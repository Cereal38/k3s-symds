#!/bin/sh

# Stop the script on any error
set -e

echo "=== Starting the cluster with k3d... ===\n"

k3d cluster create k3s-symds

echo "\n=== Creating CNPG namespace  ===\n"

kubectl create namespace cnpg-system

echo "\n=== Installing CNPG operator  ===\n"

kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s # Wait for the previous operation to complete

echo "\n=== Create a namespace for postgres db  ===\n"

kubectl create namespace postgres-db

echo "\n=== Create postgres db  ===\n"

kubectl apply -f k8s/postgres-cluster.yaml
