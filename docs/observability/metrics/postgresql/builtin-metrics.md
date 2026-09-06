# CNPG built-in metrics

CloudNativePG ships a set of **built-in** PostgreSQL metrics that run on every
cluster without any custom SQL — this page is the operator-facing inventory of
what is available out of the box, so you know which signals exist before reaching
for a [custom query](custom-metrics.md).

| Quick facts | |
|---|---|
| Source A | `cnpg-default-monitoring` ConfigMap (13 default queries), enabled by `disableDefaultQueries: false` in each `Cluster.spec.monitoring` |
| Source B | `cnpg_collector_*` — instance-manager collector metrics (always on, not query-driven) |
| Source C | `barman_cloud_cloudnative_pg_io_*` — Barman Cloud plugin backup metrics (supersede the collector backup metrics) |
| Metric prefix | `cnpg_` — series are `cnpg_<query>_<column>` (default queries) or `cnpg_collector_<name>`; backup series use the plugin prefix |
| Clusters | `platform-db` (ns `platform`), `product-db` (ns `product`) |
| Custom counterpart | [custom-metrics.md](custom-metrics.md) |
| Scrape | repo `PodMonitor` (`monitoring/podmonitor.yaml`) with `podTargetLabels: [cnpg.io/cluster, cnpg.io/instanceRole, cnpg.io/instanceName]` → `cnpg_io_cluster` label |

## Overview

Two independent built-in sources feed the `cnpg_*` namespace:

1. **Default queries** — CNPG mounts a `cnpg-default-monitoring` ConfigMap and runs
   its 13 queries alongside the custom set. Because `disableDefaultQueries` is
   `false`, these always run; **do not re-implement them as custom queries** (that
   shadows the built-in and can drop columns — see the removed `pg_stat_checkpointer`
   / `pg_database_size` note in [custom-metrics.md](custom-metrics.md)).
2. **Collector metrics** — the instance manager exports `cnpg_collector_*` directly
   (cluster liveness, WAL, fencing). These are not queries and cannot be
   disabled. The **backup** collector metrics are the exception: since the clusters
   moved to the Barman Cloud CNPG-I plugin, backup timestamps are emitted as
   `barman_cloud_cloudnative_pg_io_*` through the same exporter, and the old
   `cnpg_collector_*backup*` names are no longer populated (plugin migration guide,
   "Verify your metrics").

Most **chart** and **deep-signal** alerts consume built-in metrics; custom queries
add per-table / per-statement / lock-level detail the built-ins do not cover.

## Default queries (`cnpg-default-monitoring`)

| Query | Key emitted metrics (`cnpg_…`) | Consumed by alert |
|-------|--------------------------------|-------------------|
| `pg_stat_database` | `pg_stat_database_deadlocks`, `_blks_hit`, `_blks_read`, `_temp_bytes`, `_temp_files`, `_xact_commit`, `_xact_rollback`, `_conflicts`, `_blk_read_time`, `_blk_write_time`, `_tup_*` | `CNPGDeadlocksIncreasing`, `CNPGLowCacheHitRatio`, `CNPGTempFileSpill` |
| `pg_database` | `pg_database_size_bytes`, `pg_database_xid_age`, `pg_database_mxid_age` | `CNPGTransactionIDWraparoundWarning/Critical`; DB-size dashboards |
| `pg_stat_archiver` | `pg_stat_archiver_archived_count`, `_failed_count`, `_last_archived_time`, `_last_failed_time`, `_seconds_since_last_archival`, `_seconds_since_last_failure`, `_last_*_wal_start_lsn`, `_stats_reset_time` | `CNPGWALArchiveFailing` |
| `pg_stat_checkpointer` | `pg_stat_checkpointer_checkpoints_timed`, `_checkpoints_req`, `_write_time`, `_sync_time`, `_buffers_written`, `_restartpoints_timed/req/done`, `_stats_reset_time` | `CNPGCheckpointPressure` |
| `pg_stat_bgwriter` | `pg_stat_bgwriter_buffers_alloc`, `_buffers_clean`, `_maxwritten_clean`, `_stats_reset_time` | (dashboards) |
| `pg_replication` | `pg_replication_lag`, `_in_recovery`, `_is_wal_receiver_up`, `_streaming_replicas` | `CNPGClusterHACritical/Warning`, `CNPGClusterStandbyNotStreaming`. **`pg_replication_lag` is no longer alerted on**: it is `now() - pg_last_xact_replay_timestamp()`, so it grows without bound on an idle standby — `CNPGClusterPhysicalReplicationLag*` moved to `pg_replication_slots_pg_wal_lsn_diff` (bytes) on 2026-09-06 and `CNPGClusterHighReplicationLag` was removed as a duplicate |
| `pg_replication_slots` | `pg_replication_slots_active`, `_pg_wal_lsn_diff` | (dashboards) |
| `pg_stat_replication` | `pg_stat_replication_write_lag_seconds`, `_flush_lag_seconds`, `_replay_lag_seconds`, `_*_diff_bytes`, `_backend_xmin_age`, `_backend_start` | (dashboards) |
| `backends` | `backends_total`, `backends_max_tx_duration_seconds` | `CNPGClusterHighConnectionsWarning/Critical` (with `pg_settings`) |
| `backends_waiting` | `backends_waiting_total` | (dashboards) |
| `pg_settings` | `pg_settings_setting` (e.g. `{name="max_connections"}`) | `CNPGClusterHighConnections*` |
| `pg_postmaster` | `pg_postmaster_start_time` | (uptime dashboards) |
| `pg_extensions` | `pg_extensions_update_available` | (maintenance dashboards) |

## Collector metrics (`cnpg_collector_*`)

| Metric | Meaning | Consumed by alert |
|--------|---------|-------------------|
| `cnpg_collector_up` | exporter/instance liveness | `CNPGClusterOffline` |
| `cnpg_collector_fencing_on` | instance fenced | `CnpgClusterFenced` |
| `cnpg_collector_pg_wal` (label `value` ∈ `size,count,keep,min,max`) | WAL directory stats | `PostgresWALSizeHigh` (`value="size"`) |
| `cnpg_collector_pg_wal_archive_status` | last archive success/fail | (WAL runbooks) |
| `cnpg_collector_last_available_backup_timestamp`, `_last_failed_backup_timestamp` | backup recency — **superseded** by the plugin metrics below; not populated for plugin-managed backups | (none — alerts moved to plugin metrics) |
| `cnpg_collector_wal_records`, `_wal_bytes`, `_wal_fpi`, `_wal_buffers_full` | WAL generation | (dashboards) |
| `cnpg_collector_sync_replicas`, `_replica_mode`, `_nodes_used`, `_manual_switchover_required` | topology/HA state | (dashboards) |
| `cnpg_collector_postgres_version`, `_collection_duration_seconds`, `_last_collection_error` | metadata / exporter health | (dashboards) |
| `cnpg_collector_first_recoverability_point` | **superseded** by the plugin metric below | (none) |

## Barman Cloud plugin metrics (`barman_cloud_cloudnative_pg_io_*`)

Exposed through the same instance-manager exporter once a cluster archives via the
Barman Cloud plugin (all three clusters do). These are the metrics backup alerting
must query.

| Metric | Meaning | Consumed by alert |
|--------|---------|-------------------|
| `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` | UNIX timestamp of the most recent successful backup | `PostgresBackupTooOld`, `PostgresBackupMetricsMissing` |
| `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp` | UNIX timestamp of the most recent failed backup | `PostgresBackupFailed` |
| `barman_cloud_cloudnative_pg_io_first_recoverability_point` | earliest point in time the cluster can be recovered to | (no alert yet — recoverability-vs-policy alerting is an open gap) |

## Operations

- **Verify a built-in metric is live:** `count by (cnpg_io_cluster) (<metric>)` in
  VMUI (`:8428`) should return one series per cluster. If `platform-db` is missing
  the `cnpg_io_cluster` label, check the cluster is using the repo `PodMonitor`
  (`enablePodMonitor` must be **false** so the operator's label-less PodMonitor does
  not win — see [README.md](README.md#scrape-architecture--rule-layout)).
- **Do not shadow built-ins** with a same-named custom query — CNPG loads the custom
  set after the defaults, so a duplicate query name overrides and can drop columns.

## Related documentation

- [README.md](README.md#scrape-architecture--rule-layout) — scrape architecture & rule layout
- [custom-metrics.md](custom-metrics.md) — the custom-query counterpart
- [alert-catalog.md](../../alerting/alert-catalog.md#4-postgresql--cloudnativepg) — §4 / §4b PostgreSQL alerts
- Runbooks: [postgresql/](../../runbooks/postgresql/)

---
_Last updated: 2026-08-31 — Barman Cloud plugin metrics documented; collector backup metrics marked superseded._
