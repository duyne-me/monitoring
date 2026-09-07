# ClickHouseTooManyParts

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `chi_clickhouse_metric_PartsActive > 300` |
| **Status** | active · currently ~98 on a loaded cluster |
| **Dashboard** | ClickHouse → Data analysis |
| **Local-stack** | present — `ClickHouseMetrics_PartsActive > 300` from the server's `:9363` endpoint |

## Meaning

Active parts exceeded **300** for 10 minutes. ClickHouse's own
`parts_to_throw_insert` default is 300 **per partition**; this alert watches the
table-wide count instead, so it is an earlier, blunter signal than the point at
which inserts actually start failing.

Each insert batch creates a part; background merges combine them. A rising part
count means **inserts are arriving faster than merges retire them**, which has
exactly two shapes: too many small inserts, or merges that cannot keep up.

## Impact

Nothing fails at first — queries just read more parts, so they get slower. If the
count keeps climbing, ClickHouse first delays inserts
([ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md)) and then rejects them.
On-disk size also inflates, because small parts compress worse than merged ones.

## Diagnosis

```bash
PW=$(kubectl get secret -n monitoring clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl exec -n monitoring chi-clickhouse-otel-0-0-0 -- clickhouse-client --password=$PW"

# Which table, and how parts are distributed across partitions
$CH --query "
  SELECT table, partition, count() AS parts, sum(rows) AS rows,
         formatReadableSize(sum(bytes_on_disk)) AS disk
  FROM system.parts WHERE active AND database='otel'
  GROUP BY table, partition ORDER BY parts DESC LIMIT 15"

# Are merges running, or stuck
$CH --query "SELECT table, elapsed, progress, is_mutation, num_parts FROM system.merges"

# Is a merge failing repeatedly
$CH --query "
  SELECT table, count() n, any(exception) FROM system.part_log
  WHERE event_time > now() - INTERVAL 1 HOUR AND error != 0 GROUP BY table"
```

`system.parts`, `system.merges` and `system.part_log` are **per-replica** — a
problem on one replica will not appear if you only ask another.

### PromQL

```promql
chi_clickhouse_metric_PartsActive > 300
max by (hostname) (chi_clickhouse_metric_PartsActive)
```

## Mitigation

1. **Small-insert shape** → fix it at the Collector, not at ClickHouse. The
   `batch` processor's size and timeout decide how big each insert is; bigger and
   fewer is the correct direction.
2. **Merge starvation** → check CPU on the replica and whether merges are
   erroring in `system.part_log`. A replica that is CPU-starved merges slowly.
3. **Cross-check the TTL work.** `ttl_only_drop_parts = 1` on the `otel.*` tables
   means TTL drops whole day-partitions rather than rewriting parts, so TTL is
   *not* a source of merge pressure there. The `system.*` tables use the default
   `0` and do rewrite — see the hub's
   [Partitions and TTL](../../clickhouse/fundamentals.md#the-alignment-rule).
4. `OPTIMIZE TABLE … FINAL` is a last resort, not a routine fix: it forces a full
   merge and will make CPU and disk worse before better.

## Escalation

Warning. Escalate if it is climbing rather than flat, or if
`ClickHouseInsertsDelayed` joins it — that is the ordered path to insert failure.

## Related

- [ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md) — the next step.
- [ClickHouseDiskAlmostFull](ClickHouseDiskAlmostFull.md) — unmerged parts inflate
  disk.

---
_Last updated: 2026-09-05 — created; the clickhouse alert group had no runbooks at all_
