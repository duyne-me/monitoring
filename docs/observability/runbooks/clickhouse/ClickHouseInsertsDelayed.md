# ClickHouseInsertsDelayed

| | |
|---|---|
| **Severity** | info |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `chi_clickhouse_metric_DelayedInserts > 0` |
| **Status** | active |
| **Dashboard** | ClickHouse → Data analysis |
| **Local-stack** | present — `rate(ClickHouseProfileEvents_DelayedInserts[5m]) > 0`, a counter from `system.events` (the cluster reads the `system.metrics` gauge) |

## Meaning

ClickHouse is **deliberately slowing inserts down**. When active parts pass
`parts_to_delay_insert`, the server sleeps each insert a little to give merges
time to catch up — a designed brake, applied before the hard stop at
`parts_to_throw_insert`.

Severity `info` is correct: nothing has failed. This is the engine telling you it
is under merge pressure and is protecting itself.

## Impact

Insert latency rises. The OTel Collector's clickhouse exporter absorbs this in
its `sending_queue`; if the delay persists and the queue fills, batches are
dropped — and the **edge access log is ClickHouse-only** (ADR-061), so what is
dropped from that stream has no second copy.

## Diagnosis

This alert is a symptom of part pressure, so start there:

```bash
PW=$(kubectl get secret -n monitoring clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl exec -n monitoring chi-clickhouse-otel-0-0-0 -- clickhouse-client --password=$PW"

$CH --query "SELECT table, partition, count() parts FROM system.parts
             WHERE active AND database='otel' GROUP BY 1,2 ORDER BY parts DESC LIMIT 10"
$CH --query "SELECT * FROM system.merges FORMAT Vertical"
```

Check the Collector side too — whether it is feeling it:

```promql
otelcol_exporter_queue_size{exporter="clickhouse"}
otelcol_exporter_queue_capacity{exporter="clickhouse"}
```

### PromQL

```promql
chi_clickhouse_metric_DelayedInserts > 0
max by (hostname) (chi_clickhouse_metric_PartsActive)     # the cause
```

## Mitigation

Handled by [ClickHouseTooManyParts](ClickHouseTooManyParts.md) — bigger and fewer
inserts from the Collector's `batch` processor, or relieve whatever is starving
merges. Raising `parts_to_delay_insert` removes the warning without removing the
problem and is the wrong lever.

## Escalation

Info. Escalate only if `otelcol_exporter_queue_size` is approaching capacity,
which means data loss is next.

## Related

- [ClickHouseTooManyParts](ClickHouseTooManyParts.md) — the cause.
- [ClickHouseExporterUnhealthy](ClickHouseExporterUnhealthy.md) — what firing
  next means data is actually being dropped.

---
_Last updated: 2026-09-05 — created; the clickhouse alert group had no runbooks at all_
