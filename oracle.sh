#!/bin/bash

kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "$1;"

