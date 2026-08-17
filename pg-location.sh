#!/bin/bash

kubectl exec -it location-pg-1 -- psql -U postgres -d location -c "$1;"
