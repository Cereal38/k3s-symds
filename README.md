# k3s-symds

Run a k3s cluster with a Oracle db, a Postgres db (cnpg) and SymmetricDs. To try it locally easily.

## What is needed

- At least 40gb of free disk space  
- k3d command installed  

## Useful commands

Insert into Oracle:

```shell
printf "insert into identity (first_name,last_name,birth_date) values ('Nikola','Tesla',DATE '1856-07-10');\ncommit;\n" | kubectl exec -i identity-ora -- sqlplus -S identity/identity@//localhost:1521/FREEPDB1
```

Insert into Postgres:

```shell
kubectl exec -i identity-pg-1 -- psql -U postgres -d identity -c "insert into symds_identity.identity (id,first_name,last_name,birth_date) values (101,'Rene','Descartes','1596-03-31');"
```
