# ADR-067: Constrain Commerce CDC to an Explicit Source Allowlist

> **Decision summary:** We will constrain commerce CDC with CNPG-managed
> column-list publications, exact-table source grants, and exhaustive PeerDB
> exclusions because analytical convenience must not become schema-wide data
> access. We accept that PeerDB's snapshot credential can still query every
> column of an allowed base table in exchange for avoiding shadow tables and
> transactional-service export APIs.

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Decision date** | 2026-09-09 |
| **Owners** | `duynhne` |
| **Deciders** | `duynhne` |
| **Scope** | PostgreSQL data egress and authorization for the RFC-0030 PeerDB mirrors |
| **Affected components** | CNPG `Publication` and `DatabaseRole` resources; source DDL/grants; PeerDB source credentials and mappings; staging and ClickHouse inspection gates |
| **Related RFC** | [RFC-0030](../../rfc/RFC-0030/) |
| **Related research** | [research.md](../../rfc/RFC-0030/research.md) |
| **Supersedes** | — |
| **Superseded by** | — |
| **Implementation tracking** | RFC-0030 source-safety and correctness gates |
| **Adoption** | Not started |

## Context

PeerDB requires PostgreSQL logical replication for changes and SQL `SELECT` for
its initial snapshot. PostgreSQL publication column lists constrain what enters
the WAL stream, but they do not constrain what the same database login may read
with SQL. Granting snapshot access to a base table therefore exposes all its
columns to that credential even when only a subset is published.

The selected order, checkout, and payment tables contain columns that must not
leave the transactional boundary, including customer, address, payment-provider,
idempotency, workflow, and audit material. A schema-wide reader would turn every
future table into an implicit analytics export.

## Scope

### In scope

- Which tables and columns may leave each source database.
- PeerDB source identity, privileges, and compensating controls.
- The review and verification gates for forbidden data.

### Out of scope

- The CDC product and runtime topology, decided by ADR-066.
- Database ownership and application runtime privileges.
- ClickHouse serving metrics and staff authorization.
- Row-level security for tables that do not currently use RLS.

## Decision drivers

| Priority | Driver | Why it matters |
|---------:|--------|----------------|
| 1 | Minimize sensitive-data exposure | A replicated column is copied into staging and analytical storage |
| 2 | Reviewable desired state | Source owners must see every exported table and column in git |
| 3 | Snapshot compatibility | PeerDB still needs a supported initial-copy path |
| 4 | No implicit future access | New schemas and tables must remain denied by default |
| 5 | Operational simplicity | Controls must remain understandable during rotation and incident response |

## Decision

We will declare one CNPG `Publication` per source database with explicit table
and column objects and reclaim policy `retain`. Publication membership must
match the RFC-0030 v1 source contract, including every required replica-identity
column. A newly added source column is excluded until source-owner review.

Each database will have a distinct non-owning, non-superuser PeerDB login. It
receives only the connection, schema usage, replication, and exact-table
`SELECT` privileges needed by its mirror. It receives no DDL, ownership,
`BYPASSRLS`, schema-wide default privileges, or `SELECT ON ALL TABLES IN SCHEMA`.
PeerDB mappings will independently exclude every forbidden column.

We explicitly accept that exact-table `SELECT` lets the credential query
forbidden columns in an allowed table. Publication columns are a WAL egress
boundary, not a PostgreSQL SQL-authorization boundary. HBA, TLS, NetworkPolicy,
secret isolation, audit, and pre-exposure staging/ClickHouse inspection bound
that residual risk.

### Decision rules

| Rule | Required behavior |
|------|-------------------|
| **Allowlist ownership** | Source owners review every publication table and column; additions are deny-by-default |
| **Identity isolation** | One login per source database; credentials and grants are not shared across mirrors |
| **Privileges** | Exact-table `SELECT` plus required connection/replication privileges only; no ownership, DDL, `BYPASSRLS`, or schema-wide defaults |
| **Two layers** | CNPG publication column lists constrain WAL and PeerDB exclusions constrain snapshot/mapping behavior |
| **Exposure gate** | Staging objects, raw ClickHouse columns, logs, and traces must be inspected before any API route opens |
| **Failure behavior** | A forbidden field finding pauses the affected mirror and removes API reachability while evidence is preserved and purged |

## Alternatives considered

| Option | Benefits | Costs / risks | Result |
|--------|----------|---------------|--------|
| **A — Exact-table reads plus two explicit column allowlists** | Works with PeerDB snapshot and CDC; reviewable in git | Credential can query forbidden columns on allowed tables | Selected |
| **B — Sanitized shadow tables** | SQL grants can expose only approved columns | Adds change propagation, storage, reconciliation, and another source-side writer path |
| **C — Service export APIs** | Services enforce field-level contracts | Three bulk APIs, application load, pagination/checkpoint ownership, and delete semantics |
| **D — Batch queries with projected columns** | SQL sees only the selected query result | Reintroduces the batch transport state machine rejected by ADR-066 |
| **E — Publication allowlist without PeerDB exclusions** | Fewer configuration surfaces | Snapshot behavior would rely on a WAL control that does not govern SQL reads | Rejected |

### Why the selected option won

It is the smallest control set compatible with PeerDB's real snapshot
requirements. It makes exported columns visible in desired state, denies new
tables by default, and keeps an independent destination mapping check.

### Why the closest alternative lost

Sanitized shadow tables would provide a stronger SQL authorization boundary,
but only by adding another replicated representation inside the transactional
cluster. Maintaining those rows correctly across updates and deletes recreates
the transport and reconciliation problem before PeerDB even starts.

## Consequences

### Positive consequences

- Every exported table and column is reviewable and versioned.
- New tables and columns do not enter analytics automatically.
- A compromised credential is limited to one database and named tables.
- PeerDB never owns source DDL or application data.

### Negative consequences and accepted trade-offs

- The snapshot login can query forbidden columns from an allowed table.
- Publication and PeerDB mapping changes must be coordinated.
- Every mapped DDL change requires classification and a pause/gate decision.
- Secret rotation, audit coverage, and negative privilege tests become permanent obligations.

### Neutral consequences

- CNPG manages role attributes and publications; an idempotent source DDL step manages object grants.
- RLS remains absent; adopting RLS later requires a separate review of logical replication behavior.

## Implementation obligations

| Obligation | Owner | Tracking | Completion signal |
|------------|-------|----------|-------------------|
| Declare the three publications and source roles | Platform / Database | RFC-0030 source-safety gate | CNPG reports `status.applied=true` at the observed generation |
| Apply exact object grants and deny broad grants | Source owners | RFC-0030 source DDL | Positive selected-table tests and negative cross-table/DDL tests pass |
| Maintain matching PeerDB exclusions | Platform | RFC-0030 mirror configuration | Snapshot and CDC contain only the approved v1 columns |
| Inspect every egress layer | Security / Platform | RFC-0030 correctness gate | Forbidden-column scan passes in staging, raw tables, logs, and traces |
| Add credential rotation and leak response procedures | Platform / Security | RFC-0030 close-out | Rotation and pause/purge drills pass |

## Validation and compliance

| Requirement | Verification |
|-------------|--------------|
| Exact database scope | Each source credential fails against the other two databases |
| Exact table scope | Selected tables are readable; non-selected and newly created tables are denied |
| No write or DDL access | `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, ownership, and role escalation tests fail |
| Column egress | Concurrent snapshot and insert/update/delete tests expose only the source contract columns |
| Secret rotation | New credential reconnects; the old credential is rejected |
| Leak response | Inject a canary forbidden field, verify detection, mirror pause, route removal, and purge evidence |

## Revisit triggers

Re-open this decision when one or more of the following become true:

- Policy or compliance forbids table-wide SQL readability by the CDC credential.
- A selected source table begins carrying materially more sensitive data.
- PeerDB gains a proven snapshot mode with enforceable column-level SQL access.
- RLS is introduced on a mapped table.
- Forbidden-data inspection or credential-isolation drills fail.

A changed decision requires a new ADR that supersedes this one.

## References

- [RFC-0030](../../rfc/RFC-0030/)
- [RFC-0030 research](../../rfc/RFC-0030/research.md)
- [PostgreSQL extension and database platform](../../../databases/architecture.md)

## History

| Date | Status / adoption | Change |
|------|-------------------|--------|
| 2026-09-09 | Proposed / Not started | Initial decision drafted during RFC-0030 architecture review |
| 2026-09-09 | Accepted / Not started | Owner accepted the architecture; qualification remains Phase 0 of implementation |

---
_Last updated: 2026-09-09._
