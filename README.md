# k3s-symds

Run a k3s cluster with a Oracle db, a Postgres db (cnpg) and SymmetricDs. To try it locally easily.

## What is needed

- At least 40gb of free disk space  
- k3d command installed  

## Useful commands

Insert a new identity into Oracle:

```shell
# Insert the new identity
printf "insert into identity (first_name,last_name,birth_date) values ('Nikola','Tesla',DATE '1856-07-10');\ncommit;\n" | kubectl exec -i oracle-db -- sqlplus -S ora/ora@//localhost:1521/FREEPDB1

# Select all identities
kubectl exec -i oracle-db -- sqlplus -S "ora/ora@//localhost:1521/FREEPDB1" <<< "SELECT * FROM identity;"

# Delete the new identity
printf "delete from identity where last_name = 'Tesla';\ncommit;\n" | kubectl exec -i oracle-db -- sqlplus -S ora/ora@//localhost:1521/FREEPDB1
```

Insert a new identity into Postgres:

```shell
# Insert the new identity
kubectl exec -i identity-pg-1 -- psql -U postgres -d identity -c "insert into symds_identity.identity (id,first_name,last_name,birth_date) values (101,'Rene','Descartes','1596-03-31');"

# Select all identities
kubectl exec -it identity-pg-1 -- psql -U postgres -d identity -c 'select * from symds_identity.identity;'

# Delete the new identity
kubectl exec -i identity-pg-1 -- psql -U postgres -d identity -c "delete from symds_identity.identity where last_name = 'Descartes';"
```
