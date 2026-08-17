# k3s-symds

A self-contained local playground for **bidirectional Oracle ↔ PostgreSQL replication with [SymmetricDS](https://www.symmetricds.org/)**, running on a throwaway [k3d](https://k3d.io) cluster.

One command brings up an Oracle database, two PostgreSQL clusters (via [CloudNativePG](https://cloudnative-pg.io/)), three SymmetricDS nodes and all the configuration wiring them together. Another command destroys it. Nothing is installed on your machine beyond the prerequisites below.

It demonstrates three patterns:

1. **Cross-database replication** — a table in Oracle stays in sync with its counterpart in Postgres, in both directions, through SymmetricDS.
2. **Schema translation inside Postgres** — the replicated data lands in a dedicated `symds_identity` schema, and native Postgres triggers mirror it into a separate application schema (`identity_app`), also in both directions. This keeps the application's own model decoupled from the replication landing zone.
3. **Fan-out to independent targets** — one Oracle source feeds two unrelated Postgres databases. `identity-pg` receives the identity tables, `location-pg` receives `fr_cities`, each through its own node group, router and channel, so neither sees the other's data or blocks the other's batches.

---

## Prerequisites

| Tool | Notes |
|---|---|
| [Docker](https://docs.docker.com/get-docker/) | k3d runs the cluster inside Docker |
| [k3d](https://k3d.io/#installation) | creates the k3s cluster |
| `kubectl` | talks to the cluster |

Roughly 7 GB of free RAM — the Oracle Free image is the hungry one, with three JVMs and two Postgres clusters alongside it. First run pulls several GB of images and takes a few minutes.

## Quick start

```shell
./up.sh     # create everything (a few minutes on first run)
./down.sh   # destroy everything
```

`up.sh` is idempotent only in the sense that it always starts from scratch — it creates a brand new cluster. Run `./down.sh` first if one is already up.

When it finishes, all three databases are port-forwarded to localhost and replication is live.

## Verify it works

Give the stack ~30s after `up.sh` finishes for the initial load to settle, then check the seeded rows arrived in Postgres:

```shell
./pg-identity.sh "select * from symds_identity.identity order by id"
./pg-identity.sh "select * from identity_app.id_document_type order by id"
```

`fr_cities` is the slow one — 82k rows — and it lands in the other cluster:

```shell
./pg-location.sh "select count(*) from symds_location.fr_cities"
```

Expect 82199. A smaller number means the initial load is still streaming.

### Oracle → Postgres

```shell
./oracle.sh "insert into id_document_type (id, code, label_fr, label_en) values (4, 'DRIVER', 'Permis de conduire', 'Driving licence')"

# Lands in the replication schema, then the trigger mirrors it to the app schema
./pg-identity.sh "select * from symds_identity.id_document_type order by id"
./pg-identity.sh "select * from identity_app.id_document_type order by id"
```

The location node is plain replication, no app schema:

```shell
./oracle.sh "insert into fr_cities (id, insee_code, name, name_ascii, country_code) values (999999999, '75056', 'Paris-Test', 'Paris-Test', 'FR')"
./pg-location.sh "select id, insee_code, name from symds_location.fr_cities where id = 999999999"
```

### Postgres → Oracle

```shell
./pg-identity.sh "insert into identity_app.id_document_type (id, code, label_fr, label_en) values (5, 'RESIDENCE', 'Titre de sejour', 'Residence permit')"

# The trigger pushes it to symds_identity, SymmetricDS pushes it to Oracle
./oracle.sh "select * from id_document_type order by id"
```

```shell
./pg-location.sh "update symds_location.fr_cities set population = 1 where id = 999999999"
./oracle.sh "select id, name, population from fr_cities where id = 999999999"
```

Changes propagate within a few seconds — routing runs every 1s, push and pull every 2s (see the engine configmaps).

## Architecture

```
                                Oracle (pod: oracle-db)
                      ┌──────────────────────────────────────────┐
                      │  schema ORA                              │
                      │                                          │
                      │    identity                              │
                      │    id_document_type                      │
                      │    fr_cities                             │
                      │                                          │
                      │  sym_*  (SymmetricDS config + data)      │
                      └────────────────────┬─────────────────────┘
                                           │
                         ┌─────────────────┴────────────────┐
                         │  symds-oracle                    │
                         │  node oracle-000                 │
                         │  group: oracle                   │
                         │  registration server             │
                         └─────────┬──────────────┬─────────┘
                                   │              │  HTTP :31415
                        ┌──────────┘              └────────────────┐
                        │                                          │
    ┌───────────────────┴──────────────────┐    ┌──────────────────┴───────────────────┐
    │  symds-identity                      │    │  symds-location                      │
    │  node identity-001                   │    │  node location-002                   │
    │  group: identity                     │    │  group: location                     │
    │  channel: identity                   │    │  channel: location                   │
    └───────────────────┬──────────────────┘    └──────────────────┬───────────────────┘
                        │                                          │
    ┌───────────────────┴──────────────────┐    ┌──────────────────┴───────────────────┐
    │  PostgreSQL (CNPG: identity-pg)      │    │  PostgreSQL (CNPG: location-pg)      │
    │  database identity                   │    │  database location                   │
    │                                      │    │                                      │
    │  schema symds_identity               │    │  schema symds_location               │
    │    identity                          │    │    fr_cities                         │
    │    id_document_type                  │    │    sym_*                             │
    │    sym_*                             │    └──────────────────────────────────────┘
    │        ▲                             │
    │        │ PG triggers                 │
    │        │ (bidirectional,             │
    │        │  loop-guarded)              │
    │        ▼                             │
    │                                      │
    │  schema identity_app                 │
    │    id_document_type                  │
    └──────────────────────────────────────┘
```

**Node topology.** `oracle-000` is the root node: it holds the SymmetricDS configuration tables and acts as the registration server. `identity-001` and `location-002` are clients that register against it and receive an initial load automatically (`auto.registration` / `auto.reload` are set on the root). The two clients never talk to each other — there is no node group link between `identity` and `location`, so neither one is a replication target of the other.

**Direction semantics.** Each client has a symmetric pair of links: `oracle → <client> = P` (push) and `<client> → oracle = W` (wait for pull). Oracle pushes its changes out and pulls each client's back.

**Channel isolation.** Each client has its own channel (`identity`, `location`). Channels are the unit of batching and blocking in SymmetricDS, so an error on a `fr_cities` batch stalls only the `location` channel — the identity tables keep flowing. This is what makes the 82k-row initial load safe to sit next to the small tables.

### What is synced

| Oracle (`ORA`) | Node | Landing schema | App schema |
|---|---|---|---|
| `identity` | `identity-001` | `symds_identity.identity` | — |
| `id_document_type` | `identity-001` | `symds_identity.id_document_type` | `identity_app.id_document_type` |
| `fr_cities` | `location-002` | `symds_location.fr_cities` | — |

`identity` and `fr_cities` demonstrate plain replication. `id_document_type` additionally demonstrates the app-schema mirroring, via the two trigger functions in `k8s/configmap/identity-sql-script-configmap.yaml`.

The Postgres-side tables in `symds_identity` and `symds_location` are **created by SymmetricDS itself** during the initial load (`initial.load.create.first=true` on the root node) — they are not in any migration here. The schemas themselves are, via `postInitApplicationSQL` in each CNPG Cluster.

### Loop prevention

Both trigger functions set a transaction-local flag, `symds.sync_in_progress`, before propagating a row, and each checks the flag on entry. Without it, `symds_identity` → `identity_app` would trigger `identity_app` → `symds_identity` and bounce forever. The functions are `SECURITY DEFINER` owned by `identity_app`, so all cross-schema writes happen as that role — which is what the privilege grants in `00_setup_user_config.sql` are for.

## Connecting with a database client

`up.sh` port-forwards all three databases automatically (PIDs in `.pf/`, cleaned up by `down.sh`), so tools like DataGrip work out of the box.

**Oracle** — host `localhost`, port `1521`, service name `FREEPDB1`, user `ora`, password `ora`

**PostgreSQL** — host `localhost`, two clusters on two ports:

| Port | Database | Cluster |
|---|---|---|
| `5432` | `identity` | `identity-pg` |
| `5433` | `location` | `location-pg` |

| User | Password | Role |
|---|---|---|
| `identity` | `identity` | owns `symds_identity`; the `identity-001` engine connects as this |
| `identity_app` | `identity_app` | owns `identity_app`; simulates the consuming application |
| `location` | `location` | owns `symds_location`; the `location-002` engine connects as this |
| `postgres` | see below | superuser of either cluster, used by the setup job |

Each cluster has its own CloudNativePG-generated superuser password:

```shell
kubectl get secret identity-pg-superuser -o jsonpath='{.data.password}' | base64 -d
kubectl get secret location-pg-superuser -o jsonpath='{.data.password}' | base64 -d
```

Credentials are hardcoded on purpose — this is a disposable local stack, not a deployment template.

## Repository layout

```
up.sh / down.sh          create and destroy the whole stack
seed-oracle.sh           create and populate the Oracle source tables
oracle.sh                run a single SQL statement against Oracle
pg-identity.sh           ... against the identity Postgres cluster
pg-location.sh           ... against the location Postgres cluster

data/
  fr_cities.csv          82k French communes, bulk-loaded by seed-oracle.sh

k8s/
  db/                    CloudNativePG Cluster definitions (identity-pg, location-pg)
  secret/                Oracle and Postgres credentials
  symds/                 SymmetricDS deployments, services, engine + Flyway configmaps
  configmap/             SQL run by the setup job (roles, grants, app schema, triggers)
  job/                   the job that applies those SQL scripts
```

The `k8s/symds/` files come in one set per node: a deployment, a service and an engine configmap for each of `symds-oracle`, `symds-identity` and `symds-location`, plus the single `symds-flyway-configmap.yaml` shared by all of them.

### The SQL scripts

Applied in filename order by the `identity-setup-user-conf` job, as the Postgres superuser:

| Script | Purpose |
|---|---|
| `00_setup_user_config.sql` | create the `identity_app` role and schema, grant it access to `symds_identity` |
| `01_create_id_document_type.sql` | create the application's own table |
| `02_sync_id_document_type_symds_to_app.sql` | trigger: replication schema → app schema |
| `03_sync_id_document_type_app_to_symds.sql` | trigger: app schema → replication schema |

All four must stay **idempotent** — the job may run more than once (see below).

## Startup order

`up.sh` enforces a sequence that matters, so it is worth knowing if you change it:

1. **Oracle first, then seeded.** SymmetricDS captures from tables that already exist. This is also where the 82k `fr_cities` rows get bulk-loaded, before any capture trigger exists to record them.
2. **Root node (`symds-oracle`) before the clients.** Its init container runs `symadmin create-sym-tables`, creating the `sym_*` configuration tables in Oracle, and registers the `oracle` node group.
3. **Flyway then inserts the sync configuration** — node groups, links, routers, channels, triggers — into the *root node's* Oracle database. It runs as an init container of the client nodes, which is why the root must already be up.
4. **Client nodes** register and receive their initial loads: `symds-identity`, then `symds-location`, each preceded by a readiness wait on its CNPG cluster.
5. **The setup job last**, because `02_…` attaches a trigger to `symds_identity.id_document_type`, which only exists once the initial load has created it.

Step 5 is a race: if the initial load has not finished, the job fails with `relation … does not exist`. The job's default `backoffLimit` of 6 makes Kubernetes retry it with backoff, so it resolves itself — but a failed pod or two in `kubectl get pods` right after `up.sh` is expected, not a problem.

**Both client nodes mount the same `symds-flyway-files` configmap** and migrate the same `flyway_schema_history` in Oracle. Because `up.sh` starts them one after the other, `symds-identity` gets there first and applies *every* migration — including `V3`/`V4`, which configure the location node. By the time `symds-location`'s init container runs, the history is already current and it applies nothing. Harmless, but it means a migration's file name says nothing about which node's init container will actually run it, and starting the two clients concurrently would put them in a Flyway lock race.

## Common tasks

### Add a table to the replication

1. Add the table to `seed-oracle.sh` so it exists on the Oracle side.
2. Add a new Flyway migration in `k8s/symds/symds-flyway-configmap.yaml` with the `sym_trigger` and `sym_trigger_router` rows, pointing at the router of whichever node should receive it (copy `V2__symds_id_document_type.sql` for `identity`, `V4__symds_location_fr_cities.sql` for `location`).
3. Apply and restart a client node so its init container re-runs:

```shell
kubectl apply -f k8s/symds/symds-flyway-configmap.yaml
kubectl rollout restart deployment/symds-identity
```

Either client works for step 3 — they share the migration history, so restarting one applies whatever is outstanding regardless of which node the new rows are for.

**Never edit a migration that has already been applied** — Flyway checksums them. Add a new `V<n>__*.sql` instead.

If the target node has already completed its initial registration, SymmetricDS will *not* retroactively create and load the new table — `initial.load.create.first=true` only fires during a node's first registration. Send the schema and request a reload for just that table, with `-n` set to the node id (`001` for identity, `002` for location):

```shell
# 1. Create the table on the Postgres side
kubectl exec deploy/symds-oracle -c symmetricds -- \
  /opt/symmetric-ds/bin/symadmin --engine oracle-000 send-schema -n 001 <TABLE_NAME>

# 2. Copy the existing rows
kubectl exec deploy/symds-oracle -c symmetricds -- \
  /opt/symmetric-ds/bin/symadmin --engine oracle-000 reload-table -n 001 <TABLE_NAME>
```

For a full re-sync of every table (disaster recovery, or re-registering a node from scratch), run against Oracle instead — heavier, and for `002` that means re-shipping all 82k `fr_cities` rows:

```sql
update sym_node_security set initial_load_enabled = 1, initial_load_time = null where node_id = '001';
commit;
```

### Add another target database

The `location` node is the worked example — copy it. You need, per new target: a CNPG `Cluster` and its app secret (`k8s/db/`, `k8s/secret/`), an engine configmap declaring `group.id`/`external.id`/`registration.url`, a service, a deployment, a Flyway migration creating the node group, both links, both routers and a channel, and the `up.sh` lines to apply them in that order. The secret must be applied **before** the Cluster — CNPG only reads it during initdb bootstrap, and naming a secret that does not exist yet leaves the cluster stuck without bootstrapping.

### Change the Postgres setup SQL

```shell
kubectl apply -f k8s/configmap/identity-sql-script-configmap.yaml
kubectl delete job identity-setup-user-conf
kubectl apply -f k8s/job/identity-setup-user-conf-job.yaml
```

A job's pod template is immutable, so it has to be deleted and recreated rather than restarted.

## Troubleshooting

**Nothing is replicating.** Check all three nodes are up and the clients registered:

```shell
kubectl logs deploy/symds-oracle -c symmetricds --tail=50
kubectl logs deploy/symds-identity -c symmetricds --tail=50
kubectl logs deploy/symds-location -c symmetricds --tail=50
```

**Check for stuck batches** — `ER` status means an error. `node_id` tells you which target is stuck, and because each client has its own channel, one being stuck says nothing about the other:

```shell
./oracle.sh "select batch_id, node_id, channel_id, status, error_flag from sym_outgoing_batch order by batch_id desc fetch first 10 rows only"
./pg-identity.sh "select batch_id, node_id, status, error_flag from symds_identity.sym_outgoing_batch order by batch_id desc limit 10"
./pg-location.sh "select batch_id, node_id, status, error_flag from symds_location.sym_outgoing_batch order by batch_id desc limit 10"
```

**A pod is stuck in `CreateContainerConfigError`.** The kubelet cannot resolve a `Secret` or `ConfigMap` the container references — usually one that was never applied. `kubectl describe pod <pod>` names it in the Events. Note that this is distinct from a SymmetricDS failure, which would show as `CrashLoopBackOff` instead, because the container at least started.

**A CNPG cluster never becomes ready.**

```shell
kubectl get cluster
kubectl describe cluster location-pg
```

If it never bootstrapped because its app secret was missing, applying the secret unblocks it. If it bootstrapped *without* your secret, CNPG generated its own password and the engine will fail authentication — delete the Cluster and its PVC and let it bootstrap again.

**The setup job failed.**

```shell
kubectl logs job/identity-setup-user-conf
```

`permission denied for table sym_data` means the grants in `00_setup_user_config.sql` did not cover an object created after they ran. `relation … does not exist` means it ran before the initial load — see [Startup order](#startup-order).

**The Flyway migration failed.** It runs as an init container, so the pod never starts:

```shell
kubectl logs deploy/symds-identity -c symds-identity-flyway-migrate
kubectl logs deploy/symds-location -c symds-location-flyway-migrate
```

**Start clean.** Most problems are faster to destroy than to debug:

```shell
./down.sh && ./up.sh
```

## Known limitations

This is a demonstration stack, deliberately scoped to a laptop:

- Each Postgres cluster is a single instance, no HA, 1 Gi of storage.
- Credentials in plain text in `k8s/secret/`.
- Oracle runs as a bare pod, not a Deployment, and its data does not survive `down.sh`.
