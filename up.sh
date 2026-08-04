#!/bin/sh

# Stop the script on any error
set -e

echo "=== Starting the cluster with k3d... ===\n"

k3d cluster create k3s-symds
