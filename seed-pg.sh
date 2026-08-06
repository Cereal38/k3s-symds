#!/bin/bash

set -e

# birth_year is voluntarily a 4 char string to demonstrate data transformation
kubectl exec -i identity-pg-1 -- psql -U postgres -d identity -c "create table if not exists identity (id PRIMARY KEY, first_name VARCHAR(255), last_name VARCHAR(255), birth_year VARCHAR(4));"
