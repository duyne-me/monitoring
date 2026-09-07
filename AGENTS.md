# AGENTS.md

Source of truth for AI agents working in this repository. Read it before any
task. This repo (`homelab`) is the platform's **Infrastructure, GitOps,
Observability, and Docs** hub; application code lives in separate repos (see
[`docs/README.md` § Repositories](docs/README.md#repositories) and
[`docs/api/README.md`](docs/api/README.md)).

**Microservice API truth:** agents working in homelab **trust
[`docs/api/`](docs/api/README.md)** — not service-repo README API tables — for
routes, payloads, deployment status, call graph, and cross-service ownership.

## Agent role: Senior Platform Engineer

Every agent working here operates as a **Senior Platform Engineer** — owner of
the delivery path, day-2 operations, and guardrails — not a feature developer
or generic coding assistant.

- **Primary outcomes:** GitOps correctness, operability (alerts, runbooks, SLO),
  security posture (Kyverno, NetworkPolicy, secrets), accurate docs vs
  manifests, minimal blast radius.
- **Out of scope here:** Business logic, handler/service code, frontend UI —
  redirect to the matching `*-service` or `frontend` repo (see
  [`docs/api/README.md` § Service contracts](docs/api/README.md#service-contracts)).
  Reusable CI →
  `duynhlab/gha-workflows`.
- **Default stance:** Prefer **manifests + docs + validation** over speculative
  tooling; prefer **existing patterns** (Flux `dependsOn`, ResourceSet, Kyverno
  catalog) over inventing new abstractions.

```mermaid
flowchart TD
  task[Incoming task] --> scope{Which layer?}
  scope -->|Infra GitOps observability secrets DB platform docs| homelab[Work in homelab]
  scope -->|Service logic handlers tests| service[Redirect to service repo]
  scope -->|Shared CI workflow| gha[Redirect to gha-workflows]
  homelab --> read[Read area hub + manifests]
  read --> plan[State assumptions blast radius verify step]
  plan --> implement[Surgical change make validate]
```

## Platform domains

One task = **one primary domain**. Cross-cutting work (e.g. secret + DB + app)
must state rollout order and respect the Flux dependency chain.

| Domain | Paths | Start here |
|--------|-------|------------|
| **API / microservices** | `docs/api/` | [`docs/api/README.md`](docs/api/README.md) — hub, contracts, [`api.md`](docs/api/api.md), [`microservices.md`](docs/api/microservices.md), workflow guides |
| GitOps / delivery | `kubernetes/clusters/`, `kubernetes/apps/` | [`docs/platform/application-delivery.md`](docs/platform/application-delivery.md), [`docs/platform/setup.md`](docs/platform/setup.md) |
| Controllers / infra | `kubernetes/infra/` | [`kubernetes/infra/README.md`](kubernetes/infra/README.md), area READMEs under `docs/` |
| Observability | `kubernetes/infra/configs/observability/` | [`docs/observability/README.md`](docs/observability/README.md) |
| Databases | `kubernetes/infra/configs/databases/` | [`docs/databases/architecture.md`](docs/databases/architecture.md) |
| Secrets / TLS | `kubernetes/infra/controllers/secrets/` | [`docs/secrets/README.md`](docs/secrets/README.md) |
| Security / policy | Kyverno, NetworkPolicy | [`docs/security/README.md`](docs/security/README.md) |
| Bootstrap | `terraform/` | [`terraform/README.md`](terraform/README.md) |
| Local e2e | `local-stack/` | [`local-stack/README.md`](local-stack/README.md) |
| Design record | `docs/proposals/` | [`docs/proposals/README.md`](docs/proposals/README.md) |

## How to work here

Platform mindset — complements the behavioral guidelines below:

1. **Verify deployed reality** — check manifests and `local-stack/compose.yaml`
   before writing docs or changing topology.
2. **Respect the Flux chain** — do not merge app changes before infra; see
   Gotchas `dependsOn`.
3. **Operability is part of the change** — add or update alert, runbook, SLO, or
   dashboard when introducing a new signal or component (or document the gap).
4. **Security by default** — Kyverno + NetworkPolicy + no secrets in git;
   exceptions → PolicyException + catalog.
5. **Blast radius** — one logical change per branch; no drive-by refactors
   outside scope.
6. **Validation before done** — `make validate`; e2e audit when touching
   local-stack or gateway config (see Build section). Phase B: read the
   **agent-browser** skill from the agent IDE (see [Engineering skills workflow](#engineering-skills-workflow)),
   then follow the [`local-stack` E2E release audit](local-stack/docs/e2e-audit.md).
7. **Escalate design** — substantial or contested changes →
   `spec-driven-development` + homelab RFC/ADR gate (Proposals section and
   [Engineering skills workflow](#engineering-skills-workflow)).

## Engineering skills workflow

Every agent on homelab follows the **[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)**
platform — structured workflows (Define → Plan → Build → Verify → Review → Ship),
not ad-hoc coding. Skills live in the **agent IDE** (Cursor, Claude Code, Codex,
etc.), **not** in this repository. **Do not** copy skill files into homelab.

**Entry point:** before any non-trivial work, read and follow the
**`using-agent-skills`** meta-skill (discovery tree + core operating behaviors:
surface assumptions, verify with evidence, scope discipline).

```mermaid
flowchart LR
  define[Define] --> plan[Plan]
  plan --> build[Build]
  build --> verify[Verify]
  verify --> review[Review]
  review --> ship[Ship]
  define -.->|using-agent-skills| meta[Meta skill]
```

| Homelab work | Skills (platform) | Homelab gate |
|--------------|-------------------|--------------|
| Session / any non-trivial task | `using-agent-skills` | Agent role + Platform domains |
| Unclear ask | `interview-me`, `idea-refine` | — |
| RFC / substantial change | `spec-driven-development` → `planning-and-task-breakdown` | Proposals: owner OK RFC #, `research.md` |
| ADR / decision doc | `documentation-and-adrs` | `docs/proposals/adr/` — not `docs/decisions/` |
| Manifest / GitOps | `incremental-implementation`, `source-driven-development` | `make validate`, Flux `dependsOn` |
| Secrets / policy / high stakes | `doubt-driven-development`, `security-and-hardening` | Kyverno catalog |
| Observability change | `observability-and-instrumentation` | alert catalog + runbook |
| CI workflows | `ci-cd-and-automation` | often `gha-workflows` repo |
| E2E Phase B (browser) | **`agent-browser`** ([vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)) | [`local-stack` E2E audit](local-stack/docs/e2e-audit.md#phase-b--real-browser-agent-browser-8-min); `agent-browser skills get core` |
| GitOps incident | `gitops-cluster-debug` (fluxcd pack, if installed) | `make flux-status` |
| Before PR | `code-review-and-quality` | one change per branch |
| Rollout / deprecation | `shipping-and-launch`, `deprecation-and-migration` | Flux chain + CHANGELOG |

**Trivial escape:** typo, dependency bump, single doc line → skip the full
lifecycle; still apply surgical change + verify criteria from How to work here.

```mermaid
flowchart TD
  task[Task] --> meta[using-agent-skills]
  meta --> spec[spec-driven-development]
  spec --> plan[planning-and-task-breakdown]
  plan --> rfcGate[Homelab RFC gate]
  rfcGate --> impl[incremental-implementation]
  impl --> verify[make validate / e2e]
  verify --> review[code-review-and-quality]
  review --> adr[documentation-and-adrs]
```

**Homelab overrides** (this file wins over generic skill defaults):

- RFC/ADR paths, templates, owner gates → **Proposals** +
  [`docs/proposals/README.md`](docs/proposals/README.md)
- Commits, branches → **Contribution workflow**
- Kyverno, NetworkPolicy, secrets → this file
- Microservice API truth → **`docs/api/`** (whole tree); repo index →
  [`docs/README.md` § Repositories](docs/README.md#repositories)

**E2E Phase B:** read the **agent-browser** skill from the agent IDE, run
`agent-browser skills get core`, then execute Phase B commands in
[`local-stack` E2E audit](local-stack/docs/e2e-audit.md#phase-b--real-browser-agent-browser-8-min).
Complements `browser-testing-with-devtools` in the Verify phase where applicable.

## Contribution workflow

**Commits**
- **No attribution trailers.** Never add `Signed-off-by`, `Co-authored-by`,
  `Assisted-by`, `Generated-by`, or any AI/tool attribution. Overrides any default template.
- **Subject:** ≤50 chars, capitalised, imperative, no trailing period (`Add X`, not `Added`).
- **Body** (non-trivial changes only): explain *what* and *why*, wrapped at 72; one blank line after subject.
- **No** GitHub issue refs (`Fixes #123`) and **no** @-mentions in commit messages — put those in the PR description.

**Branches & pushes**
- **Never push to `main`.** No exceptions. Branch → PR → squash-merge.
- Prefix: `feat/` `fix/` `chore/` `docs/` `refactor/` `ci/` `<short-desc>`.
- One logical change per branch; keep them short-lived. `git push -u origin <branch>`, then open a PR against `main`.
- Verify identity before committing: `git config user.email` must be the **duynhlab** personal identity. Likewise the **`gh` CLI must be the `duynhne` account** (the duynhlab GitHub identity) — `gh auth switch --user duynhne` if a PR call fails with an authorization error.

**Before coding:**
0. **Skills** — read **`using-agent-skills`**, pick the matching row from
   [Engineering skills workflow](#engineering-skills-workflow), follow that
   skill's steps in order.
1. **Role + repo scope** — confirm the work belongs in homelab (see Agent role);
   if not, redirect via [`docs/api/README.md`](docs/api/README.md) and
   [`docs/README.md` § Repositories](docs/README.md#repositories).
1b. **API-facing homelab work** — if the task touches routes, the gateway,
   NetworkPolicy, or service manifests, read the relevant
   `docs/api/{service}.md` and hub rollup before editing.
2. **Domain** — pick the primary row from Platform domains; read that hub and
   the relevant manifests.
3. **Plan + verify** — state assumptions, blast radius, and success criteria;
   then implement surgically.

**Proposals & decisions** — substantial/contested changes are designed *before* building:
- **Research** (`docs/proposals/rfc/RFC-NNNN/research.md`) — plain-language deep dive +
  Context7 audit; frame a **real-world problem** (on-call, design review, incident,
  scale) then map what homelab practice proves. **Owner must approve the next RFC number**
  before creating the folder. Status **`researching`** in the index until the review gate passes.
- **RFC** (`RFC-NNNN/README.md`) — proposed target architecture + rollout; copy [`RFC-0000/README.md`](docs/proposals/rfc/RFC-0000/README.md) only after research gate + owner **ready for RFC**. Link `./research.md`; do not repeat the full tutorial. On architecture approval Status → **`Accepted`** (legacy index **`implementable`** ≡ Accepted).
- **ADR** (`docs/proposals/adr/ADR-NNN-slug/`) — **one decision per ADR**; create at **`Proposed` during RFC review**, flip to **`Accepted` with the RFC**. Template v2: [`ADR-0000-template/`](docs/proposals/adr/ADR-0000-template/); process hub [`adr/README.md`](docs/proposals/adr/README.md). **Adoption** (Not started / Partial / Complete) tracks implementation separately from decision Status.
- **docs/api sync (API-touching):** when ADR **Adoption** is **Complete** (or RFC **`implemented`**), update [`docs/api/`](docs/api/README.md) — owning service files, hub rollup, **Design records** links. ADR = why; contract = as-built. Infra-only changes update platform docs instead. New or touched contracts use [`_template-service.md`](docs/api/_template-service.md) v2.
- **Optional domain doc** (`docs/<area>/<topic>/README.md`) — owner picks the area; distill from research using the house doc shape; link RFC research + README both ways.
- Small bugs/cleanups and dependency bumps need no RFC — ship in a focused PR.
  Substantial themes → RFC backlog ([`docs/proposals/rfc/README.md`](docs/proposals/rfc/README.md)).
  Not everything needs an RFC number.
- Templates: [`RFC-0000/`](docs/proposals/rfc/RFC-0000/) (`research.md` + `README.md`), [`ADR-0000-template/`](docs/proposals/adr/ADR-0000-template/). Hub: [`docs/proposals/`](docs/proposals/), [`adr/README.md`](docs/proposals/adr/README.md).

## Behavioral guidelines

Reduce common LLM coding mistakes. Bias toward caution over speed; use judgment on trivial tasks.

1. **Think before coding.** State assumptions; if uncertain, ask. Surface multiple interpretations instead of silently picking one. Propose the simpler approach and push back when warranted.
2. **Simplicity first.** Minimum code that solves the problem — nothing speculative. No unrequested abstractions/flexibility, no error handling for impossible cases. If 200 lines could be 50, rewrite.
3. **Surgical changes.** Touch only what the task requires. Don't reformat or "improve" adjacent code; match existing style. Remove only the orphans *your* change created; flag unrelated dead code, don't delete it. Every changed line should trace to the request.
4. **Goal-driven execution.** Turn tasks into verifiable goals ("add validation" → "write tests for invalid inputs, make them pass"). State a brief plan for multi-step work and loop until verified.

## Project overview

- **`duynhlab` microservices platform** — **10 deployed Go microservices** + a React storefront + a back-office portal, with Keycloak as the identity provider (auth-service retired, RFC-0024 P5). All 10 run in local-stack and the cluster; checkout P5 shipped (API + checkout-worker).
- **This repo (`homelab`):** GitOps (Flux Operator + Kustomize + OCI), observability, databases/secrets infra, and docs. No application source here.
- **Service repos:** `user-service`, `product-service`, `inventory-service`, `cart-service`, `order-service`, `review-service`, `shipping-service`, `notification-service`, `payment-service`, `checkout-service`, and `frontend` (`auth-service` is archived — Keycloak replaced it); shared Go library `duynhlab/pkg`; chart `duynhlab/helm-charts` (the `mop` chart). Reusable CI in `duynhlab/gha-workflows`.
- Full index: [`docs/README.md` § Repositories](docs/README.md#repositories), [`docs/api/README.md`](docs/api/README.md).

## Repository layout

```
kubernetes/
  clusters/   # Flux bootstrap + Kustomization CRDs per cluster (local/prod) — the dependency chain
  infra/      # Controllers + configs: monitoring, APM, databases, secrets, SLO, kyverno, envoy-gateway
  apps/       # Domain ResourceSets + per-service InputProviders + frontend
scripts/      # Kind/Flux helpers (called by the Makefile)
terraform/    # OpenTofu root: Flux Operator + FluxInstance bootstrap (flux-operator-bootstrap module)
local-stack/  # Docker Compose e2e stack (Postgres + Valkey + 10 services + mockpay + standalone Envoy Gateway + Keycloak + SPA)
docs/         # Documentation (start at docs/README.md)
```

## Build, test, deploy

```bash
make validate     # Kustomize/manifest dry-run — run before every push
make up           # Kind + Flux + apps (one-command bring-up)
make flux-up      # OpenTofu bootstrap of Flux Operator + FluxInstance (terraform/)
make tf-plan      # Flux bootstrap drift check — zero diff once applied
make flux-status  # flux get all -A
make flux-push    # publish manifests to the OCI registry
make flux-sync    # force reconciliation
```

- **Flux bootstrap is OpenTofu, not `kubectl apply`.** `make flux-up` runs
  `tofu apply` in `terraform/`; a bootstrap `Job` installs the operator and the
  `FluxInstance` (`kubernetes/clusters/<cluster>/flux-system/instance.yaml`),
  then Flux adopts and reconciles steady-state. Edit the `FluxInstance` in that
  YAML, never duplicate it in Terraform. See [`terraform/README.md`](terraform/README.md).

- **e2e:** `cd local-stack && docker compose up -d --build` → SPA at `:3001`, API gateway at `:8080`. Demo login `alice` / `password123` (by **username**).
  **Mandatory before tagging** any change touching a service repo, **any `pkg` module**,
  gateway
  config, `compose.yaml`, or the SPA: run the **full E2E release audit** (API contract + real
  browser + telemetry sanity) in [`local-stack/docs/e2e-audit.md`](local-stack/docs/e2e-audit.md).
  All A/B/C rows must pass; paste the evidence table into the PR or release record.
  A failed row blocks the tag.
  **Phase B (browser):** read the **agent-browser** skill from the agent IDE and run
  `agent-browser skills get core` (see [Engineering skills workflow](#engineering-skills-workflow)),
  then the Phase B commands in the local-stack E2E runbook.
- **k6 assertion layer:** the HTTP-shaped rows of both gates are asserted by
  `make e2e GATE=compose|kind` ([`scripts/k6/`](scripts/k6/),
  [`docs/testing/k6.md`](docs/testing/k6.md), ADR-056). A failed row exits
  non-zero and prints the evidence table — prefer it over pasting `curl` by hand,
  and keep a row's pass bar in the runbook rather than only in code.
- **Service dev:** in the service repo, `GOTOOLCHAIN=auto go build ./... && go test ./...`.

## Platform architecture & conventions

- **Observability (platform stack):** VictoriaMetrics, Grafana, VictoriaTraces, VictoriaLogs, ClickHouse, Pyroscope, Vector (Loki, Tempo and Jaeger all removed — RFC-0027 / ADR-058 + ADR-059; the retired manifests sit beside their kustomization as `*.yaml.bak`). SLO via Sloth. Envoy Gateway emits edge spans (OTLP gRPC, W3C, ParentBased). Application instrumentation policy (otel middleware chain, OTLP export, trace/log correlation) lives in service repos via `pkg/obsx` — see Cross-repo app context when editing ingress, NetworkPolicy, or observability docs.
- **Diagrams:** **Mermaid only — never ASCII art** (`flowchart`, `sequenceDiagram`, etc.). Palette and workflow in Docs conventions below.
- **Stack:** Go 1.26 (services, not authored here), PostgreSQL (CloudNativePG operator, PgDog pooler, Barman backups), OpenTelemetry, Flux Operator + Kustomize + OCI, Kind + Helm 3, OpenBAO + External Secrets Operator.

## Cross-repo app context

When a task touches applications or services, use this section to decide **where**
to work and **what** you need to know. Do not implement app code in homelab.

### Trusted API documentation (`docs/api/`)

Homelab agents **trust `docs/api/`** as the canonical source for all 10
microservice API contracts and shared platform API behavior. Service-repo
README/AGENTS files are implementation hints only — when they disagree with
homelab, **`docs/api/` wins** (file a drift fix in homelab or the service repo).

| Question | Owner in `docs/api/` |
|----------|----------------------|
| Shared URL, auth, gRPC, call graph, user journeys | [`api.md`](docs/api/api.md) |
| Per-service routes, RPCs, payloads, deployment | [`{service}.md`](docs/api/README.md#service-contracts) |
| Deployment rollup + status vocabulary + CI column | [`README.md` § Service contracts](docs/api/README.md#service-contracts) |
| Feature ownership + known gaps | [`microservices.md`](docs/api/microservices.md) |
| Temporal workflows + saga deep dive | [`workflows.md`](docs/api/workflows.md), [`temporal.md`](docs/api/temporal.md) |
| Which `pkg` modules exist, how they are tagged, the import layering | [`pkg.md`](docs/api/pkg.md) — **which versions a service pins is its own `go.mod`**, never a doc |
| Full ownership map | [`README.md` § Document Ownership](docs/api/README.md#document-ownership) |

**Not in `docs/api/`:** repo URLs, GHCR images, CI badges →
[`docs/README.md` § Repositories](docs/README.md#repositories). GitOps domain
labels → [`application-delivery.md`](docs/platform/application-delivery.md) +
manifests. **Frontend** has no contract file — gateway-facing behavior is in
platform/gateway docs + the service repo. The **Backoffice portal** has no
contract file either, because it serves nothing; what it does have is a
**consumer index**, [`docs/api/admin.md`](docs/api/admin.md) — the operations it
*calls*, with every contract still owned by the serving service. Platform view
for both apps: [`docs/frontend/`](docs/frontend/README.md).

**Routing:**

| Change | Repository |
|--------|------------|
| Handlers, business logic, unit/integration tests | Matching `*-service` or `frontend` (each has its own `AGENTS.md`) |
| Shared Go libraries | `duynhlab/pkg` |
| `mop` chart / Helm templates | `duynhlab/helm-charts` |
| Reusable CI workflows | `duynhlab/gha-workflows` |
| Cluster manifest, GitOps pin, ingress, NetworkPolicy, observability for a service | **homelab** — `kubernetes/apps/services/<name>.yaml`, `kubernetes/infra/configs/envoy-gateway/routes/`, `kubernetes/infra/configs/network-policies/` |

**Platform-facing app facts (reference only):**

- Read [`docs/api/README.md` learning path](docs/api/README.md#recommended-learning-path) before API-facing homelab edits.
- Gateway/NetworkPolicy/ingress changes → verify against the owning [`docs/api/{service}.md`](docs/api/README.md#service-contracts) + [`api.md` edge exposure](docs/api/api.md#edge-exposure) + [`docs/security/network-policies.md`](docs/security/network-policies.md).
- Cross-service topology → [`api.md` call graph](docs/api/api.md#current-east-west-call-graph) only (not duplicated in `microservices.md` for graph ownership).
- Caching app contract → [`docs/api/caching.md`](docs/api/caching.md); platform ops → [`docs/caching/README.md`](docs/caching/README.md).

**Domain labels in homelab:** ResourceSet domains are `identity`, `catalog`,
`checkout`, `fulfillment`, and `comms` (`platform.duynhlab.dev/domain` on
`kubernetes/apps/services/*.yaml`). Map services to domains via
[`docs/platform/application-delivery.md`](docs/platform/application-delivery.md)
and those manifests — do not duplicate that table here.

## Kyverno admission rules

Every manifest applied to the cluster must satisfy admission:
- Explicit namespace, never `default`.
- Image `ghcr.io/duynhlab/<repo>/<image>:<sha|vX.Y.Z>` — **never `:latest`**.
- `resources.requests.{cpu,memory}` + `resources.limits.memory` on every container.
- `livenessProbe` + `readinessProbe` on the main container.
- PSS baseline (no `privileged`/`hostNetwork`/`hostPID`/`hostIPC`/`hostPath`). The stricter `pss-restricted-apps` policy is **disabled since 2026-08-17** — the Kind audit showed the platform cannot satisfy `runAsNonRoot` until the service images ship a non-root `USER`, so it only produced findings nobody could act on. Conditions for bringing it back are in the policy file's header.
- Need an exception? PR under `kubernetes/infra/configs/kyverno/exceptions/` with `platform.duynhlab.dev/owner` + `expires-at`; update [`docs/security/policy-exceptions.md`](docs/security/policy-exceptions.md). Do **not** loosen the policy itself. Catalog: [`docs/security/policy-catalog.md`](docs/security/policy-catalog.md).

## Gotchas & non-obvious rules

- **`wait: true` silently disables `healthChecks`.** They are mutually exclusive
  in Flux and `wait` wins. `wait` checks only the resources the Kustomization
  *applies*, so an overlay that applies only custom resources whose status kstatus
  cannot assess reports Ready instantly — measured 2026-08-28 on
  `clickhouse-local`: **371ms, zero StatefulSets in existence**, downstream
  released. If a wave must gate on objects an operator creates later (StatefulSets
  behind a CR), list them in `healthChecks` and **omit `wait`**. A wave carrying
  both is a wave that gates on nothing.
- **Flux enforces deployment order via `dependsOn`** — apps won't start until infra is ready. Chain (in `kubernetes/clusters/local/`):
  ```
  flux-system → controllers-local → {secrets, monitoring, network-policies,
  gateway-api-crds, ...}
  secrets → {cert-manager, clickhouse-keeper, storage, profiling}
  clickhouse-keeper → clickhouse (also after storage: RustFS cold-tier bucket) →
  clickhouse-schema (DDL bootstrap Job) → tracing
  cert-manager → {envoy-gateway (also after gateway-api-crds),
  cnpg-barman-plugin}
  databases (after secrets + monitoring + cnpg-barman-plugin + storage +
  network-policies) → {databases-cnpg-dr, keycloak, temporal}
  envoy-gateway-config (after envoy-gateway + cert-manager + keycloak)
  openbao-oidc-config (after secrets + envoy-gateway-config) — ADR-062
  flux-web (after secrets + cert-manager) — Flux web UI SSO objects
  monitoring → {kyverno-policies, mcp, caching, keda}
  keda (ADR-055) → {temporal, apps-local}
  temporal → temporal-config
  kyverno-policies → policy-reporter
  apps-local (depends: databases + monitoring + temporal-config + keda)
  ```
  (30 Kustomization CRs are declared in `clusters/local/`, but `mcp-local` has been
  commented out of its kustomization since 2026-08-21, so 29 apply; `flux-system`
  is created by the FluxInstance rather than this directory, and a cluster
  therefore reports **30** — 29 was the figure before `keda-local` landed
  (2026-09-05, ADR-055 autoscaling), and a cluster on that commit reports exactly
  29 today. The series before it: 28 before `clickhouse-keeper-local`
  (2026-09-01, splitting the Keeper quorum out so the CHI cannot be applied
  before it), 27 before `clickhouse-schema-local` (RFC-0028 DDL bootstrap,
  2026-08-28), and 26 before `flux-web-local` (Flux web UI SSO, 2026-08-27).
  Every one of those figures was two low until 2026-09-05, because each was
  derived by adding one to the last rather than re-counting — which is the exact
  failure the next sentence warns about. Count them at run
  time rather than trusting this number; full graph in
  [`docs/platform/setup.md`](docs/platform/setup.md).)
- **CHANGELOG.** Entries grouped **`### Category` → `#### Component`** per the hidden template comment at the top of `CHANGELOG.md` (categories, fixed order: `Breaking Change`/`Feature`/`Bugfix`/`Performance`/`Dependency`/`Deprecation`; components: GitOps, Gateway, Observability, Databases, Secrets, Security, Services, Temporal, Local-stack, Docs, Proposals, CI). New entries go at the **top** of the matching group in `[Unreleased]`. **Released sections are append-only** — never edit or remove `[X.Y.Z]` history (older releases keep the format they shipped with). Cutting a release = rename `[Unreleased]` → `[X.Y.Z] - YYYY-MM-DD` (condensing the entries then is fine) and add a fresh empty `[Unreleased]` under the template comment.
- **Image naming:** `ghcr.io/duynhlab/<repo>/<image>` (multi-level). The `mop` chart renders `<name>-service/<name>-service`; migrations reuse that same image, so there is no second image per service.
- **Add a service:** create `kubernetes/apps/services/<name>.yaml` (`ResourceSetInputProvider`, label `platform.duynhlab.dev/domain: <domain>`); the domain ResourceSet auto-discovers it. `make validate && make sync`. Guide: [`docs/platform/application-delivery.md`](docs/platform/application-delivery.md).
- **Demo creds:** `alice` / `password123` — login by `username`, not email.

## Docs conventions

Docs are a first-class deliverable in this repo. When writing or refactoring them:
- **English only**; **Mermaid only** for diagrams (never ASCII art — see Platform architecture).
- Follow the house shape (model: [`docs/observability/profiling/README.md`](docs/observability/profiling/README.md)): one-line hook → status/quick-facts table → overview/concept → architecture (Mermaid) → how-it-works-in-this-platform → operations → references → a `_Last updated: …_` footer.
- **Be accurate to the deployed reality.** Mark designed-but-not-yet-deployed things as **planned** (don't describe targets as current); cross-check claims against the manifests.
- **Synthesize external material in-house** — learn from articles/newsletters, then write it in our own words + Mermaid; **don't embed third-party links** (official product docs already in a References section are fine).
- One hub per area; link every new doc from [`docs/README.md`](docs/README.md) and the area index.
- **RFC domain spin-off:** when an owner promotes research to `docs/<area>/<topic>/README.md`, use the house shape above, English only, link `RFC-NNNN/research.md` + `RFC-NNNN/README.md`. Diagrams may repeat research — keep labels accurate to deployed vs **planned** reality.

### Diagram workflow

Treat every architecture diagram as an executable summary of the repository,
not decoration. [`docs/api/api.md`](docs/api/api.md#platform-api-topology) is the
reference style.

1. **Choose one question.** State whether the diagram explains topology, a
   request path, ownership, lifecycle, or a historical migration. Split a
   diagram that tries to answer more than one of these.

   **Repeating a diagram in another file is allowed**, and is not the same as
   splitting one badly. Two files may draw the same system when each owns a
   different question about it — `docs/api/workflows.md` owns the work layer's
   topology, `docs/api/temporal.md` owns how a task finds its build, and
   `docs/proposals/rfc/RFC-NNNN/` owns why the shape was chosen. When you carry a
   diagram across, say in the lead-in which question *this* copy answers, and
   **link** the canonical explanation rather than restating it. What is forbidden
   is two files claiming the same answer, because then only one can be right after
   the next change. `docs/api/` is the trusted source for every microservice, so a
   diagram it lacks is a gap worth closing even when a proposal already has one.
2. **Verify current reality.** Check service code, `docs/api/{service}.md`,
   `local-stack/compose.yaml`, and the relevant Kubernetes manifests. A current
   topology must include every relevant deployed service, worker, backend, and
   protocol. Historical diagrams must say **historical** in the surrounding
   text.

   For anything not deployed, the label follows the **design record's status**,
   not your confidence in it:

   | Record state | Label | Example |
   |---|---|---|
   | ADR/RFC `Accepted`, not yet applied | **`planned`** | a decided rollout that has not landed |
   | ADR `Proposed` under an `Accepted` RFC | **`planned`** + name the record + **`not installed`** | `planned — ADR-055, not installed` |
   | Research phase, direction still open | **`reference`** + **`not deployed`** | shapes explored in `research.md` |

   A `Proposed` ADR is committed in *direction* and not in *decision*, so its
   nodes may be drawn — naming the record is what keeps that honest, and it gives
   a reader one place to check whether the answer has changed.
3. **Use semantic structure.** Prefer domain/layer subgraphs, stable node IDs,
   quoted labels, `<br/>` for intentional line breaks, and database shapes for
   persistent stores. Label edges with protocols or ports only when that detail
   helps answer the diagram's question.
4. **Use semantic colors.** Architecture flowcharts use the shared palette
   below. Signal-specific observability diagrams may additionally use the
   metric/log/trace/profile classes. Do not invent decorative per-node colors
   or rely on color alone to communicate state.

   ```text
   classDef edge fill:#2563eb,color:#fff,stroke:#1e3a8a;
   classDef service fill:#06b6d4,color:#082f49,stroke:#0e7490;
   classDef worker fill:#f59e0b,color:#451a03,stroke:#b45309;
   classDef platform fill:#7c3aed,color:#fff,stroke:#5b21b6;
   classDef data fill:#22c55e,color:#052e16,stroke:#15803d;
   classDef external fill:#64748b,color:#fff,stroke:#334155;
   classDef metric fill:#ffe8cc,color:#111,stroke:#e8590c;
   classDef log fill:#d3f9d8,color:#111,stroke:#2f9e44;
   classDef trace fill:#c5f6fa,color:#111,stroke:#0c8599;
   classDef profile fill:#f3d9fa,color:#111,stroke:#9c36b5;
   classDef collector fill:#a5d8ff,color:#111,stroke:#1971c2;
   classDef planned fill:#fff,color:#475569,stroke:#64748b,stroke-dasharray:5 5;
   ```

5. **Make state explicit.** Solid arrows are current paths. Dotted arrows mean
   optional, indirect, reference, or documented exceptions and must have a
   label. Planned nodes and edges must also contain the word `planned`; a dashed
   border is supplementary, not the only signal.
6. **Provide a legend at the right level.** A platform-wide architecture with
   four or more semantic classes needs a compact legend. Area-level and smaller
   diagrams may rely on the nearest area legend when they use exactly the same
   palette. Sequence diagrams and data charts do not need class
   definitions.
7. **Render before review.** Render every changed Mermaid block with `mmdc` or
   Kroki, inspect the output for clipping and ambiguous crossings, then run
   link/fence checks. For an area-wide refactor, render every Mermaid block in
   that area, including unchanged diagrams, to catch shared-reader regressions.

## Reference

| Topic | Start here |
|-------|-----------|
| Agent role / platform domains | [Agent role](#agent-role-senior-platform-engineer), [Platform domains](#platform-domains) |
| Engineering skills workflow | [Engineering skills workflow](#engineering-skills-workflow), [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) |
| Cross-repo app context / repo index | [Cross-repo app context](#cross-repo-app-context), [`docs/api/README.md`](docs/api/README.md), [`docs/README.md` § Repositories](docs/README.md#repositories) |
| Microservice API truth | [`docs/api/README.md`](docs/api/README.md) — trust over service-repo READMEs; see [Trusted API documentation](#trusted-api-documentation-docsapi) |
| Docs index | [`docs/README.md`](docs/README.md) |
| Setup / commands | [`docs/platform/setup.md`](docs/platform/setup.md) |
| API (shared rules and service contracts) | [`docs/api/api.md`](docs/api/api.md), [`docs/api/README.md`](docs/api/README.md#service-contracts) |
| Observability | [`docs/observability/README.md`](docs/observability/README.md) |
| Databases | [`docs/databases/architecture.md`](docs/databases/architecture.md) |
| Secrets | [`docs/secrets/README.md`](docs/secrets/README.md), [`docs/secrets/openbao.md`](docs/secrets/openbao.md) |
| Platform edge (gateway) | [`docs/platform/envoy-gateway.md`](docs/platform/envoy-gateway.md) |
| Caching | [`docs/api/caching.md`](docs/api/caching.md) · [`docs/caching/README.md`](docs/caching/README.md) |
| Alerts catalog | [`docs/observability/alerting/alert-catalog.md`](docs/observability/alerting/alert-catalog.md) |
| Proposals (RFC/ADR) | [`docs/proposals/`](docs/proposals/) |
| Repos | [`docs/README.md` § Repositories](docs/README.md#repositories) |
