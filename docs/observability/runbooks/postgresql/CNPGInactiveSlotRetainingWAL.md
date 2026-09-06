# CNPGInactiveSlotRetainingWAL

| | |
|---|---|
| **Severity** | warning |
| **Source** | deep-signal ([`deep-signals-alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/postgres/deep-signals-alerts.yaml)) |
| **Clusters** | `platform-db`, `product-db` |
| **Metrics** | `cnpg_pg_replication_slots_pg_wal_lsn_diff`, `cnpg_pg_replication_slots_active`, `cnpg_pg_replication_in_recovery` |
| **Grafana** | CloudNativePG cluster board |

## Meaning

A replication slot on the **primary** is `inactive` while still retaining more
than **1 GiB** of WAL, for over 15 minutes. Postgres will not recycle WAL a slot
still claims, so the primary's `pg_wal` grows for as long as this holds.

This alert is the **cause**. `CNPGClusterPhysicalReplicationLagCritical` reports
the same incident as a **symptom** — a standby that is behind. Lag can resolve on
its own; a slot pinning WAL cannot, and it ends in a full disk.

## Impact

The primary's PVC fills. On this platform a full disk is especially nasty: it
does **not** announce itself as a storage problem. It surfaces as RBAC
`Forbidden`, API `EOF`, stalled Flux reconciles and pods that will not start —
see [`podman disk-full`](CNPGWALArchiveFailing.md) for the same class of
misdirection. Postgres itself stops accepting writes once it cannot write WAL.

## Diagnosis

The alert names the slot. Start from the primary:

```bash
kubectl exec -n "$NS" "$PRIMARY" -c postgres -- psql -U postgres -c "
  SELECT slot_name, active, wal_status,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
  FROM pg_replication_slots ORDER BY 4 DESC"

# What the retention costs on disk, right now
kubectl exec -n "$NS" "$PRIMARY" -c postgres -- du -sh /var/lib/postgresql/data/pgdata/pg_wal
```

A CNPG slot is named `_cnpg_<cluster>_<instance>` with underscores, so
`_cnpg_platform_db_3` belongs to instance `platform-db-3`. Then ask **why** that
standby is not consuming it:

```bash
# Streaming, or not at all?
kubectl exec -n "$NS" "$STANDBY" -c postgres -- psql -U postgres -c "SELECT * FROM pg_stat_wal_receiver"
# Empty result = no walreceiver = it is not even trying

# Which timeline is each instance on?
for p in <instances>; do
  kubectl exec -n "$NS" "$p" -c postgres -- psql -U postgres -tAc \
    "SELECT '$p TL=' || timeline_id FROM pg_control_checkpoint()"
done

kubectl logs -n "$NS" "$STANDBY" -c postgres --tail=40
```

### The two shapes this takes

**A standby that is merely slow or restarting** — `pg_stat_wal_receiver` has a
row, timelines match, the slot goes active again on its own. Nothing to do but
watch it drain.

**A standby that has diverged** — no walreceiver at all, and its timeline is
*behind* the primary's. The log says it outright:

```
FATAL: could not start WAL streaming: requested starting point 0/84000000
       on timeline 1 is not in this server's history
LOG:   new timeline 2 forked off current database system timeline 1
       before current recovery point 0/84000000
```

That standby replayed **past** the point where the new primary's timeline forked,
so it holds WAL the primary's history does not contain. It can neither stream nor
archive-recover, and **it will never self-heal** — the loop
`restore …history → waiting for WAL → FATAL` repeats forever. Note that the pod
stays `Ready` the whole time, because `hot_standby` answers queries fine; only
this alert and the lag alert reveal it.

## Resolution

For a diverged standby, the instance must be re-cloned. CNPG will rebuild it from
the primary when its PVC and pod are removed:

```bash
kubectl delete pvc -n "$NS" "$STANDBY" && kubectl delete pod -n "$NS" "$STANDBY"
```

Once it rejoins, the slot goes active and the retained WAL is released.

**Do not drop the slot to make the alert stop.** The slot is what lets the
standby catch up; dropping it forfeits that and the standby then needs a rebuild
anyway. The one case for dropping it is a decision *not* to rebuild that
instance — and then it must be dropped, or the primary keeps filling:

```sql
SELECT pg_drop_replication_slot('_cnpg_<cluster>_<n>');
```

## Why the expression looks the way it does

Three details, each found by measuring rather than reasoning:

- **Every instance reports every slot.** A standby's copy of the broken slot
  would double-fire, so `cnpg_pg_replication_in_recovery == 0` keeps only the
  primary's view — which is also the only view that matters, since it is the
  primary's disk at stake.
- **A standby's `pg_wal_lsn_diff` can be negative** (measured `-67108704`). Any
  `max by (…)` aggregation over the raw metric is therefore meaningless.
- **The byte metric sits on the left of the `and`** so `$value` is the retained
  size, not the boolean from `active == 0`.

## References

- [`CNPGClusterPhysicalReplicationLagCritical`](CNPGClusterPhysicalReplicationLagCritical.md)
  and [`CNPGClusterPhysicalReplicationLagCritical`](CNPGClusterPhysicalReplicationLagCritical.md) — the symptom side
- [`CNPGWALArchiveFailing`](CNPGWALArchiveFailing.md) — the other way WAL piles up, and the disk-full misdirection
- [alert catalog](../../alerting/alert-catalog.md)

---
_Last updated: 2026-08-24 — written after a promotion during host saturation left `platform-db-3` diverged on timeline 1 and the primary retaining 2.4 GiB of WAL, growing ~250 MiB/h, with only the lag alert firing._
