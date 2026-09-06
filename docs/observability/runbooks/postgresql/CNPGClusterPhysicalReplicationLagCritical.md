# CNPGClusterPhysicalReplicationLagCritical

| | |
|---|---|
| **Severity** | critical |
| **Source** | `prometheusrules/postgres/replication-health.yaml` (homelab-authored; replaced the chart rule 2026-09-06) |
| **Clusters** | `platform-db`, `product-db` |
| **Grafana** | CloudNativePG Cluster Overview |

## Meaning

A replica is more than **1 GB** of WAL behind its primary for **5 minutes**, read
from the primary's replication-slot view. The alert label `slot_name` names the
replica. At this size the primary is also retaining that much WAL for the slot,
so it is a disk-fill risk as well as a redundancy one.

This rule counted **seconds** (>15 s) until 2026-09-06 and could not be trusted —
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

Failover may lose recent commits not yet replicated. Read replicas serve stale
data. DR promotion (`product-db-replica`) risk if lag persists.

## Diagnosis

Full procedure in
[CNPGClusterPhysicalReplicationLagWarning.md](CNPGClusterPhysicalReplicationLagWarning.md)
plus:

```bash
kubectl exec -n "$NAMESPACE" "services/${CLUSTER}-rw" -- psql -c "
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '5 minutes'
ORDER BY duration DESC;
"
```

## Mitigation

1. Terminate runaway long queries on primary (with approval) if they generate
   excessive WAL.
2. Scale CPU/memory on lagging replica if resource-bound.
3. Increase `max_wal_size` / checkpoint tuning — [CNPGCheckpointPressure.md](CNPGCheckpointPressure.md).
4. For DR context: [cnpg-dr-replica-bootstrap.md](../../../databases/runbooks/cnpg-dr-replica-bootstrap.md).

## Escalation

**P1** if lag sustained >30m or failover imminent.
