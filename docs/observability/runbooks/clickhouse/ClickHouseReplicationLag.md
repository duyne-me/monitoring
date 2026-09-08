# ClickHouseReplicationLag

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay` > 300 s, `max by (replica)`, from `:9363` |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; expect 3 series at ~0) |
| **Dashboard** | ClickHouse → Server engine (replication row) |
| **Local-stack** | not present — no replication in the compose stack |

## Meaning

On this replica, the most-lagging `ReplicatedMergeTree` table has an
`absolute_delay` above 300 seconds for 10 minutes: its applied replication log
trails the freshest replica by more than five minutes. A healthy replica at
the collector's batch cadence sits at 0–2 s. Five minutes means the fetch queue
is **stuck**, not busy — a part that fails to fetch, a network path, a slow
disk — because a busy queue drains.

This is the one replication signal nothing else in the group provides.
[ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md) is the quorum's view,
[ClickHouseZooKeeperExceptions](ClickHouseZooKeeperExceptions.md) a rate of
errors, [ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) the end state.
None can say "this replica is twenty minutes behind".

## Impact

Grafana reads through the round-robin Service, so about a third of queries land
on the lagging replica and return **stale data with no error**. The most recent
window of logs, traces and edge access-log rows appears missing, then appears,
depending on which replica answered. Ingest is unaffected — the collector writes
to whichever replica it reaches and the others replicate.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl -n monitoring exec <replica pod from the alert> -- clickhouse-client --password=$PW -q"

# Which table, how far behind, and is the queue moving
$CH "SELECT database, table, absolute_delay, queue_size, inserts_in_queue, merges_in_queue,
            is_readonly, is_session_expired, active_replicas, total_replicas
     FROM system.replicas WHERE absolute_delay > 60 ORDER BY absolute_delay DESC"

# The head of the queue — one un-fetchable part blocks everything behind it
$CH "SELECT database, table, type, create_time, num_tries, last_exception, new_part_name, source_replica
     FROM system.replication_queue ORDER BY create_time ASC LIMIT 5"

# Can it reach its peers' interserver port (9009)?
$CH "SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/otel/otel_logs/replicas' FORMAT PrettyCompact"
```

Read `last_exception` first. `No active replica has part` on every entry means
the part is gone everywhere — see
[ClickHouseReplicatedDataLoss](ClickHouseReplicatedDataLoss.md). A connection
error to one `source_replica` means a network or NetworkPolicy problem between
the two pods. `is_session_expired = 1` means this is really a Keeper problem —
[ClickHouseKeeperSessionLost](ClickHouseKeeperSessionLost.md).

### PromQL

```promql
max by (replica) (ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay{job="clickhouse-server"})
max by (replica) (ClickHouseAsyncMetrics_ReplicasMaxQueueSize{job="clickhouse-server"})
max by (replica) (ClickHouseMetrics_ReplicatedFetch{job="clickhouse-server"})   # >0 = fetches in flight, so it is moving
```

## Mitigation

1. **Stuck on one part** (`num_tries` climbing, same `new_part_name`): on the
   lagging replica, `SYSTEM RESTART REPLICA otel.<table>` re-reads the queue
   from Keeper. If it still cannot fetch, `ALTER TABLE otel.<table> DROP
   DETACHED PART` is not the answer — check whether the part exists on the
   source first.
2. **Network**: `kubectl -n monitoring exec <pod> -- nc -zv
   chi-clickhouse-otel-0-<n>-0.<svc> 9009` from the lagging replica to each
   peer. A recent NetworkPolicy change in `configs/network-policies/` is the
   usual cause.
3. **Just restarted**: a replica that was down for an hour legitimately lags
   while it catches up. Watch `queue_size` fall; if it falls, wait.
4. Do **not** `SYSTEM DROP REPLICA` or delete the PVC to "re-sync". A fresh
   replica re-fetches 90 days of data through the same path that is failing.

## Escalation

Ticket. Page if two replicas lag at once (the third is the only fresh copy) or
if `last_exception` names data loss. Co-firing `ClickHouseKeeperSessionLost` or
`ClickHouseReadonlyReplica` on the same replica changes the diagnosis to Keeper
— follow those first.

## Related

- [ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) — a readonly replica lags by definition.
- [ClickHouseKeeperSessionLost](ClickHouseKeeperSessionLost.md) — the usual cause of a readonly replica.
- [ClickHouseReplicatedDataLoss](ClickHouseReplicatedDataLoss.md) — when the queue is stuck on a part nobody has.

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `ClickHouseReplicationLag`, threshold 300 s kept; per-replica from `:9363`)_
