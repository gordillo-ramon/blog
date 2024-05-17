# Create the rhbk namespace. This is not needed for vault but for testing it.
kubectl create namespace rhbk

# Create the vault namespace
kubectl create namespace vault

# If we need CSI, we have to patch the serviceaccount
# oc adm policy add-scc-to-user privileged -z vault-csi-provider -n vault

# Deploy Vault in Developer Mode. First enable the repo
helm repo add hashicorp https://helm.releases.hashicorp.com 

helm install vault hashicorp/vault -n vault -f - << _EOF_

global:
  openshift: true

ui:
  enabled: true

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

# Wait until pod is marked ready
kubectl -n vault wait --for=condition=ready pod/vault-0

# Access the vault pod and execute the following commands
kubectl -n vault exec -i --tty=false vault-0 -- sh << _EOF_

# ----------------------------------------------
# Enable Kubernetes authentication/authorization
vault auth enable kubernetes

# Kubernetes API setup for Vault
vault write auth/kubernetes/config \
    kubernetes_host="https://172.30.0.1:443"
# ----------------------------------------------

_EOF_
