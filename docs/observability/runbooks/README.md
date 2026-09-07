# Operational Runbooks

Runbooks for investigating, troubleshooting, and resolving incidents in the observability stack.
One folder per alert domain, one file per alert name; every alert that has a
runbook links it via its `runbook_url` annotation.

## Runbook Index

| Runbook | Purpose | When to Use |
|---------|---------|-------------|
| [Microservices runbooks](microservices/README.md) | Per-alert investigation (50 files) + cross-signal workflows, threshold tuning | On-call, when an application alert fires |
| [Envoy Gateway runbooks](envoy-gateway/README.md) | Per-alert investigation for the edge (9 files covering 11 `Edge*` / `EnvoyGateway*` alerts) | On-call, when an edge alert fires |
| [PostgreSQL runbooks](postgresql/README.md) | Per-alert CNPG runbooks (chart + deep-signal), 33 files, + the [plan-regression investigation workflow](postgresql/plan-regression-investigation.md) | On-call, when a PostgreSQL/CNPG alert fires — or a query got slower and you need the plan it ran at the time |
| [Kubernetes runbooks](kubernetes/README.md) | Per-alert investigation for pods, workloads, storage, nodes, API server, network (21 files) | On-call, when a Kubernetes infra alert fires |
| [Valkey runbooks](valkey/README.md) | Per-alert investigation for the cache (7 files) | On-call, when a Valkey alert fires |
| [ClickHouse runbooks](clickhouse/README.md) | Per-alert investigation for the OTel OLAP store — reachability, Keeper quorum, disk, insert pressure, operator (14 files) + TTL / merge-memory / `_N` leftover workflows | On-call, when a `ClickHouse*` alert fires — or a table is past its TTL window |
| [Kyverno runbooks](kyverno/README.md) | Per-alert investigation for the admission webhook (4 files) | On-call, when a Kyverno alert fires |
| [Temporal runbooks](temporal/README.md) | Per-alert investigation for the server, the versioned workers and the KEDA scaler that sizes them (9 files covering 10 rules) | On-call, when a Temporal alert fires |
| [KEDA runbooks](keda/README.md) | Per-alert investigation for the autoscaler's own health — operator scrape, external-metrics adapter scrape, scaler and ScaledObject errors (4 files) | On-call, when a `Keda*` alert fires |
| [Keycloak runbooks](keycloak/) | Per-alert investigation for the identity provider (5 files, no folder README yet) | On-call, when a Keycloak alert fires |
| [Logging troubleshooting](../logging/vector.md#troubleshooting) | Missing/blank Kubernetes logs (Vector → VictoriaLogs → Grafana) | On-call, when logs are missing in Grafana |

Not yet covered by per-alert runbooks (a recorded gap): cert-manager alerts —
they carry no `runbook_url`; the [alert catalog](../alerting/alert-catalog.md)
documents their severity and impact. (`gitops/`, `observability/` and
`victoriametrics/` folders exist but have no row here yet.)

## Runbook placement

Runbooks live **next to their domain hub** (`databases/runbooks/`, `secrets/runbooks/`,
`observability/runbooks/`). There is no central `docs/runbooks/troubleshooting/` folder.

## Runbook Structure

Every per-alert runbook follows [`_TEMPLATE.md`](_TEMPLATE.md) — the one
canonical template for all domain folders:

1. **Quick facts** — severity, category, source manifest, metrics, status, dashboard
2. **Meaning** — what fires and when
3. **Impact** — operational consequence
4. **Diagnosis** — PromQL, Grafana, kubectl/logs, VictoriaLogs/traces
5. **Mitigation** — resolution actions, cheapest first
6. **Escalation** — page-vs-ticket call and what not to do

Domain-specific rows and diagnosis dialects live in each folder README's
"Domain specifics" section, never in a forked template.

## Related Documentation

- [Alerting Strategy](../alerting/README.md) -- 2-layer alerting architecture
- [SLO System](../slo/README.md) -- SLO definitions and burn-rate alerts
- [Grafana Datasources](../grafana/datasources.md) -- how to view rules in Grafana UI
- [PostgreSQL metrics hub](../metrics/postgresql/README.md) — custom queries, workflows, learning path
- [Database HA Scaling](../../databases/reference/zalando/ha-scaling.md) — historical Zalando HA reference
- [Prepared Databases](../../databases/reference/zalando/prepared-databases.md) -- preparedDatabases issue runbook

---
_Last updated: 2026-09-07 — ClickHouse folder indexed (14 runbooks existed since 2026-09-05 with no row here). Previously 2026-09-05 — KEDA folder added (3 runbooks, ADR-055); Temporal folder indexed (it had 7 runbooks and no row here); two capacity runbooks added with ADR-055. Previously 2026-08-19 — infrastructure-alerts.md split into kubernetes/ + valkey/; one canonical template_
