# ClickHouse Alert Runbooks

Per-alert investigation guides for the OTel OLAP store — the `otel` database on
a 1 shard × 3 replica `ClickHouseInstallation` in `monitoring`, coordinated by a
3-node Keeper (RFC-0028 / ADR-065). Only the OpenTelemetry Collector writes to it;
Grafana reads it. VictoriaLogs and VictoriaTraces keep their own 7-day copies, so
most ClickHouse alerts degrade the 90-day SQL view and the edge access log
(ClickHouse-only, ADR-061) rather than the whole telemetry plane. One file per
alert name.

| Quick facts | |
|---|---|
| Alert rules | [`prometheusrules/observability/clickhouse-alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/observability/clickhouse-alerts.yaml) |
| Alert catalog | [§8b ClickHouse](../../alerting/alert-catalog.md#8b-clickhouse-otel-olap-engine) |
| Platform hub | [docs/observability/clickhouse/README.md](../../clickhouse/README.md) — deployed schema, retention, playground |
| Engine learning | [fundamentals.md](../../clickhouse/fundamentals.md) · [schema-and-queries.md](../../clickhouse/schema-and-queries.md) |
| Design | [RFC-0028](../../../proposals/rfc/RFC-0028/) · [ADR-065](../../../proposals/adr/ADR-065-clickhouse-replicated-topology/) |

## Index

| Alert | Sev | Source | Status | Runbook |
|-------|-----|--------|--------|---------|
| ClickHouseAllReplicasUnreachable | critical | homelab | active | [ClickHouseAllReplicasUnreachable.md](ClickHouseAllReplicasUnreachable.md) |
| ClickHouseReplicaUnreachable | warning | homelab | active | [ClickHouseReplicaUnreachable.md](ClickHouseReplicaUnreachable.md) |
| ClickHouseKeeperNoLeader | critical | homelab | active | [ClickHouseKeeperNoLeader.md](ClickHouseKeeperNoLeader.md) |
| ClickHouseKeeperQuorumDegraded | warning | homelab | active | [ClickHouseKeeperQuorumDegraded.md](ClickHouseKeeperQuorumDegraded.md) |
| ClickHouseZooKeeperExceptions | warning | homelab | active | [ClickHouseZooKeeperExceptions.md](ClickHouseZooKeeperExceptions.md) |
| ClickHouseReadonlyReplica | warning | homelab | active | [ClickHouseReadonlyReplica.md](ClickHouseReadonlyReplica.md) |
| ClickHouseDiskAlmostFull | warning | homelab | active | [ClickHouseDiskAlmostFull.md](ClickHouseDiskAlmostFull.md) |
| ClickHouseDiskCritical | critical | homelab | active | [ClickHouseDiskCritical.md](ClickHouseDiskCritical.md) |
| ClickHouseTooManyParts | warning | homelab | active | [ClickHouseTooManyParts.md](ClickHouseTooManyParts.md) |
| ClickHouseInsertsDelayed | info | homelab | active | [ClickHouseInsertsDelayed.md](ClickHouseInsertsDelayed.md) |
| ClickHouseServerErrorsElevated | info | homelab | active | [ClickHouseServerErrorsElevated.md](ClickHouseServerErrorsElevated.md) |
| ClickHouseExporterUnhealthy | warning | homelab | active | [ClickHouseExporterUnhealthy.md](ClickHouseExporterUnhealthy.md) |
| ClickHouseOperatorDown | warning | homelab | active | [ClickHouseOperatorDown.md](ClickHouseOperatorDown.md) |
| ClickHouseOperatorReconcileErrors | warning | homelab | active | [ClickHouseOperatorReconcileErrors.md](ClickHouseOperatorReconcileErrors.md) |

Rows are grouped by the failure they describe — reachability, quorum, disk,
insert pressure, the collector's view, the operator — not by severity. Count the
rule file, not this table: the catalog's count is re-derived from `- alert:`
occurrences.

## Domain specifics

- **Diagnosis dialect:** open a `clickhouse-client` on any replica *first*, then
  PromQL. The engine's own `system.*` tables answer most questions faster and
  more precisely than any exported series:
  ```bash
  PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- clickhouse-client --password "$PW" -q "SELECT 1"
  ```
  Replicas are `chi-clickhouse-otel-0-{0,1,2}-0`; the round-robin Service is
  `clickhouse-clickhouse.monitoring.svc:9000` (native) / `:8123` (HTTP).
- **Four metric producers, four label sets.** Know which one an alert reads
  before trusting a `by (...)`:

  | Producer | Scrape | Families | Identifies a replica by |
  |---|---|---|---|
  | metrics-exporter (Altinity) | operator Service `:8888/chi`, chart ServiceMonitor | `chi_clickhouse_metric_*`, `chi_clickhouse_event_*`, disks, parts | `hostname` — aggregated per CHI, so it cannot say *which* replica is sick |
  | operator control plane | operator Service `:8888/metrics` | `clickhouse_operator_*` | — |
  | server's own endpoint | per pod `:9363`, `podmonitors/clickhouse-server.yaml` | `ClickHouseMetrics_*`, `ClickHouseProfileEvents_*`, `ClickHouseAsyncMetrics_*`, `ClickHouseErrorMetric_*` | `replica` (`job="clickhouse-server"`) |
  | Keeper quorum | per pod `:7000`, chart `keeperMetrics` ServiceMonitor | `ClickHouseAsyncMetrics_Keeper*` | `pod` (`job="keeper-keeper"`, **no** `replica` label) |

  `chi_clickhouse_event_*` is built from `system.events`, which omits any counter
  still at zero — the absence of a series there proves nothing about the name.
  Add a `job=` selector whenever a family exists on both `:9363` and `:7000`.
- **Dashboards:** ClickHouse → *Server engine* (the `chi_*` / `ClickHouseMetrics_*`
  dual-target board), ClickHouse → *Overview* and *Data analysis* (SQL panels on
  `otel.*`), OTel Collector (exporter queue and `send_failed_*`).
- **Disk alerts measure the node, not the PVC.** `standard` is rancher
  local-path, a hostPath with no quota, so `DiskFreeBytes / DiskTotalBytes` is
  the Kind node filesystem (~507 GiB) and the 10Gi PVC request enforces nothing.
  `du -sh /var/lib/clickhouse` inside the pod is the number that means
  "ClickHouse".
- **Local-stack divergence:** compose runs one node with no operator, no
  exporter and no Keeper, and reads the server's `:9363` families directly
  (`local-stack/observability/vmalert/rules/clickhouse.yaml`). Reachability,
  disk, parts, delayed inserts and error-rate alerts exist under the same names
  so their runbooks transfer; the replication and operator rules do not exist
  there. The compose collector also owns the schema (`create_schema: true`); on
  the cluster the `clickhouse-schema` Job does, and a wrong schema fails that Job
  loudly rather than a dashboard quietly.

## Investigation workflows

Cross-alert procedures that no single rule owns. Each was exercised on the
Kind cluster during the 2026-09-07 audit ([#1025](https://github.com/duynhlab/homelab/issues/1025)).

### Is TTL keeping up?

`otel.*` partitions are calendar days with a 90-day TTL and `ttl_only_drop_parts = 1`,
so a healthy table holds at most 91–92 active partitions and expiry is a whole-part
drop. TTL is applied by background merges, not a scheduler: on a quiet table the
next pass waits `merge_with_ttl_timeout` (14400 s, unchanged here).

```sql
-- oldest active partition per table; age > 92 days means TTL merges are not running
SELECT database, table, min(partition) AS oldest, uniqExact(partition) AS partitions,
       dateDiff('day', toDate(min(partition)), today()) AS age_days
FROM system.parts WHERE active AND database IN ('otel', 'system')
GROUP BY database, table ORDER BY age_days DESC;

-- has a TTL merge ever run?  merge_reason = 'TTLDeleteMerge' / 'TTLRecompressMerge'
SELECT merge_reason, count() FROM system.part_log WHERE event_type = 'MergeParts' GROUP BY merge_reason;

-- anything in flight right now
SELECT table, elapsed, progress, merge_type FROM system.merges;

-- the two knobs that can starve it: pool size vs the TTL-merge cap
SELECT metric, value FROM system.metrics WHERE metric = 'BackgroundMergesAndMutationsPoolSize';
SELECT name, value, changed FROM system.merge_tree_settings
WHERE name IN ('merge_with_ttl_timeout', 'max_number_of_merges_with_ttl_in_pool', 'ttl_only_drop_parts');
```

If a table is past its window: check `ClickHouseReadonlyReplica` (a read-only
replica merges nothing), disk, then force one pass with
`ALTER TABLE otel.otel_traces MATERIALIZE TTL` or drop the oldest day by hand
with `ALTER TABLE ... DROP PARTITION '2026-06-01'`. Measured 2026-09-07:
`BackgroundMergesAndMutationsPoolSize = 2` on this cluster against an upstream
default of 16, and `max_number_of_merges_with_ttl_in_pool = 2` — TTL merges can
take the whole pool. Whether to raise the pool is a sizing decision, not an
on-call action.

### Merge memory pressure

Merge memory scales with **column count**, not table size. `system.metric_log`
(~1,900 columns wide) produced 99.5 % of all failed merges during the
2026-09-06 incident, every one `Code: 241 MEMORY_LIMIT_EXCEEDED`, at a peak of
1.45 GiB against the server's 1.80 GiB self-cap (0.9 × the 2Gi container limit).

```sql
-- who is failing, and how much memory does one merge take
SELECT table, count() AS merges, countIf(error > 0) AS failed,
       formatReadableSize(max(peak_memory_usage)) AS peak
FROM system.part_log
WHERE event_type = 'MergeParts' AND event_time > now() - INTERVAL 1 DAY
GROUP BY table ORDER BY failed DESC, peak DESC;

-- the budget those peaks are measured against
SELECT name, value FROM system.server_settings
WHERE name IN ('max_server_memory_usage', 'max_server_memory_usage_to_ram_ratio');
SELECT metric, value FROM system.asynchronous_metrics WHERE metric = 'CGroupMemoryTotal';
```

Levers, cheapest first: fewer rows (`collect_interval_milliseconds`), fewer
columns (`metric_log` `<schema_type>transposed_with_wide_view</schema_type>`),
then the container limit. A retry storm looks like load but is not: insert rate
flat, merges/hour ×15, `error > 0` on almost all of them.

### After changing a system table's engine: drop the `_N` leftovers

Changing a `system.*` log table's engine definition in the CHI does **not**
`ALTER` it. On the table's next write ClickHouse renames the old table to
`<name>_N` and creates a fresh one; the renamed copy keeps every row and has
**no TTL**. The rename is lazy and per replica, so one pass straight after apply
misses tables that have not been written to yet.

```sql
SELECT name, formatReadableSize(total_bytes) AS size, total_rows
FROM system.tables WHERE database = 'system' AND match(name, '_log_[0-9]+$');
-- then, per replica:  DROP TABLE system.<name>_N
```

Match `_log_[0-9]+$`, not `LIKE '%\_0'` — a previous cleanup missed
`trace_log_1` holding 153 MiB. Run it again a few hours later.

### Which disk is the alert measuring?

```bash
kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- sh -c 'du -sh /var/lib/clickhouse; df -h /var/lib/clickhouse'
```
```sql
SELECT name, type, formatReadableSize(total_space) AS total, formatReadableSize(free_space) AS free FROM system.disks;
```

`df` and `system.disks` show the node filesystem; `du` shows what ClickHouse
holds. When the two disagree by orders of magnitude the alert is about the node,
and the fix is on the node (or in another workload), not in ClickHouse.

## Template

New runbooks follow [`_TEMPLATE.md`](../_TEMPLATE.md) (Meaning → Impact →
Diagnosis → Mitigation → Escalation). In this folder the Diagnosis section leads
with a `clickhouse-client` block, then `### PromQL`.

---
_Last updated: 2026-09-07 — folder README created; the 14 per-alert files existed since 2026-09-05 with no index. Investigation workflows distilled from the #1025 live audit_
