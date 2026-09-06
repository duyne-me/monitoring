# CNPGClusterStandbyNotStreaming

| | |
|---|---|
| **Severity** | critical |
| **Source** | `prometheusrules/postgres/replication-health.yaml` (homelab-authored) |
| **Metrics** | `cnpg_pg_replication_in_recovery`, `cnpg_pg_replication_is_wal_receiver_up` |
| **Clusters** | `platform-db`, `product-db`, `product-db-replica` (DR) — all instances, no pod-name filter |
| **Grafana** | CloudNativePG Cluster Overview |

## Meaning

An instance is **in recovery but has no WAL receiver** for 5 minutes. It is a
standby that has stopped replicating: not slow, not lagging — disconnected.

This is deliberately independent of any lag measurement. A standby with no
receiver has nothing to measure lag against, and on an idle cluster the
time-based lag metric is unreliable anyway
([why](CNPGClusterPhysicalReplicationLagWarning.md#why-this-rule-counts-bytes)).

## Impact

Redundancy is gone for that instance, and it degrades from there:

- **The cluster is one failure closer to data loss.** A three-instance cluster
  with one dead standby is really a two-instance cluster.
- **The primary retains WAL for the dead slot.** Measured during the 2026-09-06
  incident: 1024 MB retained for a single inactive slot, and it only grows. On
  local-path volumes there is no PVC quota to stop it — it will consume the node
  filesystem.
- **On a DR cluster this means there is no disaster recovery**, silently. CNPG
  reports every instance `healthy` in cluster status while this is true.

## Diagnosis

```bash
NS=product; POD=product-db-3

# 1. Confirm: in recovery, no receiver
kubectl -n $NS exec $POD -c postgres -- psql -U postgres -tAc \
  "SELECT pg_is_in_recovery(), (SELECT count(*) FROM pg_stat_wal_receiver);"

# 2. How far behind, and on which timeline
kubectl -n $NS exec $POD -c postgres -- psql -U postgres -tAc \
  "SELECT timeline_id FROM pg_control_checkpoint();"
kubectl -n $NS exec ${NS}-db-1 -c postgres -- psql -U postgres -tAc \
  "SELECT timeline_id FROM pg_control_checkpoint();"

# 3. What the primary is holding for it
kubectl -n $NS exec ${NS}-db-1 -c postgres -- psql -U postgres -tAc \
  "SELECT slot_name, active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
   FROM pg_replication_slots;"

# 4. The reason, usually one line in the pod log
kubectl -n $NS logs $POD -c postgres --tail=200 | grep -i timeline
```

## Common causes

| Cause | Signal | Action |
|---|---|---|
| **Timeline divergence after a failover** | pod log: `Refusing to restore future timeline history file`; standby `timeline_id` lower than the primary's | The standby cannot follow the new timeline on its own. Rejoin it — `pg_rewind`, or let CNPG re-bootstrap by deleting the instance's PVC and pod |
| Network partition to the primary | receiver absent, no timeline mismatch | Check NetworkPolicy and the `-rw` Service endpoints |
| Primary refused the connection | primary log shows auth or `max_wal_senders` errors | Check `pg_hba` entries and `max_wal_senders` |
| Slot dropped while the standby was down | `pg_replication_slots` has no row for it | Re-bootstrap the instance |

## Resolution

1. Identify which of the causes above applies — the timeline check in step 2 of
   the diagnosis settles the common one immediately.
2. Rejoin the standby. Deleting its PVC and pod is the blunt, reliable route on
   this platform: CNPG re-bootstraps the instance from the primary, and the
   inactive slot is reclaimed with it. **This is destructive for that instance's
   local data only** — the primary is untouched — but confirm the cluster has at
   least one healthy standby before starting, or you are down to a single copy
   while it rebuilds.
3. Verify the slot goes `active = t` and its retained WAL falls back to near
   zero, and that this alert clears.

> Do **not** drop the inactive slot to reclaim WAL without also fixing or removing
> the standby. Dropping the slot lets the primary discard WAL the standby still
> needs, which turns a rejoinable replica into one that must be rebuilt.

## Related

- [`CNPGClusterPhysicalReplicationLagWarning`](CNPGClusterPhysicalReplicationLagWarning.md) / [`Critical`](CNPGClusterPhysicalReplicationLagCritical.md) — byte lag while still connected
- [`CNPGClusterHAWarning`](CNPGClusterHAWarning.md) — the streaming-replica count, which drops for the same reason
- [`docs/databases/disaster-recovery.md`](../../../databases/disaster-recovery.md)

---
_Last updated: 2026-09-06 — created after a live incident where a timeline-3 failover stranded `product-db-3` and the whole `product-db-replica` DR cluster on timeline 2, and no alert covered it._
