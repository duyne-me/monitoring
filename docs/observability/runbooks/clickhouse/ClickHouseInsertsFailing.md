# ClickHouseInsertsFailing

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `rate(ClickHouseProfileEvents_FailedInsertQuery[5m]) > 0`, `max by (replica)`, from `:9363` |
| **Status** | active — VERIFY-AT-KIND (added to the cluster 2026-09-08; the compose twin has carried it since 2026-08-13) |
| **Dashboard** | ClickHouse → Server engine (inserts row, top-N errors table) |
| **Local-stack** | same name, same expr, `job="clickhouse"` |

## Meaning

INSERT queries on this replica have been failing, for any reason, for 5
minutes. `FailedInsertQuery` is the broad net: it counts a `Too many parts`
rejection ([ClickHouseInsertsRejected](ClickHouseInsertsRejected.md)), a
readonly replica ([ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md)), a
schema that no longer matches what the collector sends, a bad password, a
memory limit hit during insert — anything that makes an INSERT return an error.

The first diagnostic step is therefore **which**. The `clickhouse-schema` Job
runs DDL only, so it does not trip this.

## Impact

Rows are refused at the door. The OTel Collector retries and queues; a cause
that does not clear on its own — a schema mismatch after a collector upgrade,
for instance — fills the queue and turns into drops
([ClickHouseExporterUnhealthy](ClickHouseExporterUnhealthy.md)). VictoriaLogs and
VictoriaTraces keep their own copies of logs and traces; the edge access log
does not exist anywhere else.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl -n monitoring exec <replica pod from the alert> -- clickhouse-client --password=$PW -q"

# Which error, how often, on which table — this decides everything that follows
$CH "SELECT exception_code, errorCodeToName(exception_code) AS name, count() AS n, any(tables) AS tables,
            substring(any(exception), 1, 200) AS sample
     FROM system.query_log
     WHERE query_kind = 'Insert' AND type IN ('ExceptionBeforeStart','ExceptionWhileProcessing')
       AND event_time > now() - INTERVAL 30 MINUTE
     GROUP BY exception_code ORDER BY n DESC"

# Who is sending them (should be only the collector's user)
$CH "SELECT user, client_name, count() FROM system.query_log
     WHERE query_kind = 'Insert' AND type != 'QueryFinish' AND event_time > now() - INTERVAL 30 MINUTE
     GROUP BY user, client_name"
```

Common codes on this platform and where they lead:

| Code | Name | Go to |
|---|---|---|
| 252 | `TOO_MANY_PARTS` | [ClickHouseInsertsRejected](ClickHouseInsertsRejected.md) |
| 242 | `TABLE_IS_READ_ONLY` | [ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) |
| 241 | `MEMORY_LIMIT_EXCEEDED` | README → *Merge memory pressure*; the insert itself is over budget |
| 16 / 47 / 53 | `NO_SUCH_COLUMN_IN_TABLE` / `UNKNOWN_IDENTIFIER` / `TYPE_MISMATCH` | schema drift — compare the collector's exporter version with `configs/clickhouse-schema/configmap-schema.yaml` |
| 516 | `AUTHENTICATION_FAILED` | the collector's credential Secret vs `clickhouse-credentials` |
| 499 | `S3_ERROR` | [ClickHouseS3Errors](ClickHouseS3Errors.md) — an insert landing on a cold-tier part |

### PromQL

```promql
max by (replica) (rate(ClickHouseProfileEvents_FailedInsertQuery{job="clickhouse-server"}[5m]))
# Break it down by code — the per-code family is born on first occurrence
topk(5, max by (__name__, replica) (rate({__name__=~"ClickHouseErrorMetric_.+", __name__!="ClickHouseErrorMetric_ALL", job="clickhouse-server"}[5m]) > 0))
```

## Mitigation

Follow the code. Two cases have no sibling runbook:

1. **Schema drift**: the collector's `clickhouse` exporter writes a fixed
   column set per version. After a collector image bump, diff the exporter's
   expected DDL against the schema ConfigMap and ship the schema change first
   (Flux chain: `clickhouse-schema` before `tracing`). Do not let the collector
   create tables (`create_schema: false` is deliberate, ADR-065).
2. **Credentials**: the collector reads `clickhouse-credentials` via ESO;
   `ClickHouseErrorMetric_AUTHENTICATION_FAILED` moving means the Secret and the
   CHI user disagree — usually a rotation that reached one side.

## Escalation

Ticket until `ClickHouseExporterUnhealthy` fires; then it is a page with a
known cause. What not to do: restart the collector to "flush" — it drops the
queue, which is the data you were trying to save.

## Related

- [ClickHouseInsertsRejected](ClickHouseInsertsRejected.md) — the too-many-parts subset.
- [ClickHouseServerErrorsElevated](ClickHouseServerErrorsElevated.md) — every error, not just inserts.
- [ClickHouseExporterUnhealthy](ClickHouseExporterUnhealthy.md) — the consumer side.

---
_Last updated: 2026-09-08 — created; the cluster rule was restored from the compose twin on the `:9363` ProfileEvent after the exporter-based version was deleted 2026-08-22_
