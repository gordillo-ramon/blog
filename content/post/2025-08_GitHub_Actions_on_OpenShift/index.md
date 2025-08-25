---
title: 'GitHub Actions in OpenShift'
date: '2025-08-25'
tags: [

    "GitHub",
    "OpenShift",
    "CI/CD"
]
categories: [
    "build",
]
---
With the OpenShift Container Platform, Tekton is included (https://tekton.dev/) as a tool for CI. However, some companies are using other stacks to build their applications, like Azure DevOps or Gitlab DevOps. While those technologies can be used as a pure managed service, some particular requirements (security, regulatory, etc) or cost-effective deployments may search for using runners on-prem.

That is the case of Github Actions, that can implement custom runners, and they can be executed in Kubernetes/OpenShift.

# GitHub Custom Runners in OpenShift

[GitHub Actions Kubernetes Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller) is a Kubernetes operator that orchestrates and scales self-hosted runners for GitHub Actions. It provides a way to control and deploy runner scale sets, custom runners for github actions.

Although in [prerequisites](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart#prerequisites) it says OpenShift is not supported, it does not mean it works and my guess the issue is more related with test coverage by Microsoft.

This post would show a simple way to deploy, build and test a custom runner with Action Running Controller (ARC) in OpenShift to build other containers.

# Deploying GitHub ARC

As suggested in the official documentation, we create a namespace and deploy the controller. My preference is creating the namespace in advance previously to deploy applications with helm.

```bash
NAMESPACE="arc-systems"
oc create namespace "${NAMESPACE}"
helm install arc \
    --namespace "${NAMESPACE}" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

# GitHub custom runner image

The official image `ghcr.io/actions/actions-runner:latest` is [defined](https://github.com/actions/actions-runner-controller/blob/v0.27.6/runner/actions-runner.ubuntu-22.04.dockerfile) with docker inside.

However, in case of OpenShift nodes based on cri-o, the way to build images is using buildah. So we would explain how to create a runner for OpenShift.

The mandatory software packages are [action-runner](https://github.com/actions/runner), which runs a job from a GitHub Actions workflow, and [runner-container-hooks](https://github.com/actions/runner-container-hooks), kubernetes hook implementation that spins up pods dynamically to run a job.

It is possible to build a runner that executes with the restricted-v2 SCC. However, this container can do limited actions, there are some challenges for example running buildah, but it can create java artifacts, compile rust, etc.

For the base, I have selected Centos Stream 10. It can be done with ubi9, but ubi10 lacks `lttng-ust` and I have chosen to make it as simple as possible without doing more magic.

In the [example](code/cs10.Containerfile) I followed the best practices so it can run with both alternatives, with a random user if buildah is not needed, or with nominal (runner, id=1000) user if using SCC anyuid.

First part, some labels and prerequistes for GitHub actions components:

```dockerfile
# This Dockerfile is used to build a custom image for GitHub Actions runners
# It includes the necessary tools and configurations to run GitHub Actions jobs

FROM quay.io/centos/centos:stream10

LABEL org.opencontainers.image.source="https://github.com/redhat-iberia/gha-openshift-runner-sample"
LABEL org.opencontainers.image.path="images/cs10.Dockerfile"
LABEL org.opencontainers.image.title="cs10"
LABEL org.opencontainers.image.description="A CentOS Stream 10 based runner image for GitHub Actions"
LABEL org.opencontainers.image.authors="Ramon Gordillo (@rgordill)"
LABEL org.opencontainers.image.licenses="GPLv2"
LABEL org.opencontainers.image.documentation="TBD"

# Arguments
ARG TARGETPLATFORM
ARG RUNNER_VERSION=2.327.1
ARG RUNNER_CONTAINER_HOOKS_VERSION=0.7.0

# The UID env var should be used in child Containerfile.
ENV UID=1000
ENV GID=0
ENV USERNAME="runner"

# Install software
RUN dnf update -y \
  && dnf install dnf-plugins-core -y \
  && dnf config-manager --enable crb -y \
  && dnf install -y \
  git \
  jq \
  krb5-libs \
  libicu \
  libyaml-devel \
  lttng-ust \
  openssl-libs \
  openssl \
  passwd \
  rpm-build \
  vim \
  wget \
  yum-utils \
  zlib \
  && dnf clean all
```

Then creating the nominal user, asigning group 0 (root) which is the one that would be used if a random is selected. Doing untar with that user would create the structure with runner:root, and then a simple chmod would allow all users in group 0 to execute and write in that home:

```dockerfile
# Create our user and their home directory
RUN useradd -m $USERNAME -u $UID -N -g 0

WORKDIR /home/runner

# Avoid changing group when doing untar/unzip
USER runner

RUN export ARCH=$(echo ${TARGETPLATFORM} | cut -d / -f2) \
  && if [ "$ARCH" = "amd64" ]; then export ARCH=x64 ; fi \
  && curl -L -o runner.tar.gz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
  && tar xf ./runner.tar.gz \
  && rm runner.tar.gz

# Install container hooks
RUN curl -f -L -o runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip \
  && unzip ./runner-container-hooks.zip -d ./k8s \
  && rm runner-container-hooks.zip

# Restore root for further commands
USER root

# The way to run in OpenShift with dynamic user: change group to root and set g+rwx permissions
RUN chmod -R g+rwx /home/runner
```

After that you are ready to go. You have a runner available for doing things. Obviously, you would need compilers, tools, etc, so this is an example on how to install buildah, kubectl and helm:

```dockerfile
# BEGIN -- Install additional software/tools used for actions by the runner

# --- buildah ---
# Source: https://catalog.redhat.com/software/containers/rhel10/buildah/6704f1db2d6a34af2266c2cd?container-tabs=dockerfile
# Don't include container-selinux and remove
# directories used by yum that are just taking
# up space.
RUN dnf -y install buildah \
    && rm -rf /var/cache/* /var/log/dnf* /var/log/yum.*

# Use vfs storage driver in OpenShift
RUN sed -i -e 's|^driver = "overlay"|driver = "vfs"|g' /usr/share/containers/storage.conf 

# Set up environment variables to note that this is
# not starting with usernamespace and default to
# isolate the filesystem with chroot.
ENV _BUILDAH_STARTED_IN_USERNS="" BUILDAH_ISOLATION=chroot

# --- kubectl from release page ---
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m)/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/ \
    && rm -f kubectl

# --- helm from release page ---
RUN ARCH=$(uname -m) \
  && case "$ARCH" in \
    x86_64) ARCH_TYPE="amd64" ;; \
    aarch64 | arm64) ARCH_TYPE="arm64" ;; \
    *) ARCH_TYPE="unknown" ;; \
  esac \
  && curl -LO "https://get.helm.sh/helm-v3.18.4-linux-${ARCH_TYPE}.tar.gz" \
    && tar -zxvf helm-v3.18.4-linux-${ARCH_TYPE}.tar.gz \
    && mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm \
    && rm -rf linux-${ARCH_TYPE} helm-v3.18.4-linux-${ARCH_TYPE}.tar.gz

# END -- Install additional software/tools used for actions by the runner
```

Don't forget to restore user runner, so running the container would do with that user and not with root

```dockerfile
# restore user for further commands
USER runner
```

Use that Containerfile to build it with our prefered tool (docker, podman, buildah, etc) and push it to a registry, where the Action Runner Set will pull it for running.

# Deploying an Action Runner Set

A new namespace is prefered for runners to execute. That would help to control the resources using quotas, and also provide selectors and tolerations if a set of nodes are to be used exclusively for the builds. 

A new serviceaccount would be created to provide the grants needed to execute buildah for example, or to create objects in the cluster during the builds.

And finally, we create a secret with github app credentials so the runner can execute as a custom one.
The content of `gha-secret` would be something like:

```yml
kind: Secret
apiVersion: v1
metadata:
  name: gha-secret
  namespace: arc-runners
stringData:
  github_app_id: "xxxxxxx"
  github_app_installation_id: "xxxxxxxx"
  github_app_private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
```
Follow the [guidelines](https://docs.github.com/en/enterprise-server@3.17/actions/tutorials/use-actions-runner-controller/authenticate-to-the-api) to set up the application, provide it the grants needed and get the values for this secret.

Now creating the kubernetes objects.

```bash
INSTALLATION_NAME="arc-openshift-runner-set"
NAMESPACE="arc-runners"
SERVICEACCOUNT="runner"

kubectl create namespace "${NAMESPACE}"
kubectl create sa "${SERVICEACCOUNT}" --namespace "${NAMESPACE}"
kubectl create -f gha-secret.yaml --namespace "${NAMESPACE}"
```

And now using openshift client, we grant the anyuid scc to the service account so buildah can run with its defined user (`runner`)

```bash
oc adm policy add-scc-to-user anyuid -z "${SERVICEACCOUNT}" --namespace "${NAMESPACE}"
```


As the action set would be deployed with helm, it is easier to configure it using `custom-values.yaml`:

```yml
githubConfigUrl: <https://github.com/myorg>
githubConfigSecret: gha-secret

maxRunners: 5
minRunners: 1

template:
  spec:
    containers:
    - name: runner
      image: <registry/image:tag>
      command: ["/home/runner/run.sh"]
      securityContext:
        runAsUser: 1000
    serviceAccountName: runner
    serviceAccount: runner

```
Finally, we can install the Action Runner Set using helm.

```bash
helm install "${INSTALLATION_NAME}" \
    --namespace "${NAMESPACE}" \
    -f values-custom.yaml \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

# Final Tests

For testing everything, we need a sample repository with actions that fires a workflow with a custom worker, whose name should match `INSTALLATION_NAME`.

```yml
jobs:
  build:
    name: Build image
    runs-on: arc-openshift-runner-set
```

A complete [sample](code/sample-build.yaml) has been provide for guidance.

One workflow output should show the runner in openshift that is building it:

```
 1 Current runner version: '2.327.1'
 2 Runner name: 'arc-openshift-runner-set-hdhwm-runner-lplfb'
 3 Runner group name: 'default'
 4 Machine name: 'arc-openshift-runner-set-hdhwm-runner-lplfb'
 5 > GITHUB_TOKEN Permissions
21 Secret source: Actions
22 Prepare workflow directory
23 Prepare all required actions
24 Getting action download info
25 Download action repository 'actions/checkout@v4' (SHA:11bd71901bbe5b1630ceea73d27597364c9af683)
26 Download action repository 'redhat-actions/buildah-build@v2' (SHA:7a95fa7ee0f02d552a32753e7414641a04307056)
27 Complete job name: Build image
```