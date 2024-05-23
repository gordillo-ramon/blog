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
 enabled: true

_EOF_
