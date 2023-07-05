local certManagerMixin = (import 'gitlab.com/uneeq-oss/cert-manager-mixin/mixin.libsonnet');

local alertingRules = if std.objectHasAll(certManagerMixin, 'prometheusAlerts') then certManagerMixin.prometheusAlerts.groups else [];

// Exclude rules that are either OpenShift specific or do not work for OpenShift.
{
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
}