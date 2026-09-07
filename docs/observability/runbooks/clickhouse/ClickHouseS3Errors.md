# ClickHouseS3Errors

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `max by (replica) (rate(ClickHouseErrorMetric_S3_ERROR{job="clickhouse-server"}[5m])) > 0` |
| **Status** | active — VERIFY-AT-KIND: the series is born on the first S3 error; run the unthresholded form after a deliberate RustFS outage |
| **Dashboard** | ClickHouse → Server engine (`system.errors` top-N table) |
| **Local-stack** | not present — compose has no RustFS and no cold tier |

## Meaning

A replica has been failing S3 requests against the RustFS cold tier for 10
minutes. `otel.otel_logs` and `otel.otel_traces` keep parts older than 7 days on
the `s3` disk (bucket `clickhouse-otel`, prefix per replica) behind a local
cache; every read, write or delete of those parts is an HTTP call to
`rustfs-svc.rustfs.svc.cluster.local:9000`, and each failure increments the
server's `S3_ERROR` counter.

Three causes, in order of likelihood: the RustFS pod is down or restarting (it
is a single Deployment); the `clickhouse-otel` bucket is missing (a fresh
`make up` that skipped or failed the bucket Job); the
`clickhouse-rustfs-credentials` Secret is stale or unmounted.

## Impact

Bounded by design of the storage policy:

- **INSERTs succeed** — new parts land on the hot volume (`default`), and
  `perform_ttl_move_on_insert` is off, so a late row never waits on RustFS.
- **Queries over the last 7 days succeed** — the sparse index and partition
  pruning never touch a cold part.
- **Queries over older data fail** with `S3_ERROR` (Grafana panels with a 30 or
  90-day range).
- **Background work retries**: TTL moves of parts crossing the 7-day line, cold
  part merges, and the whole-part drops at 90 days all fail and are retried on
  the next scheduler pass. Nothing is lost; the hot tier grows until it clears.
- **A replica that restarts during the outage stays down** — the `s3` disk runs
  an access check at server start (`skip_access_check` is false on purpose) and
  the pod will not become ready until RustFS answers.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- clickhouse-client --password "$PW" -q "
SELECT name, value, last_error_time, last_error_message
FROM system.errors WHERE name = 'S3_ERROR' FORMAT Vertical"
```

```sql
-- which background work is failing, and how
SELECT event_time, event_type, table, part_name, disk_name, error, exception
FROM system.part_log
WHERE error > 0 AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC LIMIT 20;

-- is the disk even mounted / reachable from this replica
SELECT name, type, free_space, total_space FROM system.disks WHERE name IN ('s3', 's3_cache');
```

### PromQL

```promql
max by (replica) (rate(ClickHouseErrorMetric_S3_ERROR{job="clickhouse-server"}[5m]))
# all three replicas at once -> RustFS itself; one replica -> that pod's credentials/env
```

### kubectl / logs

```bash
kubectl -n rustfs get deploy rustfs                                  # READY 1/1?
kubectl -n rustfs logs deploy/rustfs --tail=50
kubectl -n rustfs get job rustfs-setup-buckets-init -o jsonpath='{.status.succeeded}'
kubectl -n rustfs logs job/rustfs-setup-buckets-init | grep clickhouse-otel
kubectl -n monitoring get secret clickhouse-rustfs-credentials       # exists?
kubectl -n monitoring exec chi-clickhouse-otel-0-0-0 -- sh -c 'env | grep -c CLICKHOUSE_S3_'   # 2
kubectl -n monitoring logs chi-clickhouse-otel-0-0-0 | grep -i -E 's3|rustfs' | tail -20
```

### VictoriaLogs / traces

Server log lines carrying `S3_ERROR` or `Code: 499` name the endpoint and the
HTTP status RustFS returned (403 → credentials, 404 → bucket, connection refused
→ pod down).

## Mitigation

1. **RustFS down:** `kubectl -n rustfs rollout status deploy/rustfs`; if stuck,
   `kubectl -n rustfs rollout restart deploy/rustfs`. Errors stop within a
   minute; retried moves and drops complete on their own.
2. **Bucket missing:** re-run the bucket Job —
   `kubectl -n rustfs delete job rustfs-setup-buckets-init && flux -n flux-system reconcile kustomization storage-local`
   (the 30-minute CronJob would also recreate it).
3. **Credentials:** compare `kubectl -n monitoring get externalsecret` status for
   `clickhouse-rustfs-credentials` against OpenBAO
   `secret/local/infra/rustfs/backup-cnpg`; a refresh is
   `kubectl -n monitoring annotate externalsecret clickhouse-rustfs-credentials force-sync=$(date +%s) --overwrite`,
   then a pod restart (env is read at start).
4. **Do not** delete objects in the bucket by hand, and never attach a lifecycle
   rule to it: ClickHouse's local metadata references every object it wrote,
   and an object removed behind its back turns a retryable error into a broken
   part.

## Escalation

If RustFS cannot be brought back and the hot tier is filling
(`ClickHouseDiskAlmostFull`), the data-safe retreat is the rollback order in the
ClickHouse hub, § Cold tier on RustFS: `MODIFY TTL` back to DELETE-only, then `MOVE PARTITION ... TO VOLUME 'hot'` per cold partition,
then `MODIFY SETTING storage_policy = 'default'`. That needs RustFS readable for
the moves; without it, the cold partitions are lost with RustFS, and the
VictoriaLogs / VictoriaTraces 7-day copies are what remains.

## Related

- [ClickHouseDiskAlmostFull](ClickHouseDiskAlmostFull.md) — the hot tier fills while moves fail
- [ClickHouseServerErrorsElevated](ClickHouseServerErrorsElevated.md) — the broad counter this one is a slice of
- Cold tier design: `docs/observability/clickhouse/README.md` § Cold tier on RustFS

---
_Last updated: 2026-09-07 — created with the RustFS cold tier (4 of 4)_
