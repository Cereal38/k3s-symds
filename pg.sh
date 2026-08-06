#!/bin/bash

kubectl exec -it identity-pg-1 -- psql -U postgres -d identity -c "$1;"
