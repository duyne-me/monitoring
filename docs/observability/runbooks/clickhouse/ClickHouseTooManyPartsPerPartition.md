# ClickHouseTooManyPartsPerPartition

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `ClickHouseAsyncMetrics_MaxPartCountForPartition` > 300, `max by (replica)`, from `:9363` |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; record the live `parts_to_*_insert` values in the rule comment) |
| **Dashboard** | ClickHouse → Server engine (parts and merges row) |
| **Local-stack** | same series under `job="clickhouse"`; the compose rule file has only the server-wide `ClickHouseTooManyParts` |

## Meaning

Some partition, on some table, on this replica holds more than 300 active parts
for 10 minutes. This is the dimension the insert guards actually enforce:
`parts_to_delay_insert` and `parts_to_throw_insert` count active parts in
**one partition**. [ClickHouseTooManyParts](ClickHouseTooManyParts.md) reads the
server-wide total, which is a trend — spread over ~90 daily partitions per
table it barely moves while today's partition fills up.

ClickHouse's own description of the metric says values above 300 indicate
"misconfiguration, overload, or massive data loading". Merges normally keep a
partition in the single digits.

## Impact

Nothing yet, but the chain is short: past `parts_to_delay_insert` every INSERT
sleeps ([ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md)), past
`parts_to_throw_insert` they fail with `Too many parts`
([ClickHouseInsertsRejected](ClickHouseInsertsRejected.md)), and the collector's
queue fills, then drops. Query performance on that partition also degrades —
every part is a file set to open.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- clickhouse-client --password=$PW -q"

# Which partition, which table
$CH "SELECT database, table, partition, count() AS parts, sum(rows) AS rows,
            formatReadableSize(sum(bytes_on_disk)) AS size
     FROM system.parts WHERE active GROUP BY database, table, partition
     ORDER BY parts DESC LIMIT 10"

# How far from the guards
$CH "SELECT name, value FROM system.merge_tree_settings
     WHERE name IN ('parts_to_delay_insert','parts_to_throw_insert','max_parts_in_total')"

# Are merges running, and are they failing?
$CH "SELECT table, elapsed, progress, num_parts, formatReadableSize(memory_usage) FROM system.merges"
$CH "SELECT table, countIf(error > 0) AS failed, count() AS merges, formatReadableSize(max(peak_memory_usage)) AS peak
     FROM system.part_log WHERE event_type = 'MergeParts' AND event_time > now() - INTERVAL 1 HOUR
     GROUP BY table ORDER BY failed DESC"

# Insert cadence — parts are created per INSERT, so many tiny inserts = many parts
$CH "SELECT table, count() AS inserts, avg(rows) AS avg_rows
     FROM system.part_log WHERE event_type = 'NewPart' AND event_time > now() - INTERVAL 10 MINUTE
     GROUP BY table ORDER BY inserts DESC"
```

Run the first query on all three replicas (`chi-clickhouse-otel-0-{0,1,2}-0`):
parts are local state, and a replica behind on merges holds more than its peers.

### PromQL

```promql
max by (replica) (ClickHouseAsyncMetrics_MaxPartCountForPartition{job="clickhouse-server"})
max by (replica) (rate(ClickHouseProfileEvents_FailedMerges{job="clickhouse-server"}[5m]))  # unborn until a merge fails
ClickHouseMetrics_Merge{job="clickhouse-server"}
```

## Mitigation

1. **Merges failing on memory** (`MEMORY_LIMIT_EXCEEDED` in `part_log`): the
   folder README's *Merge memory pressure* workflow — usually a wide `system.*`
   log table, not `otel.*`. Fix the table's width or the container limit.
2. **Merges not running**: check the replica is not readonly
   ([ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md)) and that the
   merge pool has room (`BackgroundMergesAndMutationsPoolSize` is 2 here).
3. **Too many tiny inserts**: the OTel Collector's `clickhouse` exporter batch
   settings (`sending_queue`, `timeout`) are the lever — bigger, less frequent
   batches. That change lives in the collector config, not in ClickHouse.
4. `OPTIMIZE TABLE otel.<table> PARTITION '<day>'` forces a merge pass on one
   partition; it is safe and reversible, but it treats the symptom.
5. Do **not** raise `parts_to_throw_insert` to make room. The guard protects
   query performance and merge memory; raising it moves the failure to reads.

## Escalation

Ticket. It becomes an incident when
[ClickHouseInsertsRejected](ClickHouseInsertsRejected.md) co-fires — telemetry
is then being dropped. Two replicas alerting at once points at the collector's
insert cadence; one replica points at that replica's merges.

## Related

- [ClickHouseTooManyParts](ClickHouseTooManyParts.md) — the server-wide trend.
- [ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md) → [ClickHouseInsertsRejected](ClickHouseInsertsRejected.md) — the next two links.

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream threshold 100; ours is 300, the value ClickHouse's own metric description calls abnormal)_
