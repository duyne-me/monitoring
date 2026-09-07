# ClickHouseReplicatedDataLoss

| | |
|---|---|
| **Severity** | critical |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `increase(ClickHouseProfileEvents_ReplicatedDataLoss[10m]) > 0`, `max by (replica)`, from `:9363` |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; expect 3 series at 0 — ProfileEvents publish at zero) |
| **Dashboard** | ClickHouse → Server engine (replication row) |
| **Local-stack** | not present — no replication in the compose stack |

## Meaning

This replica needed a data part, asked every other replica — including the
ones currently offline, by checking their Keeper entries — and none of them
had it. ClickHouse gives up on that part and moves on. The rows it held are
gone; the only traces are this counter and a log line.

Critical at the first increment. There is no rate at which losing telemetry
rows is acceptable, and there is nothing to debounce: the event has already
happened. `increase[10m]` keeps a single increment visible for ten minutes
against a 30 s scrape.

## Impact

A window of rows is missing from one `otel.*` table on **every** replica (if
any replica still had the part, this would not have fired). For logs and
traces inside the last 7 days, VictoriaLogs and VictoriaTraces hold their own
copies and the SQL view alone has the gap. For the edge access log
(ClickHouse-only, ADR-061) and for anything older than 7 days, the rows are
gone. The size of the loss is the size of one part — usually minutes of data,
not days.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)

# 1. Which part, from the replica's log
kubectl -n monitoring logs <replica pod from the alert> --since=1h | grep -iE 'ReplicatedDataLoss|No active replica has part|not found on any replica' | tail -20

# 2. Is it really on nobody? Check every replica's active and detached parts for the name
for i in 0 1 2; do
  echo "--- 0-$i"
  kubectl -n monitoring exec chi-clickhouse-otel-0-$i-0 -- clickhouse-client --password="$PW" -q "
    SELECT 'active' AS where, name, rows FROM system.parts WHERE name = '<part>' AND active
    UNION ALL
    SELECT 'detached', name, 0 FROM system.detached_parts WHERE name = '<part>'"
done

# 3. What was lost — the partition tells you the day; part_log tells you the rows
kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- clickhouse-client --password="$PW" -q "
  SELECT event_time, event_type, table, part_name, rows, error, exception
  FROM system.part_log WHERE part_name = '<part>' ORDER BY event_time"

# 4. The queue entry that gave up
kubectl -n monitoring exec <replica pod> -- clickhouse-client --password="$PW" -q "
  SELECT table, type, new_part_name, num_tries, last_exception FROM system.replication_queue
  WHERE new_part_name = '<part>' OR last_exception LIKE '%<part>%'"
```

How a 3-replica store gets here: one replica loses its PVC (node rebuild on
local-path — the storage class has no quota and no snapshot), and by the time
it comes back the other two have already TTL-dropped or merged away the part it
was asked to fetch. Or a part was detected broken and detached on every copy.
Check `system.detached_parts` on all three: a `broken` or `ignored` prefix
there is recoverable, an absence is not.

### PromQL

```promql
max by (replica) (increase(ClickHouseProfileEvents_ReplicatedDataLoss{job="clickhouse-server"}[10m]))
max by (replica) (ClickHouseAsyncMetrics_NumberOfDetachedParts{job="clickhouse-server"})
```

## Mitigation

1. **Part found detached on some replica**: `ALTER TABLE otel.<table> ATTACH
   PART '<part>'` on that replica restores it; replication then re-distributes
   it. Read `system.detached_parts.reason` first — attaching a `broken` part
   re-breaks it.
2. **Part found nowhere**: nothing restores it. Record the table, partition
   and row count from `part_log` in the incident, and note whether
   VictoriaLogs/VictoriaTraces cover the window.
3. **Root cause is a lost PVC**: that replica is fine going forward; the loss
   is historical. Confirm `ClickHouseReplicationLag` on it clears as it
   catches up on what still exists.
4. Do **not** `DROP TABLE` and recreate on the affected replica to "clean up".
   The other replicas are the copy; a dropped replica re-fetches from them,
   and the part that is gone stays gone either way.

## Escalation

Page — this is confirmed data loss, even when small. The incident record needs
the row count and the window. If it fires on more than one part, or repeatedly,
the cause is ongoing (a disk, a broken-part storm) rather than a one-off, and
[ClickHouseDiskCritical](ClickHouseDiskCritical.md) / the node are the next
place to look.

## Related

- [ClickHouseReplicationLag](ClickHouseReplicationLag.md) — a queue stuck on a part nobody has fires this after giving up.
- [ClickHouseDiskAlmostFull](ClickHouseDiskAlmostFull.md) — the disk failure that usually precedes a lost PVC.
- [ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md) — a long quorum outage with a rolling PVC loss is the worst-case path here.

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `ClickHouseReplicatedDataLoss`, `[1m]` widened to `[10m]`)_
