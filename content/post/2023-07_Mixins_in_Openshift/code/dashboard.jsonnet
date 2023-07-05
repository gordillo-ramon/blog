local certManagerMixin = (import 'gitlab.com/uneeq-oss/cert-manager-mixin/mixin.libsonnet');

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