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

# restore user for further commands
USER runner