# CNPGClusterPhysicalReplicationLagWarning

| | |
|---|---|
| **Severity** | warning |
| **Source** | `prometheusrules/postgres/replication-health.yaml` (homelab-authored; replaced the chart rule 2026-09-06) |
| **Clusters** | `platform-db`, `product-db`, `product-db-replica` (DR) |
| **Grafana** | CloudNativePG Cluster Overview |

## Meaning

A replica is more than **100 MB** of WAL behind its primary for **5 minutes**,
read from the primary's replication-slot view. The alert label `slot_name`
names the replica.

This rule counted **seconds** (>1 s) until 2026-09-06 and could not be trusted —
see below.

## Why this rule counts bytes

It used to read `cnpg_pg_replication_lag`, which is
`now() - pg_last_xact_replay_timestamp()`. On a standby with nothing to replay
that grows without bound, so an **idle** cluster reported minutes of "lag" while
`pg_stat_replication` showed **0 bytes** behind. Measured on 2026-09-06:
`product-db` reported 45 minutes of lag with `sent_lsn = replay_lsn`.

`cnpg_pg_replication_slots_pg_wal_lsn_diff` reads 0 when a replica is caught up,
however long the cluster has been quiet. It is taken from the **primary's** view
(`cnpg_io_instanceRole="primary"`) because replicas report a stale copy — one was
measured at `-134193152`.

Two limits worth knowing. The slot name identifies the replica, not the pod, so
map `_cnpg_<cluster>_<n>` to `<cluster>-<n>`. And a designated-replica cluster
streams from its source **without a slot there**, so this rule cannot see the DR
cluster falling behind `product-db` — a disconnect is caught by
[`CNPGClusterStandbyNotStreaming`](CNPGClusterStandbyNotStreaming.md), but a DR
cluster that is connected and merely slow is not covered by anything today.

## Impact

Replicas slightly behind primary — `-r` / `-ro` reads may be stale. Minor
failover RPO exposure.

## Diagnosis

```promql
cnpg_pg_replication_lag{cnpg_io_cluster="$CLUSTER"}
```

```bash
kubectl exec -n "$NAMESPACE" "services/${CLUSTER}-rw" -- psql -c "SELECT * FROM pg_stat_replication;"
kubectl top pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER"
```

Check long queries, network, disk IO on replicas. PgDog bans lagging replicas —
see [PgDog operations](../../../databases/runbooks/pooler-operations.md).

## Mitigation

1. Monitor — sub-second lag often transient on Kind.
2. Optimize long-running queries on primary.
3. Enable `wal_compression` if network-bound (CNPG parameters).
4. For sustained lag see critical runbook.

## Escalation

Ticket unless lag grows toward critical (>15s).
