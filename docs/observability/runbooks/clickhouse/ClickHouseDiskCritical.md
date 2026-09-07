# ClickHouseDiskCritical

| | |
|---|---|
| **Severity** | critical |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `chi_clickhouse_metric_DiskFreeBytes{disk="default"} / chi_clickhouse_metric_DiskTotalBytes{disk="default"} < 0.05` — the hot disk only; on Kind the cold tier (RustFS) lives on the same node filesystem, so moving parts cold frees nothing here |
| **Status** | active |
| **Dashboard** | ClickHouse → Data analysis · ClickHouse → Server engine |
| **Local-stack** | present — same ratio `< 0.05` from the server's `ClickHouseAsyncMetrics_Disk*_default` on the named docker volume; there growing the volume is a real option |

## Meaning

Under 5% free on the filesystem behind a ClickHouse replica for 5 minutes.

**This ratio is the node's filesystem, not the 10Gi PVC.** The `standard`
StorageClass on Kind is `rancher.io/local-path`, whose PVs are hostPath
directories: `requests.storage: 10Gi` is advisory, nothing enforces it, and the
disk ClickHouse sees is the whole Kind node's disk — shared with every other pod
scheduled there, including a CNPG instance and everything else on that worker.

That also means **growing the PVC is not a mitigation**: `allowVolumeExpansion`
is unset and there is no quota to grow. The alert summary says "node filesystem"
for this reason.

Both ratio alerts were broken until 2026-08-31 — they divided `DiskFreeBytes`
(label `disk="default"`) by a sum containing `DiskDataBytes` (no `disk` label),
so PromQL matched nothing on every evaluation since the day they were written.
The denominator is now `DiskTotalBytes`.

## Impact

MergeTree refuses writes as the filesystem fills. Inserts fail, merges fail, and
because the disk is the *node's*, the damage is not contained to ClickHouse —
Postgres and every other pod on that worker are on the same filesystem.

## Diagnosis

```bash
PW=$(kubectl get secret -n monitoring clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)

# Which table is the eater -- includes system.* tables, which is often the answer
kubectl exec -n monitoring chi-clickhouse-otel-0-0-0 -- clickhouse-client --password="$PW" --query "
  SELECT database, table, formatReadableSize(sum(bytes_on_disk)) AS disk, sum(rows) AS rows
  FROM system.parts WHERE active GROUP BY database, table ORDER BY sum(bytes_on_disk) DESC LIMIT 15"

# Node-level truth
kubectl get pods -n monitoring -o wide | grep chi-clickhouse
docker exec <kind-node> df -h /var/lib/docker 2>/dev/null || kubectl describe node <node> | grep -A5 Conditions
```

**Check `system.*` before assuming it is `otel.*`.** The engine's own log tables
have their own retention story: six carry a 30-day TTL, five carry a 7-day TTL
set by this repo, and `metric_log` is disproportionately large for its row count
(~1,900 columns). See the hub's
[engine's own log tables](../../clickhouse/README.md#the-engines-own-log-tables).

### PromQL

```promql
chi_clickhouse_metric_DiskFreeBytes / chi_clickhouse_metric_DiskTotalBytes < 0.05
min(chi_clickhouse_metric_DiskFreeBytes / chi_clickhouse_metric_DiskTotalBytes)
```

## Mitigation

1. Find the eater with the `system.parts` query above.
2. If it is `otel.*`, drop the oldest partitions — they are daily
   (`PARTITION BY toDate(Timestamp)`), so this is cheap and precise:
   ```sql
   ALTER TABLE otel.otel_logs DROP PARTITION '2026-06-01';
   ```
3. If it is `system.*`, check for `<name>_0` leftovers — changing a system
   table's engine renames the old one and the copy inherits **no** TTL, so it
   grows forever until dropped. Per replica.
4. Free space on the node — this is a node problem as much as a ClickHouse one.
5. **Do not** try to grow the PVC. See above.

The 90-day TTL cannot rescue a same-day spike; it drops whole day-partitions on
schedule, not on pressure.

## Escalation

Critical, and escalate on the **node**, not only on ClickHouse. Everything
sharing that worker's filesystem is at risk, and the ClickHouse alert is simply
the one that noticed first.

## Related

- [ClickHouseDiskAlmostFull](ClickHouseDiskAlmostFull.md) — the 15% warning that
  should have fired first.
- [ClickHouseTooManyParts](ClickHouseTooManyParts.md) — merge starvation inflates
  on-disk size.
- Hub: [Retention & compression](../../clickhouse/README.md#retention--compression)

---
_Last updated: 2026-09-05 — created; the clickhouse alert group had no runbooks at all_
