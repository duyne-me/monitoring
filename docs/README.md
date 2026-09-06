# Documentation Index

Documentation for the **duynhlab microservices platform** — 10 Go services + a React storefront + a back-office portal (Keycloak as the identity provider), with GitOps (Flux Operator), observability, databases, secrets, and the RFC/ADR design record.

---

## Documentation Structure

```
docs/
├── api/                          # API surface, service contracts, and workflow guides
│   ├── README.md                 # Area hub and recommended learning path
│   ├── api.md                    # Canonical shared HTTP + gRPC conventions and call graph
│   ├── microservices.md          # Feature ownership, techniques, dependencies, known gaps
│   ├── identity.md               # Identity contract — two realms, edge vs in-service verification, OIDC_* env, sub as user_id
│   ├── admin.md                  # Consumer index: what the Backoffice portal calls (not a contract)
│   ├── auth.md                   # Archived — the retired token issuer's contract (RFC-0024 P5)
│   ├── user.md                   # User profile contract
│   ├── product.md                # Catalog, price gRPC contract, aggregation
│   ├── cart.md                   # Cart HTTP contract + checkout gRPC read
│   ├── order.md                  # Order HTTP/gRPC contract + Saga handoff
│   ├── review.md                 # Review HTTP/gRPC contract
│   ├── notification.md           # Inbox and delivery contracts
│   ├── shipping.md               # Tracking, quotes, shipment gRPC contract
│   ├── checkout.md               # P1-P5 checkout subsystem; P6 planned
│   ├── payments.md               # Payment contract, ledger, reconciliation
│   ├── inventory.md              # Inventory gRPC contract — the sole stock authority
│   ├── graceful-shutdown.md      # Cross-service shutdown contract (drain, timeouts)
│   ├── caching.md                # Cache-Aside app contract: keys, TTLs, invalidation
│   ├── pkg.md                     # Which shared Go modules exist and how they layer
│   ├── workflows.md              # Temporal workflow registry: owners, workers, queues
│   ├── temporal.md               # 3 Temporal workflows as built + saga vs 2PC + ops
│   ├── observability.md          # What a service must emit, and where it lands
│   ├── metrics.md                # App metric contract (names, labels, semconv)
│   ├── logs.md                   # Structured log contract + trace correlation
│   ├── tracing.md                # Span contract, propagation, sampling
│   ├── profiling.md              # Profiling contract (pkg/obsx, Pyroscope labels)
│   └── _template-service.md      # v2 template for a new service contract
├── frontend/                     # Browser apps at the platform layer (build, expose, watch)
│   ├── README.md                 # Area hub: storefront + admin portal, the build-arg contract
│   └── admin-portal/             # The operator portal in depth
│       └── README.md             # Staff realm fence, edge exposure, delivery, gaps
├── proposals/                    # Design proposals & decisions
│   ├── README.md                 # umbrella: ADR vs RFC + flow + links
│   ├── adr/                      # Architecture Decision Records
│   │   ├── README.md             # ADR conventions + index
│   │   ├── ADR-0000-template/    # template
│   │   └── ADR-001 … ADR-065     # 65 records; status per record in the ADR index
│   ├── rfc/                      # Requests for Comments
│   │   ├── README.md             # process + index + backlog
│   │   ├── RFC-0000/             # template (research.md + README.md)
│   │   └── RFC-0001 … RFC-0027   # 26 records; reserve number → research.md → README.md
├── databases/                    # Database documentation
│   ├── README.md                 # Learn / understand / operate / reference hub
│   ├── architecture.md           # Current cluster and connection topology
│   ├── cloudnativepg.md          # Current operator boundary
│   ├── backup-policy.md          # Current schedules, retention, object paths
│   ├── disaster-recovery.md      # Recovery policy and DR topology
│   ├── reliability-targets.md    # RPO/RTO targets and evidence
│   ├── poolers.md                # Current PgBouncer and PgDog inventory
│   ├── extensions.md             # Current extension policy and inventory
│   ├── fundamentals/             # Vendor-neutral PostgreSQL learning path
│   ├── runbooks/                 # Current task-focused procedures
│   └── reference/                # Comparisons and historical learning notes
├── observability/                # Observability documentation
│   ├── README.md                 # Master index + 4-pillar architecture
│   ├── opentelemetry/             # OTel instrumentation, transport, and migration learning
│   │   ├── README.md              # Canonical policy + current platform behavior
│   │   ├── fundamentals.md        # OTel primer: API vs SDK, signals, OTLP, propagation + RFC-0014 migration story
│   │   └── collector.md           # Collector deep dive: components, patterns, deployed pipelines
│   ├── metrics/                  # Pillar 1: Metrics
│   │   ├── README.md             # Hub: fundamentals, stack, architecture, coverage
│   │   ├── metrics-apps.md       # Application + gRPC east-west metrics (RED)
│   │   ├── metrics-catalog.md    # Lookup catalog — all emitted series incl. 34 business metrics
│   │   ├── metrics-infra.md      # Cluster / infrastructure metrics (USE)
│   │   ├── victoriametrics.md    # VictoriaMetrics Operator stack (incl. VMAuth planned)
│   │   ├── promql-guide.md       # PromQL reference
│   │   ├── histograms.md         # Histogram & temporality fundamentals
│   │   ├── streaming-aggregation.md  # VictoriaMetrics stream aggregation (vmagent)
│   │   └── postgresql/           # PostgreSQL-specific metrics (databases layer)
│   │       ├── README.md
│   │       ├── builtin-metrics.md
│   │       └── custom-metrics.md
│   ├── tracing/                  # Pillar 2: Distributed Tracing
│   │   ├── README.md             # Tracing guide (VictoriaTraces + OTel)
│   │   ├── architecture.md       # Trace topology: VictoriaTraces + ClickHouse
│   │   ├── jaeger.md             # Jaeger — archived (retired, RFC-0027)
│   │   ├── backends-comparison.md # Why VictoriaTraces + ClickHouse won
│   │   └── victoriatraces.md     # VictoriaTraces pilot (3rd backend)
│   ├── logging/                  # Pillar 3: Structured Logging
│   │   └── README.md             # Platform pipeline (VictoriaLogs + Vector)
│   ├── profiling/                # Pillar 4: Continuous Profiling
│   │   └── README.md             # Pyroscope (CPU, heap, goroutine)
│   ├── clickhouse/               # ClickHouse OTel logs+traces OLAP (deployed)
│   │   └── README.md             # OLAP fundamentals, MergeTree, schema + ops, Grafana chapter
│   ├── grafana/                  # Visualization layer
│   │   ├── README.md             # Grafana overview + plugins
│   │   ├── rbac-multi-team.md    # Staff-SSO group→role mapping (ADR-062), Teams, folder permissions
│   │   ├── datasources.md        # Dual datasource strategy (case study)
│   │   ├── dashboard-reference.md # Microservices dashboard (~41 panels)
│   │   └── variables.md          # Dashboard variables & regex
│   ├── alerting/                 # Alerting rules
│   │   ├── README.md             # 2-layer alerting strategy
│   │   ├── alert-catalog.md      # Full alert reference + coverage gaps
│   │   ├── slo-burn-rate-alerts.md # Multi-window burn-rate alerts
│   │   └── dashboard-comparison.md
│   ├── slo/                      # Service Level Objectives
│   │   ├── README.md             # Sloth Operator + SLO targets
│   │   ├── fundamentals.md       # SLI/SLO/error-budget concepts
│   │   ├── getting_started.md    # Enable SLO via Helm values
│   │   ├── error_budget_policy.md
│   │   └── annotation-driven-slo-controller.md
│   └── runbooks/                 # Operational runbooks
│       ├── README.md             # Runbook index
│       ├── _TEMPLATE.md          # Canonical per-alert runbook template
│       ├── envoy-gateway/               # Edge per-alert runbooks
│       ├── microservices/               # Per-alert runbooks (50 alerts)
│       ├── postgresql/                  # Per-alert CNPG runbooks
│       ├── kubernetes/                  # K8s infra per-alert runbooks
│       └── valkey/                      # Cache per-alert runbooks
├── caching/                     # Valkey cache: Cache-Aside, eviction policies, distributed-cache concept
│   └── README.md                 # Valkey platform hub (eviction, ops)
├── platform/                     # Platform/deployment documentation
│   ├── README.md                 # Platform hub — deployed vs planned, doc map, Flux summary
│   ├── setup.md                  # GitOps deployment guide (+ seed data & demo accounts)
│   ├── kind-e2e-audit.md         # The Kind cluster gate — K0–K6 audit runbook (twin of the Compose gate)
│   ├── gke-internal-dns.md       # GKE cluster.local, Cloud DNS private zones, multi-environment
│   ├── application-delivery.md    # ResourceSet patterns & templates
│   ├── cicd.md                   # CI/CD pipelines + standard/policy (pinning, permissions, signing, GoReleaser)
│   ├── gitflow.md                # Git branching & release standard
│   ├── sonarcloud.md             # SonarCloud integration
│   ├── envoy-gateway.md          # Platform edge — Gateway API resource model, both provider modes, edge telemetry
│   ├── worker-autoscaling.md     # KEDA + Worker Controller: who owns replicas, backlog signal, the alert traps a drill found
│   ├── keycloak.md               # Identity provider — deployment, realm import, database, reset, signals, gaps
│   ├── kong-gateway.md           # Archived — the platform's previous API gateway
│   ├── kyverno.md                # Kyverno admission-policy platform guide
│   ├── mcp-servers.md            # 4 MCP servers wired into the platform
│   └── ruleset-automation.md     # GitHub ruleset automation
├── secrets/                      # Secrets, TLS & trust distribution (one chain)
│   ├── README.md                 # Homelab secrets/TLS/trust hub
│   ├── openbao.md                # OpenBAO HA/Raft architecture and learning notes
│   ├── runbooks/                 # Add, rotate, bootstrap, troubleshoot secrets
│   └── cert-manager.md           # cert-manager + Let's Encrypt + trust-manager (§11 CA bundle)
│                                 # (production hardening → README § Current boundaries + RFC-0008)
├── security/                     # Admission control & network segmentation
│   ├── README.md                 # Security hub: the two fences (admission + network)
│   ├── policy-catalog.md         # Kyverno ClusterPolicy catalog (tiers, modes, NetworkPolicy generate)
│   ├── policy-exceptions.md      # PolicyException register (owner + TTL)
│   └── network-policies.md       # East-west NetworkPolicy caller matrix + topology diagram
└── testing/                      # Test strategy: the k6 assertion layer behind both E2E gates
    └── k6.md                     # Suites, GATE=compose|kind, and which runbook row each asserts
```

---

## Learning Path

### Getting Started (New Users)

1. **[Repositories](#repositories)** - Polyrepo index: GitHub links, images, and CI badges
2. **[Platform hub](./platform/README.md)** - Deployed vs planned, doc map, Flux summary
3. **[Setup Guide](./platform/setup.md)** - Complete GitOps deployment guide
   - Quick start (3 commands, 5 minutes)
   - GitOps architecture with Flux Operator
   - Simplified structure (infra/ + apps/, refactored 2026-01-12)
   - Multi-environment support
   - Step-by-step instructions
   - Troubleshooting common issues

4. **[API area hub](./api/README.md)** - How the api docs fit together (routes / payloads / catalog / subsystems)

5. **[Shared API and communication guide](./api/api.md)** - URL model, audiences, common contracts, service index, and gRPC runtime

6. **[GKE internal & private DNS](./platform/gke-internal-dns.md)** - `cluster.local`, Cloud DNS private zones, multi-environment naming (reference — not homelab)

## Repositories

Polyrepo layout: application code lives in separate GitHub repositories; this
repo (`homelab`) is the Infrastructure & GitOps hub. API contracts:
[api/README.md § Service contracts](./api/README.md#service-contracts).

### Infrastructure and shared libraries

| Component | Repository | Description | CI |
|-----------|------------|-------------|-----|
| **Infrastructure** | [duynhlab/homelab](https://github.com/duynhlab/homelab) | GitOps, K8s manifests, docs | [![CI](https://github.com/duynhlab/homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/duynhlab/homelab/actions) |
| **Helm Charts** | [duynhlab/helm-charts](https://github.com/duynhlab/helm-charts) | `mop` chart — OCI `ghcr.io/duynhlab/helm-charts/mop` | [![CI](https://github.com/duynhlab/helm-charts/actions/workflows/e2e.yml/badge.svg)](https://github.com/duynhlab/helm-charts/actions) |
| **Shared Workflows** | [duynhlab/gha-workflows](https://github.com/duynhlab/gha-workflows) | Reusable GitHub Actions | [![CI](https://github.com/duynhlab/gha-workflows/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/duynhlab/gha-workflows/actions) |
| **Common Lib** | [duynhlab/pkg](https://github.com/duynhlab/pkg) | Shared Go packages — summary + bump ledger in [docs/api/pkg.md](./api/pkg.md) | [![CI](https://github.com/duynhlab/pkg/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/pkg/actions) |

### Microservices and frontend

| Service | Repository | Contract | Image | CI |
|---------|------------|----------|-------|-----|
| Auth (**Archived**) | [auth-service](https://github.com/duynhlab/auth-service) (archived) | [auth.md](./api/auth.md) | — (retired RFC-0024 P5) | — |
| User | [user-service](https://github.com/duynhlab/user-service) | [user.md](./api/user.md) | `ghcr.io/duynhlab/user-service/user-service` | [![CI](https://github.com/duynhlab/user-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/user-service/actions) |
| Product | [product-service](https://github.com/duynhlab/product-service) | [product.md](./api/product.md) | `ghcr.io/duynhlab/product-service/product-service` | [![CI](https://github.com/duynhlab/product-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/product-service/actions) |
| Inventory | [inventory-service](https://github.com/duynhlab/inventory-service) | [inventory.md](./api/inventory.md) | `ghcr.io/duynhlab/inventory-service/inventory-service` | [![CI](https://github.com/duynhlab/inventory-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/inventory-service/actions) |
| Cart | [cart-service](https://github.com/duynhlab/cart-service) | [cart.md](./api/cart.md) | `ghcr.io/duynhlab/cart-service/cart-service` | [![CI](https://github.com/duynhlab/cart-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/cart-service/actions) |
| Order | [order-service](https://github.com/duynhlab/order-service) | [order.md](./api/order.md) | `ghcr.io/duynhlab/order-service/order-service` | [![CI](https://github.com/duynhlab/order-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/order-service/actions) |
| Review | [review-service](https://github.com/duynhlab/review-service) | [review.md](./api/review.md) | `ghcr.io/duynhlab/review-service/review-service` | [![CI](https://github.com/duynhlab/review-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/review-service/actions) |
| Notification | [notification-service](https://github.com/duynhlab/notification-service) | [notification.md](./api/notification.md) | `ghcr.io/duynhlab/notification-service/notification-service` | [![CI](https://github.com/duynhlab/notification-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/notification-service/actions) |
| Shipping | [shipping-service](https://github.com/duynhlab/shipping-service) | [shipping.md](./api/shipping.md) | `ghcr.io/duynhlab/shipping-service/shipping-service` | [![CI](https://github.com/duynhlab/shipping-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/shipping-service/actions) |
| Checkout | [checkout-service](https://github.com/duynhlab/checkout-service) | [checkout.md](./api/checkout.md) | `ghcr.io/duynhlab/checkout-service/checkout-service` | [![CI](https://github.com/duynhlab/checkout-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/checkout-service/actions) |
| Payment | [payment-service](https://github.com/duynhlab/payment-service) | [payments.md](./api/payments.md) | `ghcr.io/duynhlab/payment-service/payment-service` | [![CI](https://github.com/duynhlab/payment-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/payment-service/actions) |
| Frontend | [frontend](https://github.com/duynhlab/frontend) | [frontend/](./frontend/README.md) — platform view; no API contract of its own | `ghcr.io/duynhlab/frontend/frontend` | [![CI](https://github.com/duynhlab/frontend/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/frontend/actions) |
| Backoffice portal | [admin-service](https://github.com/duynhlab/admin-service) | [frontend/admin-portal/](./frontend/admin-portal/README.md) — operator SPA; the reads it calls are in each service's contract | `ghcr.io/duynhlab/admin-service/admin-service` | [![CI](https://github.com/duynhlab/admin-service/actions/workflows/build.yml/badge.svg)](https://github.com/duynhlab/admin-service/actions) |

Clone all repositories: [platform/setup.md](./platform/setup.md).

### Observability

#### Metrics

1. **[Metrics Guide](./observability/metrics/README.md)** - Complete metrics documentation
   - 4 custom application metrics (RED method)
   - 40 data panels across 6 row groups in the Grafana dashboard
   - Exemplars, path normalization, auto-discovery

2. **[PromQL Guide](./observability/metrics/promql-guide.md)** - Complete guide to PromQL functions
   - `rate()` vs `increase()` functions
   - Counter resets handling
   - Time range vs rate interval
   - Best practices and troubleshooting

3. **[PostgreSQL metrics hub](./observability/metrics/postgresql/README.md)** - CNPG custom queries, workflows, signal guides

4. **[PostgreSQL alert runbooks](./observability/runbooks/postgresql/README.md)** - Per-alert CNPG investigation (33 files)

4b. **[Microservices alert runbooks](./observability/runbooks/microservices/README.md)** - Per-alert RED/Golden investigation (50 files) + cross-signal workflows and threshold tuning

5. **[Variables & Regex](./observability/grafana/variables.md)** - Dashboard variable patterns
   - Filter configurations
   - Multi-select patterns

4. **[Grafana Dashboard Guide](./observability/grafana/dashboard-reference.md)** - Complete dashboard reference for SRE/DevOps
    - All panels with query analysis and troubleshooting
    - PromQL patterns and best practices (Google SRE, Prometheus docs)
    - Before/After comparisons for updated panels (Status Code, Apdex, 4xx/5xx)
    - SRE runbooks and incident response scenarios
    - Grafana Annotations planning (planned feature)

#### Service Level Objectives (SLO)

1. **[SLO Documentation](./observability/slo/README.md)** - Complete SLO system overview
   - Architecture (Helm chart auto-generation)
   - SLI definitions and PromQL queries
   - SLO targets and error budgets

2. **[SLO Getting Started](./observability/slo/getting_started.md)** - Enable SLOs via Helm values
   - `slo.enabled: true` in HelmRelease
   - Per-service target overrides
   - Verification checklist

3. **[SLO Burn-Rate Alerts](./observability/alerting/slo-burn-rate-alerts.md)** - Alert configuration and runbooks
4. **[Error Budget Policy](./observability/slo/error_budget_policy.md)** - Budget management guidelines
5. **[Annotation-Driven Controller](./observability/slo/annotation-driven-slo-controller.md)** - Future approach for large-scale automation

#### Observability (4 Pillars)

1. **[Observability Overview](./observability/README.md)** - Master index, 4-pillar architecture
   - **[OTel fundamentals](./observability/opentelemetry/fundamentals.md)** - what OTel is: API vs SDK, signals, OTLP transport, propagation & baggage + the RFC-0014 old-vs-new migration story (start here if new)
   - **[OpenTelemetry (platform)](./observability/opentelemetry/README.md)** - Collector topology, sampling, operations (app policy → [api/observability.md](./api/observability.md))
   - **[OpenTelemetry Collector](./observability/opentelemetry/collector.md)** - component model, deployment patterns, the deployed pipelines
   - **[Histograms & temporality](./observability/metrics/histograms.md)** - bucket mechanics, explicit vs exponential, delta vs cumulative
    - Metrics, Tracing, Logging, Profiling
    - Component inventory and correlation workflow
    - Deployment and quick start

2. **[Distributed Tracing](./observability/tracing/README.md)** - the VictoriaTraces + ClickHouse fan-out, end to end
3. **[Tracing Architecture](./observability/tracing/architecture.md)** - Trace topology: VictoriaTraces (7d) + ClickHouse (90d)
4. **[Jaeger (archived)](./observability/tracing/jaeger.md)** - Frozen history: the in-memory store, and why the Jaeger *query API* outlived the deployment ([RFC-0027](./proposals/rfc/RFC-0027/README.md))
5. **[Tempo (archived)](./observability/tracing/tempo.md)** - Frozen history: why Tempo ran twice, what its metrics-generator did, and why it was retired ([RFC-0027](./proposals/rfc/RFC-0027/README.md))
6. **[Backend Comparison](./observability/tracing/backends-comparison.md)** - why VictoriaTraces + ClickHouse won, and what retiring Tempo cost
7. **[VictoriaTraces (pilot)](./observability/tracing/victoriatraces.md)** - 3rd backend via the VM operator
8. **[Continuous Profiling](./observability/profiling/README.md)** - Pyroscope setup
9. **[ClickHouse OTel OLAP](./observability/clickhouse/README.md)** - Deployed supplementary OLAP; OTel logs/traces SQL + [Grafana chapter](./observability/clickhouse/README.md#grafana) (dashboard suite, Explore, linking) ([RFC-0019](./proposals/rfc/RFC-0019/))
    - [Fundamentals](./observability/clickhouse/fundamentals.md) - OLAP vs LogsQL, MergeTree, deployed 1×3
    - [Schema and queries](./observability/clickhouse/schema-and-queries.md) - ORDER BY, EXPLAIN granules, codecs
    - [Materialized views](./observability/clickhouse/materialized-views.md) - incremental `TO` trace-id table
10. **[Logging](./observability/logging/README.md)** - Hub: OTLP app logs (otelzap tee) + Vector for non-instrumented pods
    - [VictoriaLogs store](./observability/logging/victorialogs.md) - streams model, VLSingle, ingest contracts, retention
    - [Vector pipeline](./observability/logging/vector.md) - DaemonSet, transforms, PG plans/pgaudit, self-monitoring
    - [LogsQL guide](./observability/logging/logsql-guide.md) - streams on this platform, filters, pipes, recipes
11. **[Application logging](./api/logs.md)** - App-side logging contract (JSON fields, levels, middleware)
    - Platform ingest ops: [VictoriaLogs store](./observability/logging/victorialogs.md)

### API Reference

1. **[API area hub](./api/README.md)** - Start here for the learning path and all 11 service contracts

2. **[Shared API and communication guide](./api/api.md)** - URL naming, audiences, auth, errors, pagination, HTTP-vs-gRPC, current call graph, HTTP/2 load balancing, security, and observability

3. **[Microservices catalog](./api/microservices.md)** - Feature ownership, service dependencies, techniques, and known gaps

4. **[Identity and tokens](./api/identity.md)** - Realms, where a token is verified, and the `OIDC_*` env contract every service follows

4. **Service contracts** - [Auth](./api/auth.md), [User](./api/user.md), [Product](./api/product.md), [Inventory](./api/inventory.md), [Cart](./api/cart.md), [Order](./api/order.md), [Review](./api/review.md), [Notification](./api/notification.md), [Shipping](./api/shipping.md), [Checkout](./api/checkout.md), and [Payment](./api/payments.md)

6. **[Temporal workflows](./api/temporal.md)** - all three workflows as built, saga vs 2PC theory, infrastructure, and operations

7. **[RFCs — research then decide](./proposals/rfc/)** — owner approves next `RFC-NNNN` → `research.md` (plain-language + Context7) → `README.md` → optional `docs/<area>/` spin-off

### Databases

1. **[Database area hub](./databases/README.md)** - Choose a learning,
   platform, operations, or historical-reference path.

2. **[PostgreSQL learning path](./databases/README.md#learn-postgresql)** -
   Internals, replication and HA, pooling, backup/recovery, and extensions.

3. **[PostgreSQL Disaster Recovery](./databases/disaster-recovery.md)** - HA, DR, RPO/RTO, PITR, standby taxonomy, and restore evidence
    - [RPO/RTO Planning](./databases/reliability-targets.md) - per-tier targets vs as-built, mapped to clusters
    - [Restore & Failover Drills](./databases/runbooks/restore-and-failover-drills.md) - drill cadence, roles, and evidence log
    - [Cross-Region / Cross-Zone DR](./databases/cross-region-dr.md) - roadmap to independent failure domains
    - [Emergency Recovery](./databases/runbooks/emergency-recovery.md) - "start here when it's down" runbook
    - [GameDay drill record](./proposals/rfc/RFC-0021/gameday.md) - recorded drills: measured RTO, data-convergence evidence, falsified claims

### Runbooks & Troubleshooting

1. **[PostgreSQL Backup/Restore](./databases/runbooks/backup-restore.md)** - Backup and restore procedures (CNPG Barman)
2. **[Logging troubleshooting](./observability/logging/vector.md#troubleshooting)** - Missing/blank Kubernetes logs (Vector → VictoriaLogs → Grafana)
3. **[Add a service database](./databases/runbooks/add-service-database.md)** - RFC-0012 triplet flow on product-db
4. **[Rotate a product-db service password](./databases/runbooks/rotate-cnpg-service-password.md)** - End-to-end rotation via OpenBAO → triplet → PgDog
6. **[Pooler operations](./databases/runbooks/pooler-operations.md)** — day-2 ops for both poolers: PgDog (`pgdog-product`) and the CNPG PgBouncer `Pooler` (`platform-db-pooler-rw`)
7. **[Kind E2E audit](./platform/kind-e2e-audit.md)** — the cluster release gate: Flux delivery vs pins, admission, the real edge, cluster-only telemetry

---

## Documentation by Category

### Getting Started

- [Setup Guide](./platform/setup.md) - Complete deployment instructions
- [API Reference](./api/api.md) - API endpoints and adding new microservices

### Observability

#### Metrics
- [Metrics Guide](./observability/metrics/README.md) - Comprehensive metrics documentation
- [PromQL Guide](./observability/metrics/promql-guide.md) - Complete guide to PromQL functions, time range vs rate interval, and counter handling
- [Variables & Regex](./observability/grafana/variables.md) - Filter patterns
- [Grafana Dashboard Guide](./observability/grafana/dashboard-reference.md) - Complete SRE/DevOps dashboard reference (~41 panels + annotations planning)

#### SLO/SRE
- [SLO Overview](./observability/slo/README.md) - Architecture, SLI definitions, targets
- [Getting Started](./observability/slo/getting_started.md) - Enable SLOs via Helm values
- [SLO Burn-Rate Alerts](./observability/alerting/slo-burn-rate-alerts.md) - Alert configuration
- [Error Budget Policy](./observability/slo/error_budget_policy.md) - Budget management
- [Annotation-Driven Controller](./observability/slo/annotation-driven-slo-controller.md) - Future approach

#### Observability Pillars
- [Observability Overview](./observability/README.md) - Master index, 4-pillar architecture, 3-layer service architecture + APM integration
- [OTel fundamentals](./observability/opentelemetry/fundamentals.md) - API vs SDK, signals and signal selection, OTLP transport, propagation & baggage, plus the RFC-0014 old-vs-new migration story
- [OpenTelemetry (platform)](./observability/opentelemetry/README.md) - Collector topology, sampling, operations (app policy → [api/observability.md](./api/observability.md))
- [OpenTelemetry Collector](./observability/opentelemetry/collector.md) - component model, deployment patterns, deployed pipelines + runbook
- [Histograms & temporality](./observability/metrics/histograms.md) - bucket mechanics, explicit vs exponential, delta vs cumulative
- [Distributed Tracing](./observability/tracing/README.md) - VictoriaTraces + ClickHouse fan-out
- [Tracing Architecture](./observability/tracing/architecture.md) - Trace topology: VictoriaTraces (7d) + ClickHouse (90d)
- [Jaeger (archived)](./observability/tracing/jaeger.md) - Frozen history; the Jaeger query API is now VictoriaTraces' interface
- [Backend Comparison](./observability/tracing/backends-comparison.md) - why VictoriaTraces + ClickHouse won
- [VictoriaTraces (pilot)](./observability/tracing/victoriatraces.md) - 3rd backend via the VM operator
- [Continuous Profiling](./observability/profiling/README.md) - Pyroscope setup
- [ClickHouse OTel OLAP](./observability/clickhouse/README.md) - Deployed supplementary OLAP; OTel logs/traces SQL ([RFC-0019](./proposals/rfc/RFC-0019/))
- [ClickHouse fundamentals](./observability/clickhouse/fundamentals.md) · [schema and queries](./observability/clickhouse/schema-and-queries.md) · [materialized views](./observability/clickhouse/materialized-views.md)
- [Logging (platform)](./observability/logging/README.md) - OTLP app logs + Vector for non-instrumented pods
- [Application logging](./api/logs.md) - App-side logging contract (libraries, levels, JSON fields)
- [Application observability](./api/observability.md) - Cross-cutting policy, env, middleware, three-layer spans
- [Application metrics](./api/metrics.md) · [tracing](./api/tracing.md) · [profiling](./api/profiling.md) · [caching](./api/caching.md) - Per-pillar service contracts

### API

- [API area hub](./api/README.md) - Learning path, document ownership, deployment rollup, and all service contracts
- [Shared API and communication guide](./api/api.md) - HTTP/gRPC conventions, call graph, user journeys, load balancing, security, and observability
- [Identity and tokens](./api/identity.md) - The verification contract: two realms, edge vs in-service checks, `OIDC_*` env, `sub` as `user_id`
- [Admin Portal API consumption](./api/admin.md) - Consumer index (not a contract): the 26 `/protected/` operations the Backoffice calls, by service and screen
- [Microservices catalog](./api/microservices.md) - Feature ownership, techniques, dependencies, and known gaps
- [Service contracts](./api/README.md#service-contracts) - Platform deployment rollup and one file per Go service
- [Workflow registry](./api/workflows.md) - Temporal workflows: owners, workers, task queues, and participants
- [Temporal Workflows](./api/temporal.md) - the three workflows as built, saga-vs-2PC learning, Temporal infrastructure, and operations
- [Checkout](./api/checkout.md) - Session orchestration, fully shipped (local-stack + cluster); the legacy order path was removed in RFC-0021 P5
- [Payments](./api/payments.md) - Payment API, state machine, ledger, provider, and reconciliation

### Frontend

- [Browser applications](./frontend/README.md) - Area hub: the two SPAs at the platform layer, and the build-arg contract that makes an image tag a deployment contract
- [Admin Portal](./frontend/admin-portal/README.md) - The operator portal: staff-realm fence, `/protected/` audience, edge exposure, delivery, and its gap list

### Design records (RFCs and ADRs)

The **owning indexes are complete and are the only place a record's status is
maintained.** This page deliberately does not duplicate them — a partial copy
here is how an index starts disagreeing with the records it points at.

- [**ADR index**](./proposals/adr/README.md) — all **65** decisions, each with
  its `Status` and `Adoption`. The *why* behind significant choices.
- [**RFC index**](./proposals/rfc/README.md) — all **26** proposals, plus the
  process (research gate → RFC → ADR) and the backlog.
- [Proposals hub](./proposals/) — templates and how to open a new record.

**Start here** — a reading path, *not* an index. These eight decisions shape
most of what the rest of the platform does; all are `Accepted` and adopted.

| Decision | Why it matters |
|---|---|
| [ADR-044](./proposals/adr/ADR-044-envoy-gateway-platform-edge/) — Envoy Gateway as the platform edge | Every north-south request enters here; replaced Kong (RFC-0024) |
| [ADR-041](./proposals/adr/ADR-041-keycloak-platform-idp/) — Keycloak as the platform IdP | The only token issuer; retired the custom `auth-service` |
| [ADR-047](./proposals/adr/ADR-047-protected-apis-on-owning-services/) — administrative commands on `/protected/` | Operators go through role-gated APIs on owning services, never a DB |
| [ADR-030](./proposals/adr/ADR-030-temporal-workflow-versioning/) — Temporal Worker Versioning | Why a running saga survives a worker deploy |
| [ADR-054](./proposals/adr/ADR-054-temporal-worker-controller/) — the Worker Controller owns that lifecycle | The build id is derived, and appears nowhere in git |
| [ADR-023](./proposals/adr/ADR-023-clickhouse-observability-olap/) — ClickHouse as OLAP for OTel logs and traces | The 90-day SQL surface beside the fast path |
| [ADR-059](./proposals/adr/ADR-059-retire-tempo/) — retire Tempo, take service graphs from VictoriaTraces | Why the trace tier is two sinks and not five |
| [ADR-056](./proposals/adr/ADR-056-k6-e2e-assertion-layer/) — assert the E2E gates with k6 | A written gate row is not a verified one |

### Payments

- [Payments](./api/payments.md) - Design record (RFC-0010 + ADR-007…011) + payment↔provider reconciliation: classes, equivalence rules, internal API, e2e evidence

### Databases

- [Database area hub](./databases/README.md) - Learning, current platform,
  runbooks, and historical reference.
- [Emergency recovery](./databases/runbooks/emergency-recovery.md) - First-response router
- [Restore & Failover Drills](./databases/runbooks/restore-and-failover-drills.md) - Drill cadence, roles, and evidence log
- [Cross-Region / Cross-Zone DR](./databases/cross-region-dr.md) - Planned roadmap to independent failure domains
- [Declarative Role & Database Management](./databases/declarative-role-management.md) - Per-service triplet (ExternalSecret + DatabaseRole + Database) on product-db; RFC-0012 rollout state
- [PostgreSQL Further Reading](./databases/reference/further-reading.md) - Curated external references
- [PostgreSQL Internals](./databases/fundamentals/README.md) - Vendor-neutral learning path for processes, storage, WAL, MVCC, queries, and replication

### Caching

- [Application caching](./api/caching.md) - Cache-Aside contract, stampede prevention, keys, env
- [Caching (Valkey)](./caching/README.md) - Platform deployment, eviction policies, distributed-cache concept

### Platform

- [Platform hub](./platform/README.md) - Deployed vs planned, doc map, Flux summary
- [Setup Guide](./platform/setup.md) - Complete deployment and configuration guide
- [Kind E2E audit](./platform/kind-e2e-audit.md) - The **cluster gate**: K0–K6 runbook proving Flux delivered the pinned images, admission/secrets/isolation, the real edge, and cluster-only telemetry. Twin of the [Compose E2E audit](../local-stack/docs/e2e-audit.md)
- [Application Delivery](./platform/application-delivery.md) - ResourceSet patterns & templates
- [cert-manager + Flux](./secrets/cert-manager.md) - TLS with Let's Encrypt, HelmRelease, and trust-manager CA bundle distribution (§11)
- [CI/CD](./platform/cicd.md) - CI/CD pipelines, workflows, **and the standard/policy** (action SHA-pinning, least-privilege permissions, image signing/verification, required-checks matrix, GoReleaser binary releases)
- [Git Branching & Release](./platform/gitflow.md) - Hybrid Enterprise Gitflow standard (dev/uat/main + immutable tags)
- [SonarCloud](./platform/sonarcloud.md) - SonarCloud integration
- [Envoy Gateway](./platform/envoy-gateway.md) - The platform edge: Gateway API resource model, policy attachment, Kubernetes vs standalone providers, edge JWT, and the telemetry the proxy itself produces
- [Worker Autoscaling](./platform/worker-autoscaling.md) - How a versioned Temporal worker gets its replica count (KEDA + Worker Controller), and five mechanics a Kind drill exposed: the two-writer replica trap, API-poll vs scrape latency, the 17-series backlog metric, why `up == 0` cannot see a vanished target, and sunset delays that add
- [Kong API Gateway](./platform/kong-gateway.md) - **Archived.** The platform's previous API gateway, kept for reference
- [Kyverno](./platform/kyverno.md) - Admission policies: tiers, Audit→Enforce rollout, exceptions
- [Keycloak](./platform/keycloak.md) - The platform identity provider: deployment shape, realm import and its one-shot limitation, the bypassed pooler, reset procedure, signals, and known gaps
- [Graceful Shutdown](./api/graceful-shutdown.md) - Cross-service shutdown contract: readiness drain + signal handling (moved to `docs/api/`)
- [GKE internal & private DNS](./platform/gke-internal-dns.md) - In-cluster DNS and Cloud DNS private zones
- [MCP Servers](./platform/mcp-servers.md) - In-cluster MCP servers (VictoriaMetrics, VictoriaLogs, Flux Operator, Grafana) behind the edge
- [Ruleset Automation](./platform/ruleset-automation.md) - GitHub repo ruleset provisioning

### Secrets

- [Secrets hub](./secrets/README.md) - Homelab-wide OpenBAO → ESO → cert-manager → trust-manager flow, secret catalog, and runbook index
- [OpenBAO Architecture](./secrets/openbao.md) - OpenBAO HA/Raft internals, auth, engines, policies
- [Secrets runbooks](./secrets/runbooks/) - OpenBAO/ESO troubleshooting and recovery
- [Secrets hardening & boundaries](./secrets/README.md#current-boundaries--production-hardening) - Deployed vs planned: TLS, KMS, OIDC, AppRole, database-engine credentials
- [cert-manager + Flux](./secrets/cert-manager.md) - TLS with Let's Encrypt, HelmRelease, and trust-manager `homelab-ca-bundle` (§11, dual-PKI split)
- [Secrets decisions & hardening](./proposals/) - ADR-004 (audit) + ADR-005 (OpenBAO HA); [RFC-0008](./proposals/rfc/RFC-0008/) production hardening + parity/testing matrix; RFC backlog for rotation / PushSecret

### Security

- [Security hub](./security/README.md) - Admission (Kyverno) + segmentation (NetworkPolicy) in one map
- [Policy Catalog](./security/policy-catalog.md) - Kyverno ClusterPolicy catalog (tiers, modes, acceptance criteria)
- [Policy Exceptions](./security/policy-exceptions.md) - PolicyException register (owner + TTL)
- [Network Policies](./security/network-policies.md) - East-west NetworkPolicy caller matrix + topology

### Runbooks

- [Kind E2E audit](./platform/kind-e2e-audit.md) - The cluster release gate (K0–K6), twin of the [Compose E2E audit](../local-stack/docs/e2e-audit.md)
- [k6 assertion layer](./testing/k6.md) - One suite for both gates: rows as thresholds, saga over HTTP, edge limiter, Temporal backlog
- [PostgreSQL Backup/Restore](./databases/runbooks/backup-restore.md) - Backup and restore procedures
- [Logging troubleshooting](./observability/logging/vector.md#troubleshooting) - Missing/blank Kubernetes logs
- [Add a service database](./databases/runbooks/add-service-database.md) - RFC-0012 triplet flow
- [Rotate a product-db service password](./databases/runbooks/rotate-cnpg-service-password.md) - End-to-end rotation

---

## Quick Reference

### Key Concepts

- **GitOps** - Declarative infrastructure managed via Flux Operator
- **Flux Operator** - Kubernetes-native GitOps reconciliation engine
- **Kustomize** - Simplified structure (direct manifests in infra/ + apps/, refactored 2026-01-12)
- **OCI Registry** - `localhost:5050` (local), stores Kubernetes manifests as artifacts
- **Helm Chart** - Generic chart for all microservices (`charts/`)
- **HelmRelease CRDs** - Flux manages Helm deployments declaratively
- **40 Data Panels + 6 Row Groups** - Complete monitoring dashboard
- **4 Custom Metrics** - Application-level metrics (RED method)
- **9 Microservices** - All services with v1 API (canonical)
- **Monitoring Stack** - VictoriaMetrics Operator (VMAgent, VMSingle, VMAlert, VMAlertmanager) + prometheus-operator-crds + Grafana Operator + metrics-server
- **SLO System** - Sloth Operator with PrometheusServiceLevel CRDs
- **APM Stack** - VictoriaTraces + ClickHouse (tracing), OTel Collector (fan-out), Pyroscope (profiling), VictoriaLogs + Vector (logging)
- **Secrets Stack** - OpenBAO (HA Raft) + External Secrets Operator for centralized secret management
- **TLS / PKI** - cert-manager with **dual issuers**: Let's Encrypt (DNS-01 via Cloudflare) for browser-facing `*.duynh.me`; self-signed `homelab-ca` for future internal mTLS, distributed via trust-manager `homelab-ca-bundle`
- **Bootstrap-only secrets** - Cloudflare API token (`secret/local/infra/cloudflare/api-token`) is operator-supplied (not in Git, not seeded by `openbao-bootstrap`); re-seed after every fresh cluster

---

## Additional Resources

- **[AGENTS.md](../AGENTS.md)** - AI agent guide for navigating the codebase
- **[README.md](../README.md)** - Project overview and quick start

---

_Last updated: 2026-08-06 — RFC-0021 closed (P0–P7); inventory is the sole stock authority._
