---
title: What are mixins and how to add them to OpenShift (Rules and Dashboards)
date: '2023-07-05'
tags: [
    "OpenShift",
    "prometheus",
    "mixins",
]
categories: [
    "monitoring",
]
---

Prometheus and grafana have been established as de-facto stacks for kubernetes cluster monitoring, at least in the upstream communities. Once a cluster has the stack available, kubernetes and other application components are exposing their metrics. There is a need to create curated alerts based on those metrics and dashboards that give a high level view of what is happening.

There is an effort to create those artifacts in a templated way. It enables a distribution to bundle them with customization if needed but keeping the baseline reusable.

That is what [kubernetes mixins](https://monitoring.mixins.dev/kubernetes/) are meant for. In this article, I would explore how to use one mixin to add prometheus rules and dashboards to OpenShift.

## Jsonnet

[Jsonnet](https://jsonnet.org/) defines itself as "A configuration language for app and tool developers". There are some tools around this language. There are also some extensions to your favorite IDE that can help to develop using this language, like the [grafana extension for vscode](https://marketplace.visualstudio.com/items?itemName=Grafana.vscode-jsonnet). I need the following:

* `jsonnet`: tool that has a fedora [package](https://packages.fedoraproject.org/pkgs/jsonnet/jsonnet/index.html) that comes from a [google repo](https://github.com/google/jsonnet).
* `jb`: another tool with a [package](https://packages.fedoraproject.org/pkgs/golang-github-jsonnet-bundler/golang-github-jsonnet-bundler/) that comes from a [golang based repo](https://github.com/jsonnet-bundler/jsonnet-bundler)
* `gojsontoyaml`: there is no fedora package for this tool, but you can add it from [its repo](https://github.com/brancz/gojsontoyaml) if you have golang installed using `go install github.com/brancz/gojsontoyaml`


## The basics

### PrometheusRules

In OpenShift, prometheus is deployed with the Prometheus Operator. Alerts are defined using PrometheusRule CR, so I need my mixin to create those prometheus rules.

### Dashboards

In OpenShift, there is no grafana runtime deployed. However, there are some custom dashboards that can be configured using the same (with some restrictions) json exported dashboard from grafana.

For a dashboard to appear in the Console UI, the dashboard JSON definition needs to be loaded into a ConfigMap in the `openshift-config-managed` namespace.

```yaml
metadata:
  labels:
    console.openshift.io/dashboard: 'true'
```

To appear in the Developer UI, it needs to have the following label.

```yaml
metadata:
  labels:
    console.openshift.io/odc-dashboard: 'true'
```

## Everything together

The example would be to create the artifacts for [cert-manager operator](https://github.com/openshift/cert-manager-operator/). There is an existing mixin created by [Uneeq](https://www.digitalhumans.com/about) that I would use to create the artifacts.

### Initial structure and main script

I have created the following structure:

```bash
├── hack
├── jsonnet
│   └── vendor
├── manifests
```

On hack, I create the script that would checkout the mixin, and apply the transformations to create the target artifacts. I have called `mixin.sh`, but any name would fit.

```bash
#!/bin/sh
set -eu

if ! command -v jb &> /dev/null; then
  echo "jb could not be found. See https://github.com/jsonnet-bundler/jsonnet-bundler"
  exit 1
fi

# Generate jsonnet mixin prometheusrule and dashboards manifest.

cd jsonnet && jb update
jsonnet -J vendor main.jsonnet  | gojsontoyaml > ../manifests/0000_90_cert-manager-operator_01_prometheusrule.yaml
jsonnet -J vendor dashboard.jsonnet  | gojsontoyaml > ../manifests/0000_90_cert-manager-operator_02-dashboards.yaml
```

First lines are checking if the required tools are working. The magic is in the last two ones. That uses `main.jsonnet` and `dashboards.jsonnet`to create the rules and the dashboards. But wait, some initial steps before are still needed.

### jsonnet configuration

Jsonnet uses a file and a lock to import dependencies. On the jsonnet folder, as I need to import the mixin from other project, I need to create the following [`jsonnetfile.json`](code/jsonnetfile.json):

```json
{
  "version": 1,
  "dependencies": [
    {
      "source": {
        "git": {
          "remote": "https://gitlab.com/uneeq-oss/cert-manager-mixin",
          "subdir": ""
        }
      },
      "version": "master"
    }
  ],
  "legacyImports": true
}
```

Create also an empty jsonnectfile.lock.json file which would reference the branch and the commits that I lock to once the tooling executes. Don't import anything in the project yet, the jsonnet tooling will do for you.

At this moment, if I execute the first part of `hack/mixin.sh` from the root folder, `cd jsonnet && jb update`, it would download a subfolder under `jsonnet/vendor` with the mixin dependencies.

### Templating

I have created the two jsonnet scripts that would create the kubernetes objects needed from the templates. The first one, [`main.jsonnet`](code/main.jsonnet) will handle PrometheusRules:

```go
local certManagerMixin = (import 'gitlab.com/uneeq-oss/cert-manager-mixin/mixin.libsonnet');

local alertingRules = if std.objectHasAll(certManagerMixin, 'prometheusAlerts') then certManagerMixin.prometheusAlerts.groups else [];

{0000_90_cert-manager-operator_02-dashboards.yaml
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
  metadata: {
    name: 'cert-manager-prometheus-rules',
    namespace: 'cert-manager-operator',
    annotations:
      {
        'include.release.openshift.io/self-managed-high-availability': 'true',
        'include.release.openshift.io/single-node-developer': 'true',
      },
  },
  spec: {
    groups: alertingRules,
  },
}0000_90_cert-manager-operator_02-dashboards.yaml
```

Very simple, I just select the `prometheusAlerts` leaf created with `mixin.libsonnet` (usually this file is just an import of other modules) and injects them into the PrometheusRule CR. I can do other post processing in jsonnet if I need to, like filtering alerts that are not relevant to our environment, changing some fields in them, etc, but I will keep it as simple as it is.

Next one is [`dashboard.jsonnet`](code/dashboard.jsonnet):

```go
local certManagerMixin = (import 'gitlab.com/´uneeq-oss/cert-manager-mixin/mixin.libsonnet');

{
  apiVersion: 'v1',
  kind: 'ConfigMap',
  metadata: {
    annotations: {
      'include.release.openshift.io/ibm-cloud-managed': 'true',
      'include.release.openshift.io/self-managed-high-availability': 'true',
      'include.release.openshift.io/single-node-developer': 'true',
    },
    labels: {
      'console.openshift.io/dashboard': 'true',
    },
    name: 'cert-manager-dashboard',
    namespace: 'openshift-config-managed',
  },
  data: {
    'cert-manager.json': std.manifestJsonEx(certManagerMixin.grafanaDashboards['cert-manager.json'], '    '),
  },
}
```

Also very simple, I get the leaf from the mixin dashboard that references the `cert-manager.json` and injects in the configmap that was referenced previously.

After executing the complete `hack/mixin.sh` the desired manifests should be created (`0000_90_cert-manager-operator_01_prometheusrule.yaml` and `0000_90_cert-manager-operator_02-dashboards.yaml`) that can be directly applied to our cluster.

## Final Note

OpenShift dashboards do not implement all the set of options that a grafana dashboard have. If you get some warning in the console regarding that, you may filter out or transform it, preferably on the jsonnet script, to get a compatible set.