# ClickHouseInsertsRejected

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `rate(ClickHouseProfileEvents_RejectedInserts[5m]) > 0`, `max by (replica)`, from `:9363` |
| **Status** | active — VERIFY-AT-KIND (added to the cluster 2026-09-08; the compose twin has carried it since 2026-08-13) |
| **Dashboard** | ClickHouse → Server engine (inserts row); OTel Collector (exporter queue) |
| **Local-stack** | same name, same expr, `job="clickhouse"` — this is the one ClickHouse alert that existed in compose before the cluster |

## Meaning

The `parts_to_throw_insert` guard rejected at least one INSERT on this replica
in each of the last 5 minutes. The error clients see is `Code: 252. Too many
parts`. This is the third and last link of parts → delayed → rejected;
[ClickHouseTooManyPartsPerPartition](ClickHouseTooManyPartsPerPartition.md) and
[ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md) should already be firing.

The counter is a ProfileEvent, published at zero by the server's own endpoint,
so the series exists on a healthy store and `rate() > 0` is a real test — which
is why this rule could be restored here after the exporter-based version was
deleted in August (its `chi_clickhouse_event_*` source omits zero counters and
could not prove the name).

## Impact

The OTel Collector's `clickhouse` exporter retries a rejected batch
(`retry_on_failure`) and queues behind it (`sending_queue`). While the queue
holds, nothing is lost; when it fills, batches drop and
[ClickHouseExporterUnhealthy](ClickHouseExporterUnhealthy.md) fires. Behind the
round-robin Service, a third of batches hit the sick replica, so the effect is
a slow leak rather than an outage — until the queue is full.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl -n monitoring exec <replica pod from the alert> -- clickhouse-client --password=$PW -q"

# The rejections themselves, with the table and the part count that triggered them
$CH "SELECT event_time, query_kind, tables, exception
     FROM system.query_log
     WHERE type = 'ExceptionBeforeStart' AND exception_code = 252 AND event_time > now() - INTERVAL 30 MINUTE
     ORDER BY event_time DESC LIMIT 10"

# Which partition is over the guard
$CH "SELECT database, table, partition, count() AS parts FROM system.parts WHERE active
     GROUP BY database, table, partition ORDER BY parts DESC LIMIT 5"
$CH "SELECT name, value FROM system.merge_tree_settings WHERE name IN ('parts_to_delay_insert','parts_to_throw_insert')"

# Why merges are not clearing it — see the README's merge memory workflow
$CH "SELECT table, countIf(error > 0) AS failed, count() FROM system.part_log
     WHERE event_type = 'MergeParts' AND event_time > now() - INTERVAL 1 HOUR GROUP BY table"
```

### PromQL

```promql
max by (replica) (rate(ClickHouseProfileEvents_RejectedInserts{job="clickhouse-server"}[5m]))
# Is the collector already dropping?
sum(rate(otelcol_exporter_send_failed_log_records{exporter="clickhouse"}[5m]))
otelcol_exporter_queue_size{exporter="clickhouse"}
```

## Mitigation

Same levers as [ClickHouseTooManyPartsPerPartition](ClickHouseTooManyPartsPerPartition.md),
in the same order: fix failing merges, then insert cadence, then a targeted
`OPTIMIZE TABLE ... PARTITION`. Two things specific to rejection:

1. If only one replica rejects, it is behind on merges — often the one that
   was readonly or restarted recently. Its peers keep ingesting; do not touch
   the collector.
2. Do **not** raise `parts_to_throw_insert`. It is the last guard before a
   partition becomes unqueryable.

## Escalation

Ticket while `ClickHouseExporterUnhealthy` stays quiet — the queue is
absorbing it. Page when that fires: telemetry is being dropped, and the edge
access log (ClickHouse-only, ADR-061) has no other copy.

## Related

- [ClickHouseInsertsDelayed](ClickHouseInsertsDelayed.md), [ClickHouseTooManyPartsPerPartition](ClickHouseTooManyPartsPerPartition.md) — the two links before this.
- [ClickHouseInsertsFailing](ClickHouseInsertsFailing.md) — the broader INSERT-error counter; this one is a subset of it.
- [ClickHouseExporterUnhealthy](ClickHouseExporterUnhealthy.md) — the consumer side.

---
_Last updated: 2026-09-08 — created; the cluster rule was restored from the compose twin on the `:9363` ProfileEvent after the exporter-based version was deleted 2026-08-22_
