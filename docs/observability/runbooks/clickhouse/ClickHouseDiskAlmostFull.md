# ClickHouseDiskAlmostFull

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `chi_clickhouse_metric_DiskFreeBytes{disk="default"} / chi_clickhouse_metric_DiskTotalBytes{disk="default"} < 0.15` — the hot disk only; the `s3` / `s3_cache` series exist since the RustFS cold tier and report the object-storage ceiling |
| **Status** | active |
| **Dashboard** | ClickHouse → Data analysis |
| **Local-stack** | present — `ClickHouseAsyncMetrics_DiskAvailable_default / DiskTotal_default < 0.15` on the named docker volume |

## Meaning

Under 15% free for 15 minutes on the filesystem behind a replica. The early
warning for [ClickHouseDiskCritical](ClickHouseDiskCritical.md), and the one that
gives you time to act deliberately rather than by dropping partitions under
pressure.

As with the critical, **this ratio measures the Kind node's filesystem, not the
10Gi PVC** — local-path PVs are hostPath directories with no quota. The
kubelet-based PVC alerts (`KubePersistentVolumeFillingUp`) are inert here for the
same reason and are documented as such in the catalog.

## Impact

None yet. This is headroom, not failure.

## Diagnosis

Same as the critical, with time to look at the trend rather than only the level:

```promql
# How fast is it filling
predict_linear(chi_clickhouse_metric_DiskFreeBytes[6h], 24*3600) < 0
deriv(chi_clickhouse_metric_DiskFreeBytes[1h])
```

```bash
PW=$(kubectl get secret -n monitoring clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n monitoring chi-clickhouse-otel-0-0-0 -- clickhouse-client --password="$PW" --query "
  SELECT database, table, formatReadableSize(sum(bytes_on_disk)) d
  FROM system.parts WHERE active GROUP BY 1,2 ORDER BY sum(bytes_on_disk) DESC LIMIT 10"
```

## Mitigation

Decide which of three it is before acting:

1. **Real growth in `otel.*`** — retention is doing its job and the volume simply
   grew. Either accept and give the node more disk, or shorten the 90-day TTL,
   which is a deliberate change, not an incident action.
2. **`system.*` outgrowing the data** — the engine's own log tables are a fixed
   cost that does not scale down when idle. Check them; see the hub's
   [engine's own log tables](../../clickhouse/README.md#the-engines-own-log-tables).
3. **Not ClickHouse at all** — the node's filesystem is shared. Something else on
   that worker may be the growth.

## Escalation

Warning. Escalate if `predict_linear` says the trend reaches zero before anyone
would look again.

## Related

- [ClickHouseDiskCritical](ClickHouseDiskCritical.md)
- [ClickHouseTooManyParts](ClickHouseTooManyParts.md)

---
_Last updated: 2026-09-05 — created; the clickhouse alert group had no runbooks at all_
