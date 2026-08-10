# k3s-symds

A self-contained local playground for **bidirectional Oracle ↔ PostgreSQL replication with [SymmetricDS](https://www.symmetricds.org/)**, running on a throwaway [k3d](https://k3d.io) cluster.

One command brings up an Oracle database, a PostgreSQL cluster (via [CloudNativePG](https://cloudnative-pg.io/)), two SymmetricDS nodes and all the configuration wiring them together. Another command destroys it. Nothing is installed on your machine beyond the prerequisites below.

It demonstrates two patterns:

1. **Cross-database replication** — a table in Oracle stays in sync with its counterpart in Postgres, in both directions, through SymmetricDS.
2. **Schema translation inside Postgres** — the replicated data lands in a dedicated `symds_identity` schema, and native Postgres triggers mirror it into a separate application schema (`identity_app`), also in both directions. This keeps the application's own model decoupled from the replication landing zone.

---

## Prerequisites

| Tool | Notes |
|---|---|
| [Docker](https://docs.docker.com/get-docker/) | k3d runs the cluster inside Docker |
| [k3d](https://k3d.io/#installation) | creates the k3s cluster |
| `kubectl` | talks to the cluster |

Roughly 6 GB of free RAM — the Oracle Free image is the hungry one. First run pulls several GB of images and takes a few minutes.

## Quick start

```shell
./up.sh     # create everything (a few minutes on first run)
./down.sh   # destroy everything
```

`up.sh` is idempotent only in the sense that it always starts from scratch — it creates a brand new cluster. Run `./down.sh` first if one is already up.

When it finishes, both databases are port-forwarded to localhost and replication is live.

## Verify it works

Give the stack ~30s after `up.sh` finishes for the initial load to settle, then check the seeded rows arrived in Postgres:

```shell
./pg.sh "select * from symds_identity.identity order by id"
./pg.sh "select * from identity_app.id_document_type order by id"
```

### Oracle → Postgres

```shell
./oracle.sh "insert into id_document_type (id, code, label_fr, label_en) values (4, 'DRIVER', 'Permis de conduire', 'Driving licence')"

# Lands in the replication schema, then the trigger mirrors it to the app schema
./pg.sh "select * from symds_identity.id_document_type order by id"
./pg.sh "select * from identity_app.id_document_type order by id"
```

### Postgres → Oracle

```shell
./pg.sh "insert into identity_app.id_document_type (id, code, label_fr, label_en) values (5, 'RESIDENCE', 'Titre de sejour', 'Residence permit')"

# The trigger pushes it to symds_identity, SymmetricDS pushes it to Oracle
./oracle.sh "select * from id_document_type order by id"
```

Changes propagate within a few seconds — routing runs every 1s, push and pull every 2s (see the engine configmaps).

## Architecture

```
                    Oracle (pod: oracle-db)                 PostgreSQL (CNPG: identity-pg)
                 ┌──────────────────────────┐            ┌──────────────────────────────────┐
                 │  schema ORA              │            │  database identity               │
                 │                          │            │                                  │
                 │  identity                │            │  schema symds_identity           │
                 │  id_document_type        │            │    identity                      │
                 │                          │            │    id_document_type              │
                 │  sym_*  (SymmetricDS     │            │    sym_*                         │
                 │          config + data)  │            │            ▲                     │
                 └────────────┬─────────────┘            │            │ PG triggers         │
                              │                          │            │ (bidirectional,     │
                              │                          │            │  loop-guarded)      │
                              │                          │            ▼                     │
                              │                          │  schema identity_app             │
                              │                          │    id_document_type              │
                              │                          └────────────┬─────────────────────┘
                              │                                       │
                    ┌─────────┴──────────┐                  ┌─────────┴──────────┐
                    │  symds-oracle      │  ◄── HTTP ──►    │  symds-identity    │
                    │  node oracle-000   │     :31415       │  node identity-001 │
                    │  group: oracle     │                  │  group: identity   │
                    │  (registration     │                  │  (client)          │
                    │   server / root)   │                  │                    │
                    └────────────────────┘                  └────────────────────┘
```

**Node topology.** `oracle-000` is the root node: it holds the SymmetricDS configuration tables and acts as the registration server. `identity-001` is a client that registers against it and receives an initial load automatically (`auto.registration` / `auto.reload` are set on the root).

**Direction semantics.** The node group link is `oracle → identity = P` (push) and `identity → oracle = W` (wait for pull), so Oracle pushes its changes and pulls Postgres's.

### What is synced

| Oracle (`ORA`) | Postgres (`symds_identity`) | Postgres (`identity_app`) |
|---|---|---|
| `identity` | `identity` | — |
| `id_document_type` | `id_document_type` | `id_document_type` |

`identity` demonstrates plain replication. `id_document_type` additionally demonstrates the app-schema mirroring, via the two trigger functions in `k8s/configmap/identity-sql-script-configmap.yaml`.

The Postgres-side tables in `symds_identity` are **created by SymmetricDS itself** during the initial load (`initial.load.create.first=true` on the root node) — they are not in any migration here.

### Loop prevention

Both trigger functions set a transaction-local flag, `symds.sync_in_progress`, before propagating a row, and each checks the flag on entry. Without it, `symds_identity` → `identity_app` would trigger `identity_app` → `symds_identity` and bounce forever. The functions are `SECURITY DEFINER` owned by `identity_app`, so all cross-schema writes happen as that role — which is what the privilege grants in `00_setup_user_config.sql` are for.

## Connecting with a database client

`up.sh` port-forwards both databases automatically (PIDs in `.pf/`, cleaned up by `down.sh`), so tools like DataGrip work out of the box.

**Oracle** — host `localhost`, port `1521`, service name `FREEPDB1`, user `ora`, password `ora`

**PostgreSQL** — host `localhost`, port `5432`, database `identity`

| User | Password | Role |
|---|---|---|
| `identity` | `identity` | owns `symds_identity`; the SymmetricDS engine connects as this |
| `identity_app` | `identity_app` | owns `identity_app`; simulates the consuming application |
| `postgres` | see below | superuser, used by the setup job |

The superuser password is generated by CloudNativePG:

```shell
kubectl get secret identity-pg-superuser -o jsonpath='{.data.password}' | base64 -d
```

Credentials are hardcoded on purpose — this is a disposable local stack, not a deployment template.

## Repository layout

```
up.sh / down.sh          create and destroy the whole stack
seed-oracle.sh           create and populate the Oracle source tables
oracle.sh / pg.sh        run a single SQL statement against either database

k8s/
  db/                    CloudNativePG Cluster definition
  secret/                Oracle and Postgres credentials
  symds/                 SymmetricDS deployments, services, engine + Flyway configmaps
  configmap/             SQL run by the setup job (roles, grants, app schema, triggers)
  job/                   the job that applies those SQL scripts
```

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

1. **Oracle first, then seeded.** SymmetricDS captures from tables that already exist.
2. **Root node (`symds-oracle`) before the client.** Its init container runs `symadmin create-sym-tables`, creating the `sym_*` configuration tables in Oracle, and registers the `oracle` node group.
3. **Flyway then inserts the sync configuration** — node groups, links, routers, channels, triggers — into the *root node's* Oracle database. It runs as an init container of `symds-identity`, which is why the root must already be up.
4. **Client node (`symds-identity`)** registers and receives its initial load.
5. **The setup job last**, because `02_…` attaches a trigger to `symds_identity.id_document_type`, which only exists once the initial load has created it.

Step 5 is a race: if the initial load has not finished, the job fails with `relation … does not exist`. The job's default `backoffLimit` of 6 makes Kubernetes retry it with backoff, so it resolves itself — but a failed pod or two in `kubectl get pods` right after `up.sh` is expected, not a problem.

## Common tasks

### Add a table to the replication

1. Add the table to `seed-oracle.sh` so it exists on the Oracle side.
2. Add a new Flyway migration in `k8s/symds/symds-flyway-configmap.yaml` with the `sym_trigger` and `sym_trigger_router` rows (copy `V2__symds_id_document_type.sql`).
3. Apply and restart so the init container re-runs:

```shell
kubectl apply -f k8s/symds/symds-flyway-configmap.yaml
kubectl rollout restart deployment/symds-identity
```

**Never edit a migration that has already been applied** — Flyway checksums them. Add a new `V<n>__*.sql` instead.

If the `identity-001` node has already completed its initial registration, SymmetricDS will *not* retroactively create and load the new table — `initial.load.create.first=true` only fires during a node's first registration. Send the schema and request a reload for just that table:

```shell
# 1. Create the table on the Postgres side
kubectl exec deploy/symds-oracle -c symmetricds -- \
  /opt/symmetric-ds/bin/symadmin --engine oracle-000 send-schema -n 001 <TABLE_NAME>

# 2. Copy the existing rows
kubectl exec deploy/symds-oracle -c symmetricds -- \
  /opt/symmetric-ds/bin/symadmin --engine oracle-000 reload-table -n 001 <TABLE_NAME>
```

For a full re-sync of every table (disaster recovery, or re-registering a node from scratch), run against Oracle instead — heavier:

```sql
update sym_node_security set initial_load_enabled = 1, initial_load_time = null where node_id = '001';
commit;
```

### Change the Postgres setup SQL

```shell
kubectl apply -f k8s/configmap/identity-sql-script-configmap.yaml
kubectl delete job identity-setup-user-conf
kubectl apply -f k8s/job/identity-setup-user-conf-job.yaml
```

A job's pod template is immutable, so it has to be deleted and recreated rather than restarted.

## Troubleshooting

**Nothing is replicating.** Check both nodes are up and the client registered:

```shell
kubectl logs deploy/symds-oracle -c symmetricds --tail=50
kubectl logs deploy/symds-identity -c symmetricds --tail=50
```

**Check for stuck batches** — `ER` status means an error:

```shell
./oracle.sh "select batch_id, node_id, status, error_flag from sym_outgoing_batch order by batch_id desc fetch first 10 rows only"
./pg.sh "select batch_id, node_id, status, error_flag from symds_identity.sym_outgoing_batch order by batch_id desc limit 10"
```

**The setup job failed.**

```shell
kubectl logs job/identity-setup-user-conf
```

`permission denied for table sym_data` means the grants in `00_setup_user_config.sql` did not cover an object created after they ran. `relation … does not exist` means it ran before the initial load — see [Startup order](#startup-order).

**The Flyway migration failed.** It runs as an init container, so the pod never starts:

```shell
kubectl logs deploy/symds-identity -c symds-identity-flyway-migrate
```

**Start clean.** Most problems are faster to destroy than to debug:

```shell
./down.sh && ./up.sh
```

## Known limitations

This is a demonstration stack, deliberately scoped to a laptop:

- Single Postgres instance, no HA, 1 Gi of storage.
- Credentials in plain text in `k8s/secret/`.
- Oracle runs as a bare pod, not a Deployment, and its data does not survive `down.sh`.
