# k3s-symds

Run a k3s cluster with a Oracle db, a Postgres db (cnpg) and SymmetricDs. To try it locally easily.

## What is needed

- At least 40gb of free disk space  
- k3d command installed  

## Useful commands

Interact with the Oracle DB from shell

```shell
./oracle.sh "select * from identity"
```

Interact with the Postgres DB from shell

```shell
./pg.sh "select * from symds_identity.identity"
```

## Connect to databases

The `up.sh` script automatically portforward the postgres and the oracle db. So it's possible to connect with tools like Datagrip.

Oracle:
- host: `localhost`
- port: `1521`
- service name: `FREEPDB1`
- user: `ora`
- password: `ora`

Postgres:
- host: `localhost`
- port: `5432`
- user: `identity`
- password: `identity`

## Apply modifications in the flyway configmap

1. Update the `k8s/symds-flyway-configmap.yaml` file to add the desired migration
2. Apply the new version of the file with `kubectl apply -f k8s/symds-flyway-configmap.yaml`
3. Restart the deployment with `kubectl rollout restart deployment/symds-identity`

If the migration adds a new table to sync (`CREATE TABLE` + `sym_trigger`/`sym_trigger_router` rows) and the `identity-001` node has already completed its initial registration, SymmetricDS won't retroactively create/load that table on Postgres on its own — `initial.load.create.first=true` only fires during a node's first registration. Send the schema, then request a reload for just that table:

```shell
# 1. Create the table Postgres side
kubectl exec deploy/symds-oracle -c symmetricds -- /opt/symmetric-ds/bin/symadmin --engine oracle-000 send-schema -n 001 <TABLE_NAME>

# 2. Synchronize existing rows
kubectl exec deploy/symds-oracle -c symmetricds -- /opt/symmetric-ds/bin/symadmin --engine oracle-000 reload-table -n 001 <TABLE_NAME>
```

For a full re-sync of every table (e.g. disaster recovery, or re-registering a node from scratch), use instead (heavier):

```sql
update sym_node_security set initial_load_enabled = 1, initial_load_time = null where node_id = '001';
commit;
```
