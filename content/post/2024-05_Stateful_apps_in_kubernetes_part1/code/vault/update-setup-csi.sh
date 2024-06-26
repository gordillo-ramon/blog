# CSI needs privileged SCC serviceaccount
oc adm policy add-scc-to-user privileged -z vault-csi-provider -n vault

helm upgrade vault hashicorp/vault -n vault -f - << _EOF_

global:
  openshift: true

ui:
  enabled: true

csi:
  enabled: true
  daemonSet:
    securityContext: 
      container: 
        privileged: true

server:
  dev:
    enabled: true
  route:
    enabled: true
    host: null
    tls:
      termination: edge

injector:
  enabled: false

_EOF_
