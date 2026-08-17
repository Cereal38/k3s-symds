#!/bin/bash

echo "Try to insert Grenoble1 in DB"
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "insert into FR_CITIES (ID, REGION_CODE, DEPT_CODE, ARROND_CODE, INSEE_CODE, ALT_NAMES, NAME_ASCII, COUNTRY_CODE, GEONAME_ID, LATITUDE, LONGITUDE, NAME, POPULATION) values (9999999999,84,38,381,38185,'alt_name','Grenoble','FR',3014728,'45.178690','5.714790','Grenoble1',158552);"

echo "Create deployment"
kubectl apply -f k8s/symds/symds-location-deployment.yaml

echo "Try to insert Grenoble2 in DB"
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "insert into FR_CITIES (ID, REGION_CODE, DEPT_CODE, ARROND_CODE, INSEE_CODE, ALT_NAMES, NAME_ASCII, COUNTRY_CODE, GEONAME_ID, LATITUDE, LONGITUDE, NAME, POPULATION) values (10000000000,84,38,381,38185,'alt_name','Grenoble','FR',3014728,'45.178690','5.714790','Grenoble2',158552);"

echo "Wait for triggers to be created and migration to start"
sleep 15s

echo "Try to insert Grenoble3 in DB"
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "insert into FR_CITIES (ID, REGION_CODE, DEPT_CODE, ARROND_CODE, INSEE_CODE, ALT_NAMES, NAME_ASCII, COUNTRY_CODE, GEONAME_ID, LATITUDE, LONGITUDE, NAME, POPULATION) values (10000000001,84,38,381,38185,'alt_name','Grenoble','FR',3014728,'45.178690','5.714790','Grenoble3',158552);"

echo "Apply location configmap"
kubectl apply -f k8s/configmap/location-sql-script-configmap.yaml

echo "Apply and run the job"
kubectl apply -f k8s/job/location-setup-user-conf-job.yaml

echo "Try to insert Grenoble4 in DB"
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "insert into FR_CITIES (ID, REGION_CODE, DEPT_CODE, ARROND_CODE, INSEE_CODE, ALT_NAMES, NAME_ASCII, COUNTRY_CODE, GEONAME_ID, LATITUDE, LONGITUDE, NAME, POPULATION) values (10000000002,84,38,381,38185,'alt_name','Grenoble','FR',3014728,'45.178690','5.714790','Grenoble4',158552);"

echo "Wait 2 seconds for the job to run"
sleep 60s

echo "Try to insert Grenoble5 in DB"
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "insert into FR_CITIES (ID, REGION_CODE, DEPT_CODE, ARROND_CODE, INSEE_CODE, ALT_NAMES, NAME_ASCII, COUNTRY_CODE, GEONAME_ID, LATITUDE, LONGITUDE, NAME, POPULATION) values (10000000003,84,38,381,38185,'alt_name','Grenoble','FR',3014728,'45.178690','5.714790','Grenoble5',158552);"
