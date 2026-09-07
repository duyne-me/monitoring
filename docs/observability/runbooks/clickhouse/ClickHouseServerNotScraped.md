# ClickHouseServerNotScraped

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `absent(up{job="clickhouse-server"} == 1)` — the per-pod `:9363` scrape |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08) |
| **Dashboard** | ClickHouse → Server engine (every `ClickHouseMetrics_*` panel goes blank together) |
| **Local-stack** | not present — compose scrapes `:9363` under `job="clickhouse"` and `ClickHouseAllReplicasUnreachable` reads `up` there directly |

## Meaning

No target under `job="clickhouse-server"` has been up for 10 minutes: either
the PodMonitor `podmonitors/clickhouse-server.yaml` selects no pods, or every
replica's `:9363` endpoint is down. `absent()` is the only PromQL shape that
fires on **zero targets** — a bare `up == 0` needs a target to exist.

This alert exists because of what the rest of the group reads. `ReadonlyReplica`,
`ServerErrorsElevated`, `S3Errors`, `ZooKeeperExceptions`, `ReplicationLag`,
`KeeperSessionLost`, `ReplicatedDataLoss`, `InsertsRejected`, `InsertsFailing`
and `TooManyPartsPerPartition` all read only this scrape. When it goes blind
every one of them reports `state=inactive` with an empty `lastError` — the
exact signature of a healthy rule.

## Impact

None on the store itself: ClickHouse keeps ingesting and serving. The impact is
on **coverage** — ten alerts are silent, and a real replication or insert
failure during that window pages nobody. Treat it as "the ClickHouse alerting is
off" until cleared.

## Diagnosis

```bash
# Does the PodMonitor still match the pods?
kubectl -n monitoring get podmonitor clickhouse-server -o jsonpath='{.spec.selector.matchLabels}'; echo
kubectl -n monitoring get pods -l clickhouse.altinity.com/chi=clickhouse -o wide

# Does the CHI still expose the port the PodMonitor names?
kubectl -n monitoring get pods -l clickhouse.altinity.com/chi=clickhouse \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].ports[?(@.name=="metrics")].containerPort}{"\n"}{end}'

# Does the endpoint answer?
kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- wget -qO- http://127.0.0.1:9363/metrics | head -3

# vmagent's view of the job
kubectl -n monitoring port-forward svc/vmagent-vmagent 8429:8429 &
curl -s 'http://127.0.0.1:8429/api/v1/targets' | grep -o '"job":"clickhouse-server"[^}]*' | head
```

### PromQL

```promql
up{job="clickhouse-server"}                 # expect 3 series at 1
count(up{job="clickhouse-server"})          # 0 = selector problem, 3 with 0s = endpoint problem
```

## Mitigation

1. **Selector drift** (no pods matched): compare the PodMonitor's
   `matchLabels` with the CHI pod labels — an operator upgrade can change
   them. Fix the PodMonitor in git; do not patch it live.
2. **Port renamed or removed**: the CHI `podTemplate` must keep the container
   port named `metrics` on 9363 and `prometheus/port: "9363"` under
   `settings`. Both are in `configs/clickhouse/clickhouseinstallation.yaml`.
3. **Endpoint down on every replica**: that is the store being down —
   [ClickHouseAllReplicasUnreachable](ClickHouseAllReplicasUnreachable.md)
   owns it and should be firing too.
4. **vmagent** not scraping anything: `VMAgentDown` (§ VictoriaMetrics) is the
   real alert; this one is collateral.

## Escalation

Ticket, unless `ClickHouseAllReplicasUnreachable` co-fires (then it is that
page). What not to do: silence this alert while "waiting for the pods" — it is
the only thing telling you the other ten are blind.

## Related

- [ClickHouseAllReplicasUnreachable](ClickHouseAllReplicasUnreachable.md) — the
  exporter-side reachability page; this is its `:9363` twin.
- [ClickHouseOperatorDown](ClickHouseOperatorDown.md) — `up` on the operator
  job, the same idea for the other scrape.

```bash
git log --oneline -5 -- kubernetes/infra/configs/observability/metrics/podmonitors/clickhouse-server.yaml kubernetes/infra/configs/clickhouse/clickhouseinstallation.yaml
```

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `ClickHouseNodeDown` is a bare `up == 0`, which cannot see a scrape with no targets)_
