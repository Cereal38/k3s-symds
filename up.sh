#!/bin/sh

# Stop the script on any error
set -e

echo "=== Starting the cluster with K3D... ===\n"

k3d cluster create k3s-symds

echo "\n=== Create a namespace for Oracle DB  ===\n"

kubectl create namespace oracle

echo "\n=== Create Oracle DB  ===\n"

kubectl -n oracle run identity-ora --image=gvenzl/oracle-free:latest --env="ORACLE_PASSWORD=identity" --port=1521

echo "\n=== Expose Oracle DB pod  ===\n"

# To connect to the Oracle DB run this commande: `kubectl -n oracle exec -it identity-ora -- sqlplus system/identity@//localhost:1521/FREEPDB1`
kubectl -n oracle expose pod identity-ora --port=1521 --target-port=1521 --name=oracle-service

echo "\n=== Creating CNPG namespace  ===\n"

kubectl create namespace cnpg-system

echo "\n=== Installing CNPG operator  ===\n"

kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s # Wait for the previous operation to complete

echo "\n=== Create a namespace for Postgres DB  ===\n"

kubectl create namespace postgres

echo "\n=== Create Postgres DB  ===\n"

kubectl apply -f k8s/postgres-cluster.yaml

echo "\n=== Create a namespace for SymDs  ===\n"

kubectl create namespace symds

echo "\n=== Apply the SymDs engine configmap  ===\n"

kubectl -n symds apply -f k8s/symds-identity-engine-configmap.yaml


