# ClickHouseAllReplicasUnreachable

| | |
|---|---|
| **Severity** | critical |
| **Category** | observability |
| **Source** | `kubernetes/infra/configs/observability/metrics/prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `chi_clickhouse_metric_fetch_errors` — the **Altinity metrics-exporter's** view, 3 hostnames × 7 `fetch_type` = 21 series |
| **Status** | active |
| **Dashboard** | ClickHouse → Server engine · ClickHouse → Overview |
| **Local-stack** | present under the same name — compose has one node, so `up{job="clickhouse"} == 0` is both "all replicas" and "the server"; no operator, no exporter |

## Meaning

Every replica is failing the exporter's fetch:

```promql
count(max by (hostname) (chi_clickhouse_metric_fetch_errors) > 0)
  / count(count by (hostname) (chi_clickhouse_metric_fetch_errors)) == 1
```

`max by (hostname)` collapses the 7 fetch types per host, so the ratio is
failing-hosts over total-hosts and `== 1` means all three. This alert exists
because at 1×1 a single unreachable host *was* the store being down; with three
replicas one host is a degraded member ([ClickHouseReplicaUnreachable](ClickHouseReplicaUnreachable.md))
and only all-three is an outage.

**Read "unreachable" precisely.** The metric is the exporter's failure to query
`system.*` on a host — `fetch_type` takes `system_replicas`, `system_parts`,
`system_disks`, `system_metrics`, `system_mutations`, `system_detached_parts`.
A replica can be accepting inserts while the exporter cannot query it, and the
reverse. Confirm against the pods before declaring an outage.

**Known blind spot.** If replicas *vanish* — pods deleted, StatefulSet scaled to
zero — the series go absent rather than exceeding zero, and this alert does
**not** fire. Absence is not covered by any rule in this group. A silent
ClickHouse surface during an incident deserves:

```bash
kubectl get pods -n monitoring -l clickhouse.altinity.com/chi=clickhouse
```

## Impact

The OLAP store is unavailable for both reads and writes:

- Grafana's ClickHouse datasource fails — the 5 provisioned dashboards and any
  `trace_id` JOIN go blank.
- The OTel Collector's clickhouse exporter backpressures; its `sending_queue` and
  `retry_on_failure` absorb the outage for a while, then drop.
- **The edge access log is ClickHouse-only** (ADR-061). Unlike application logs
  and traces, it has no VictoriaLogs/VictoriaTraces copy — what is dropped here
  is gone.

Everything else keeps running. VictoriaMetrics, VictoriaLogs and VictoriaTraces
are independent sinks.

## Diagnosis

```bash
# Are the pods there at all
kubectl get pods -n monitoring -l clickhouse.altinity.com/chi=clickhouse -o wide

# The CHI's own view
kubectl get chi -n monitoring clickhouse

# Can the server answer directly, bypassing the exporter
PW=$(kubectl get secret -n monitoring clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
for i in 0 1 2; do
  kubectl exec -n monitoring chi-clickhouse-otel-0-$i-0 -- \
    clickhouse-client --password="$PW" --query "SELECT 1" && echo "  0-$i OK"
done
```

If `SELECT 1` succeeds on all three, the servers are fine and the **exporter** is
the problem — check the operator pod, and treat this as a monitoring failure
rather than a store outage.

### PromQL

```promql
# Alert expr
count(max by (hostname) (chi_clickhouse_metric_fetch_errors) > 0) / count(count by (hostname) (chi_clickhouse_metric_fetch_errors)) == 1

# Which hosts and which fetch types
max by (hostname, fetch_type) (chi_clickhouse_metric_fetch_errors) > 0
```

## Mitigation

1. **Pods missing** → the CHI should recreate them; check
   [ClickHouseOperatorDown](ClickHouseOperatorDown.md) first, because a dead
   operator cannot heal anything.
2. **Pods up, `SELECT 1` fails** → read the server logs; the usual cause on this
   platform is Keeper. See [ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md)
   — a replica that loses its Keeper session refuses writes.
3. **Pods up, `SELECT 1` works** → the exporter is the fault, not the store.
   Restarting the operator restores the metrics view without touching data.
4. Do **not** drop and recreate the `otel` database as a reflex. Schema is owned
   by the `clickhouse-schema` Job and must be dropped per replica if it is ever
   necessary — see the hub's recovery note before doing it.

## Escalation

Critical. Escalate on it, but check the three `SELECT 1` results first: an
exporter fault and a store outage look identical here and have completely
different urgency. Say which one you found.

## Related

- [ClickHouseReplicaUnreachable](ClickHouseReplicaUnreachable.md) — the
  warning-level one-of-three case this escalates from.
- [ClickHouseOperatorDown](ClickHouseOperatorDown.md) — the exporter lives with
  the operator; if it is down, this alert can fire with a healthy store.
- [ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md),
  [ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) — the Keeper-side
  causes.

---
_Last updated: 2026-09-05 — created; the clickhouse alert group had no runbooks at all_
