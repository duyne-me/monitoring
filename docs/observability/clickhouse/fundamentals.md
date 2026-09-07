# ClickHouse fundamentals — why this OLAP store exists

The engine behind the 90-day `otel_logs` / `otel_traces` SQL store: why
**columnar OLAP** is a different job from LogsQL or Postgres, how **MergeTree**
prunes granules, and how this cluster maps onto the published architecture
(1 shard × 3 replicas — not the paper's 2×2).

| | |
|---|---|
| **Status** | Learning companion to the [platform hub](README.md) — engine concepts, not ops runbooks |
| **Tables in scope** | `otel.otel_logs`, `otel.otel_traces` (+ the [trace-id MV](materialized-views.md)) |
| **Topology here** | **1 shard × 3 replicas**, ClickHouse Keeper quorum ([ADR-065](../../proposals/adr/ADR-065-clickhouse-replicated-topology/)) |
| **Not this page** | Grafana, alerts, Flux waves → [README](README.md). Schema skill → [schema-and-queries](schema-and-queries.md) |

---

## Overview

VictoriaLogs and VictoriaTraces answer *find this line / this trace* inside a
**7-day** window. ClickHouse answers *how does the whole set look?* over **90
days**: `GROUP BY`, percentiles, and a `trace_id` JOIN in one store. Those are
different questions. High-scale logging platforms pick ClickHouse when the job
is **aggregation, GROUP BY, correlation, and analytics over very large
volumes** — not when the job is full-text search. This Kind cluster is not
petabytes; the **granule prune** is the same idea at a smaller row count.

It is **not** a replacement for CloudNativePG (OLTP source of truth) or for
LogsQL / the Jaeger query API.

---

## Why OLAP (and why still ClickHouse next to VictoriaLogs)

| | OLTP (PostgreSQL here) | Search / triage (VL / VT) | OLAP (ClickHouse here) |
|---|---|---|---|
| Typical question | "Order #123 for user X?" | "Find this error line / this trace" | "Error rate by service over 30 days?" |
| Language | SQL (row lookup, ACID) | LogsQL / Jaeger API | SQL (`GROUP BY`, `quantile`, JOIN) |
| Write pattern | UPDATE/DELETE | Append streams | Append INSERT |
| Retention on this platform | Durable business data | **7 days** | **90 days** |

**In plain terms:** OLTP answers *what is this row?*; search answers *where is
this event?*; OLAP answers *how does the whole set look?*

ClickHouse does **not** replace LogsQL. Use VictoriaLogs to find and triage.
Use ClickHouse when the dashboard needs a histogram, a status mix, or a
correlation across days — the same reason the edge **access log** is
ClickHouse-only ([ADR-061](../../proposals/adr/ADR-061-edge-log-routing/)):
attributes-only records whose real questions are SQL. The junior skill of
making those queries cheap is [schema-and-queries](schema-and-queries.md).

### Columnar vs row pages

PostgreSQL stores **rows** on a page (all columns of one tuple together).
ClickHouse stores **columns** as separate files inside a **part**.
`SELECT ServiceName, count()` reads only the `ServiceName` files, and those
files compress well because neighbouring values are alike.

```mermaid
flowchart LR
  subgraph rowStore ["PostgreSQL — row pages"]
    Page["8KB page<br/>all columns of a row together"]
  end
  subgraph colStore ["ClickHouse — column files in a part"]
    C1["ServiceName file"]
    C2["Duration file"]
    C3["Timestamp file"]
  end
  Q["SELECT ServiceName, count()"] --> C1

  classDef data fill:#22c55e,color:#052e16,stroke:#15803d;
  classDef platform fill:#7c3aed,color:#fff,stroke:#5b21b6;
  class Page,C1,C2,C3 data;
  class Q platform;
```

Measured compression on local-stack (see the hub [Operations](README.md#operations)):
`otel_traces` ~**10.5×**, `otel_logs` ~**8×**.

---

## MergeTree: parts, partitions, merges, sparse index

MergeTree is **not** a Postgres B-tree heap. Writes append **immutable parts**.
Background **merges** combine parts while keeping the table's `ORDER BY`.
**Partitions** group those parts for lifecycle purposes — here, calendar days
(`PARTITION BY toDate(Timestamp)`). Why that grain, and what it costs to get it
wrong, is [Partitions and TTL](#partitions-and-ttl--the-lifecycle-pair) below.

| | PostgreSQL B-tree | ClickHouse MergeTree |
|---|---|---|
| Primary purpose | Point lookup / range on heap | Sort + prune **granules** for scans |
| Write path | Update pages / WAL | Append new parts |
| Background | Autovacuum / checkpoints | Merges combining parts |
| Index grain | One entry per row (typical) | One sparse entry **per granule** (~8192 rows) |

**Insert → part → merge** (vendor Figure 3):

![Inserts produce parts; background merges combine them while preserving sort order](./image/ch-vldb-fig-03-inserts-merges.png)

**Sparse primary index** (vendor Figure 4): the index stores the first row's
sort key of each granule, not every row. A `WHERE` that matches the `ORDER BY`
prefix can skip granules. A filter on a column that is *not* a prefix (for
example a bare `TraceId` on `otel_traces`) does **not** get that prune — that
is why traces also have a bloom skip index and a [materialized view](materialized-views.md).

![Sparse primary index: one mark per granule, not per row](./image/ch-vldb-fig-04-primary-index.png)

**Skipping indexes** (minmax, set, bloom, text) are extra prune aids on columns
that are not the primary sort. **Projections** are an alternative extra
`ORDER BY` stored beside the table. This platform uses skip indexes + one MV
instead of projections.

**Mutations / lightweight delete / AggregatingMergeTree rollups** are for
workloads that rewrite or pre-aggregate in place. OTel ingest here is
**append-only**; those engines are not this workload.

Hands-on: [Playground](README.md#playground--mergetree-by-hand) (`system.parts`,
`EXPLAIN indexes = 1`).

---

## Partitions and TTL — the lifecycle pair

A newcomer's first instinct is that a partition is a kind of index: chop the
table finer and queries get faster. It is not. **A partition is a lifecycle
boundary.** Its job is to make *deleting* and *moving* data cheap, and to keep
the blast radius of maintenance small.

The query win from partitions is real but **coarse**: a `WHERE` on the
partition key skips whole partitions before a single granule is read. The
fine-grained win — the one that decides whether a dashboard query is cheap —
comes from `ORDER BY` and granule skipping
([schema-and-queries](schema-and-queries.md)). Picking a finer partition to
"speed up queries" buys very little and costs metadata and part overhead.

### One rule explains the rest

**A part never spans two partitions.** That is why `DROP PARTITION` is a
directory removal rather than a rewrite — and TTL is just a scheduled delete,
so it inherits the same economics.

### The alignment rule

**Partition granularity should match TTL granularity.** When every row in a
part expires at the same moment, expiry becomes a file delete. When it does
not, ClickHouse has to separate live rows from dead ones *inside* the part.

Which of those happens is decided by MergeTree settings — and the default is
the expensive one. Values below are read from this cluster's
`system.merge_tree_settings`:

| Setting | Default here | Meaning |
|---|---|---|
| `ttl_only_drop_parts` | **`0`** | Delete expired **rows**, which means **rewriting the part** |
| `ttl_only_drop_parts = 1` | set per table | Drop the **whole part** — but only once *every* row in it has expired |
| `merge_with_ttl_timeout` | **`14400`** (4 h) | Minimum delay before repeating a delete-TTL merge over the same data |
| `max_number_of_merges_with_ttl_in_pool` | **`2`** | Cap so TTL merges cannot starve ordinary merges |

Now the failure mode. Take a **monthly** partition carrying a **15-day** TTL:

- With `ttl_only_drop_parts = 1` the part is dropped only when its *newest* row
  has also expired. A merged month-wide part therefore survives until roughly
  **month + 15 days** — the data outlives the retention you wrote down.
- With `ttl_only_drop_parts = 0` (the default) the rows do disappear on time,
  but ClickHouse gets there by **rewriting month-sized parts**, and that work
  can repeat as often as every **4 hours** — not once a day.

Neither is a correctness bug. Both are a bill: either retention nobody asked
for, or I/O nobody needed. On object storage that I/O is also egress.

```mermaid
flowchart TB
  Q["A row reaches its TTL"] --> A{"Does partition granularity<br/>match TTL granularity?"}

  A -->|"aligned — daily partition, day-multiple TTL"| D{"ttl_only_drop_parts"}
  A -->|"misaligned — monthly partition, 30d TTL"| M{"ttl_only_drop_parts"}

  D -->|"1"| Drop["Whole part dropped<br/>directory delete, near-free"]
  D -->|"0"| Small["One day's part rewritten<br/>small and bounded"]
  M -->|"1"| Late["Part survives until the<br/>WHOLE month expires<br/>retention overshoots"]
  M -->|"0"| Heavy["Month-sized parts rewritten<br/>repeatable every 4h"]

  classDef platform fill:#7c3aed,color:#fff,stroke:#5b21b6;
  classDef data fill:#22c55e,color:#052e16,stroke:#15803d;
  class Q,A,D,M platform;
  class Drop,Small,Late,Heavy data;
```

### Read it straight off the partition name

The cheapest way to tell which scheme a table uses is to look at what the
partition is *called* — `toDate()` yields a date, `toYYYYMM()` yields a month:

```sql
SELECT table, any(partition) AS example
FROM system.parts
WHERE database = 'system' AND active
GROUP BY table ORDER BY table;
-- trace_log   2026-09-04   <- daily
-- metric_log  202609       <- monthly
```

### What this platform actually runs

Measured on the deployed cluster:

| Tables | `PARTITION BY` | TTL | `ttl_only_drop_parts` | Verdict |
|---|---|---|---|---|
| `otel_logs`, `otel_traces`, `otel_traces_trace_id_ts` | `toDate(Timestamp)` — **daily** | 90 d | **`1`** | aligned; expiry is a part drop |
| `query_log`, `part_log` | `event_date` — **daily** | 30 d | `0` | aligned; one day rewritten at a time (operator-owned; the setting is a follow-up) |
| `trace_log` | `event_date` — **daily** | 7 d | **`1`** | aligned; operator table, TTL and setting overridden by this repo |
| `processors_profile_log`, `aggregated_zookeeper_log`, `zookeeper_connection_log` | `event_date` — **daily** | 30 d | **`1`** | aligned since 2026-09-07; shipped `toYYYYMM` — the misaligned case, 30 `event_date`s per partition expiring on 30 different days |
| `metric_log`, `asynchronous_metric_log`, `text_log`, `error_log`, `background_schedule_pool_log`, `query_views_log` | `event_date` — **daily** | 7 d | **`1`** | aligned; set by this repo after they shipped monthly with no TTL at all; the setting joined 2026-09-07 |
| `query_metric_log` | — | — | — | **removed** 2026-09-07: no TTL upstream, 1,391 columns, no reader |

Two things are worth reading twice.

First, the `otel.*` row is the textbook case, and it is deliberate: daily
partition + `ttl_only_drop_parts = 1` means a 90-day expiry costs one directory
delete per table per day.

Second, the operator did the same homework. The Altinity operator ships config
that **overrides** `query_log`, `part_log` and `trace_log` to
`PARTITION BY event_date` at the same time as it gives them a 30-day TTL — it
aligned them on purpose. The three tables that inherit an upstream 30-day TTL
without that override are the ones left monthly, and they are the misaligned
row above.

The last row is this platform's own work, and it is the same lesson applied: the
five tables shipped monthly-partitioned with no TTL, so giving them a 7-day
expiry meant moving `PARTITION BY` to daily in the same change. Details and the
`_0` cleanup it requires: [the engine's own log tables](README.md#the-engines-own-log-tables).

### Do not over-partition

Hourly partitions exist, and they are almost always the wrong answer here:
every partition carries metadata and its own parts, so a finer grain trades a
lifecycle win you already have for merge pressure you did not need. Reach for
daily when the volume is large and the lifecycle is measured in days; monthly
is fine for low-volume tables retained for months.

---

## Query layer (short)

A `SELECT` is parsed, planned, then executed by reading **granules** in
vectorized blocks — many values of one column at a time, not one row at a
time. Parallelism is across parts and granules on a replica. This page does
not cover the query compiler; the SRE skill is reading `EXPLAIN indexes = 1`
until `Granules: a/b` is small. That loop lives in
[schema-and-queries](schema-and-queries.md).

```mermaid
flowchart LR
  SQL["SQL"] --> Parser["Parser"]
  Parser --> Plan["Plan<br/>which parts / indexes"]
  Plan --> Exec["Executor<br/>read granules as column blocks"]
  Exec --> Parts[("MergeTree parts")]

  classDef platform fill:#7c3aed,color:#fff,stroke:#5b21b6;
  classDef data fill:#22c55e,color:#052e16,stroke:#15803d;
  class Parser,Plan,Exec platform;
  class Parts data;
```

**Distributed tables / extra shards** are **planned** ([ADR-065](../../proposals/adr/ADR-065-clickhouse-replicated-topology/)
out of scope for a second shard). Do not treat a `Distributed` engine as
installed.

---

## Architecture overview (VLDB) vs what is deployed

Vendor Figure 2 is the published engine layering (client protocol, query
pipeline, storage, coordination). Grafana on this platform talks **native
`:9000`**, not the HTTP `:8123` path used by `curl` in the playground.

![ClickHouse engine layers from the VLDB architecture overview](./image/ch-vldb-fig-02-architecture.png)

**Deployed replication** is **1 shard × 3 replicas** with **ClickHouse Keeper**
holding replica metadata. A replica that loses its Keeper session serves
reads and refuses writes. Vendor Figure 6 shows replication + Keeper; the
paper's **2 shard × 2 replica** drawing is **reference, not deployed**.

![Replication coordinated through ClickHouse Keeper](./image/ch-vldb-fig-06-replication.png)

```mermaid
flowchart TB
  subgraph deployed ["Deployed — 1 shard × 3"]
    G["Grafana native :9000"] --> S0["Replica 0<br/>ReplicatedMergeTree"]
    G --> S1["Replica 1"]
    G --> S2["Replica 2"]
    K["ClickHouse Keeper<br/>3-node quorum"] -.-> S0
    K -.-> S1
    K -.-> S2
  end
  subgraph paper ["Paper 2×2 — reference, not deployed"]
    P["2 shards × 2 replicas"]
  end

  classDef platform fill:#7c3aed,color:#fff,stroke:#5b21b6;
  classDef data fill:#22c55e,color:#052e16,stroke:#15803d;
  classDef planned fill:#fff,color:#475569,stroke:#64748b,stroke-dasharray:5 5;
  class G,K platform;
  class S0,S1,S2 data;
  class P planned;
```

Ingest topology (Collector fan-out, metrics never land here) stays on the
[hub Architecture](README.md#architecture). Since 2026-09-07 the cold tier is
**deployed** on Kind: `otel_logs` and `otel_traces` move parts older than 7 days
to the in-cluster RustFS object store (`TTL ... TO VOLUME 'cold'`) and still
**drop** them at 90 days; the third table and the `system.*` logs stay on the
PVC. On Kind that buys the production shape, not capacity — every path is the
same node filesystem and, without zero-copy, cold bytes exist three times. The
mechanics are in the [hub](README.md#cold-tier-on-rustfs).

**A trap that now applies here:** ClickHouse keeps metadata that
references every object it wrote, so the object store must never delete parts
behind its back. A bucket lifecycle rule that expires objects on the same
schedule as the table TTL will race the engine, and the loser is a query that
reads metadata pointing at an object that is gone. Give the engine room to
finish its own cleanup — table TTL first, bucket lifecycle a few days later as
a **backstop for orphans only**, never as the primary retention mechanism. The
[alignment rule](#the-alignment-rule) matters more here than on a PVC, because
a month-sized part rewritten every 4 hours is egress you pay for. The RustFS
bucket therefore carries **no lifecycle rule at all**: the engine deletes, the
bucket never expires.

---

## How it works on this platform

| Store | Job |
|-------|-----|
| PostgreSQL (`product-db` / `platform-db`) | OLTP source of truth |
| VictoriaMetrics | RED metrics, alerting |
| VictoriaLogs / VictoriaTraces | Live ops find/triage, 7d |
| **ClickHouse** | Long-retention SQL, `GROUP BY`, `trace_id` JOIN, 90d |

Schema DDL is owned by the `clickhouse-schema` Job (`create_schema: false` on
the exporter). Details: [README — how it works here](README.md#how-it-works-in-this-platform).

---

## Operations snippets

```sql
-- parts + compression (run on one replica; system.parts is local)
SELECT table, count() AS parts, sum(rows) AS rows,
       formatReadableSize(sum(data_compressed_bytes)) AS comp,
       round(sum(data_uncompressed_bytes)/sum(data_compressed_bytes),1) AS ratio
FROM system.parts WHERE database='otel' AND active GROUP BY table;

-- prune proof — ServiceName is the first ORDER BY key on otel_traces
EXPLAIN indexes = 1
SELECT count() FROM otel.otel_traces WHERE ServiceName = 'platform.envoy-gateway-system';
```

Connect commands: [Playground](README.md#playground--mergetree-by-hand).

---

## References

- [Architecture overview (academic / VLDB 2024)](https://clickhouse.com/docs/concepts/core-concepts/academic-overview)
- [MergeTree](https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree)
- [Choosing a primary key](https://clickhouse.com/docs/best-practices/choosing-a-primary-key)
- Platform: [ClickHouse hub](README.md) · [schema-and-queries](schema-and-queries.md) · [materialized views](materialized-views.md)
- Postgres contrast: [storage and WAL](../../databases/fundamentals/storage-and-wal.md)

---

_Last updated: 2026-09-07 — audit table: every repo-managed `system.*` engine string now carries `ttl_only_drop_parts = 1`, the three monthly tables are daily, `query_metric_log` is removed (issue #1025). Previously 2026-09-04 — the platform audit table now shows the five formerly unmanaged `system.*` tables on a 7-day TTL with daily partitions, set by this repo. Earlier the same day: added **Partitions and TTL**: the alignment rule between `PARTITION BY` and TTL granularity, both `ttl_only_drop_parts` modes with the settings read off the deployed cluster, the audit of which `otel.*` and `system.*` tables are aligned, and the object-store lifecycle trap for the planned S3 tier. Inline vendor-figure source links removed (References already cites the overview). Earlier the same day: page created._
