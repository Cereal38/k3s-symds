#!/bin/sh

# Stop the script on any error
set -e

echo "=== Starting the cluster with K3D... ===\n"

k3d cluster create k3s-symds

echo "\n=== Create Oracle DB  ===\n"

kubectl run identity-ora --image=gvenzl/oracle-free:latest --env="ORACLE_PASSWORD=identity" --env="APP_USER=identity" --env="APP_USER_PASSWORD=identity" --port=1521

echo "\n=== Expose Oracle DB pod  ===\n"

# To connect to the Oracle DB run this commande: `kubectl exec -it identity-ora -- sqlplus system/identity@//localhost:1521/FREEPDB1`
kubectl expose pod identity-ora --port=1521 --target-port=1521 --name=oracle-service

echo "\n=== Creating CNPG namespace  ===\n"

kubectl create namespace cnpg-system

echo "\n=== Installing CNPG operator  ===\n"

kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s # Wait for the previous operation to complete

echo "\n=== Create Postgres DB  ===\n"

kubectl apply -f k8s/postgres-cluster.yaml

echo "\n=== Waiting for Oracle pods to be up... ===\n"

kubectl wait --for=condition=Ready pod/identity-ora --timeout=300s

echo "\n=== Waiting for Oracle to accept connections... ===\n"

SECONDS=0
while :; do
  if probe=$(echo "SELECT 1 FROM dual;" | kubectl exec -i identity-ora -- sqlplus -S -L "identity/identity@//localhost:1521/FREEPDB1" 2>&1); then
    printf '\r\033[KOk\n' "$SECONDS"
    break
  fi
  printf '\r\033[KWaiting for DB… %ds'
  sleep 1
done

echo "\n=== Seed the Oracle DB  ===\n"

./seed-oracle.sh

echo "\n=== Apply the SymDs secret, configmaps and services  ===\n"

kubectl apply -f k8s/symds-secret.yaml
kubectl apply -f k8s/symds-flyway-configmap.yaml
kubectl apply -f k8s/symds-identity-ora-engine-configmap.yaml
kubectl apply -f k8s/symds-identity-pg-engine-configmap.yaml
kubectl apply -f k8s/symds-oracle-service.yaml
kubectl apply -f k8s/symds-identity-service.yaml

echo "\n=== Start the SymDs root node (oracle-000)  ===\n"

# The root node MUST be up before the client node: it creates the sym_* tables that
# the client's Flyway migrations populate, and it registers the oracle node group
# that those migrations reference.
kubectl apply -f k8s/symds-oracle-deployment.yaml
kubectl rollout status deploy/symds-oracle --timeout=300s

echo "\n=== Waiting for the Postgres cluster to be ready  ===\n"

kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=identity-pg --timeout=300s

echo "\n=== Start the SymDs client node (identity-001)  ===\n"

# Registers with oracle-000 and receives its initial load automatically
# (auto.registration / auto.reload are set on the root node).
kubectl apply -f k8s/symds-identity-deployment.yaml
kubectl rollout status deploy/symds-identity --timeout=300s

echo "\n=== Done ===\n"
echo "Replication should appear within ~30s. Check it with:"
echo "  kubectl exec -it identity-pg-1 -- psql -U postgres -d identity -c 'select * from symds_identity.identity;'"
