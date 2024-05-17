# Create the static role previous to creating the plugin
kubectl -n rhbk exec -i --tty=false keycloak-postgresql-0 -c patroni -- psql -U postgres -c "CREATE USER app"

# Check the Password is empty
echo "Checking empty password"
kubectl -n rhbk exec -i --tty=false keycloak-postgresql-0 -c patroni -- psql -U postgres -c "SELECT rolpassword FROM pg_authid where rolname='app'"

# Access the vault pod and execute the following commands
kubectl -n vault exec -i --tty=false vault-0 -- sh << _EOF_

# Enable the database
vault secrets enable -path database database

# ----------------------------------------------
# Create the secret with the required data
vault write database/config/keycloak-postgresql \
     plugin_name=postgresql-database-plugin \
     connection_url="postgresql://{{username}}:{{password}}@keycloak-postgresql-primary.rhbk.svc.cluster.local:5432/postgres?sslmode=disable" \
     allowed_roles="*" \
     username="postgres" \
     password="51ce-e1b2-4e68-a7f"

vault write database/static-roles/app \
      db_name=keycloak-postgresql \
      username=app \
      rotation_period=86400
_EOF_

# Check the Password is empty
echo "Checking new password"
kubectl -n rhbk exec -i --tty=false keycloak-postgresql-0 -c patroni -- psql -U postgres -c "SELECT rolpassword FROM pg_authid where rolname='app'"
