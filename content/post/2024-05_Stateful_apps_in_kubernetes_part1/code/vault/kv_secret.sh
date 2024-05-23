# Access the vault pod and execute the following commands
kubectl -n vault exec -i --tty=false vault-0 -- sh << _EOF_

# Developer instance comes with a kv-v2 path in /secrets. Additionally, enable kv-v2 secrets
vault secrets enable -path kv-v2 -version 2 kv-v2

# ----------------------------------------------
# Create the secret with the required data
echo '{
  "authenticator-password": "c6a6-caf7-4a28-b1d",
  "authenticator-username": "authenticator",
  "replication-password": "8758-18d3-43ca-a41",
  "replication-username": "replicator",
  "restapi-password": "5f86-9c99-4901-a10",
  "superuser-password": "51ce-e1b2-4e68-a7f",
  "superuser-username": "postgres"
}' | vault kv put -format json kv-v2/keycloak-postgresql/config -

# Create the policy to allow the service account to read the required data
echo '
path "kv-v2/data/keycloak-postgresql/config" {
  capabilities = ["read"]
}' | vault policy write keycloak-postgresql-policy -

# Add the role for a rhbk serviceaccount to get the credentials
vault write auth/kubernetes/role/keycloak-role \
   bound_service_account_names=default,keycloak-postgresql-patroni \
   bound_service_account_namespaces=rhbk \
   policies=keycloak-postgresql-policy \
   audience=https://kubernetes.default.svc \
   ttl=24h
# ----------------------------------------------
_EOF_
