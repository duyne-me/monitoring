# ClickHouseKeeperSessionLost

| | |
|---|---|
| **Severity** | warning |
| **Category** | observability |
| **Source** | `.../prometheusrules/observability/clickhouse-alerts.yaml` |
| **Metrics** | `ClickHouseMetrics_ZooKeeperSession` < 1, `max by (replica)`, from `:9363` — the `job=` filter is load-bearing |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; expect 3 series at exactly 1) |
| **Dashboard** | ClickHouse → Server engine (Keeper row) |
| **Local-stack** | not present — no Keeper in the compose stack |

## Meaning

This replica has had **no live session** to the ClickHouse Keeper quorum for 2
minutes. `ZooKeeperSession` is a gauge: exactly 1 when healthy (ClickHouse's
own description says it "should be no more than one"), 0 while the session is
lost or being re-established.

It sits between two signals the group already had.
[ClickHouseZooKeeperExceptions](ClickHouseZooKeeperExceptions.md) is a rate and
goes quiet once the server stops retrying;
[ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) needs a table to
actually flip, which takes `session_timeout_ms` (30 s) of continuous loss — the
2026-08-28 keeper drills never produced it because sessions re-established in
time. This gauge drops the instant the connection is gone, so a Keeper pod
restart does exercise it, and its healthy value is checkable at rest.

## Impact

For the first 30 seconds, nothing. After `session_timeout_ms`, every
`ReplicatedMergeTree` table on this replica turns readonly: INSERTs routed here
fail (the collector retries elsewhere), it stops fetching parts and starts
lagging. Reads keep working, which is why nothing else notices. If all three
replicas lose their session — a quorum outage — the store is write-down.

## Diagnosis

```bash
PW=$(kubectl -n monitoring get secret clickhouse-credentials -o jsonpath='{.data.password}' | base64 -d)
CH="kubectl -n monitoring exec <replica pod from the alert> -- clickhouse-client --password=$PW -q"

# The replica's own view of its session
$CH "SELECT name, host, port, index, connected_time, session_uptime_elapsed_seconds, is_expired, keeper_api_version
     FROM system.zookeeper_connection"

# Is the quorum itself healthy? One leader, two synced followers
kubectl -n monitoring get pods -l clickhouse-keeper.altinity.com/chk=keeper -o wide
for p in $(kubectl -n monitoring get pods -l clickhouse-keeper.altinity.com/chk=keeper -o name); do
  echo "--- $p"; kubectl -n monitoring exec "$p" -- sh -c 'echo mntr | nc 127.0.0.1 2181' | grep -E 'zk_server_state|zk_synced_followers'
done

# Can this replica reach Keeper at all?
kubectl -n monitoring exec <replica pod> -- sh -c 'echo ruok | nc -w2 keeper-keeper 2181'
```

Three readings: **quorum healthy, this replica alone at 0** → a network path
or NetworkPolicy between this pod and the Keeper Service. **Quorum degraded or
leaderless** → [ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md) /
[ClickHouseKeeperQuorumDegraded](ClickHouseKeeperQuorumDegraded.md) own it; this
alert is the consequence. **All three replicas at 0 with a healthy quorum** →
the Keeper Service or its DNS, not Keeper.

### PromQL

```promql
max by (replica) (ClickHouseMetrics_ZooKeeperSession{job="clickhouse-server"})
count(ClickHouseAsyncMetrics_KeeperIsLeader == 1)                                # quorum side
max by (replica) (rate(ClickHouseProfileEvents_ZooKeeperHardwareExceptions{job="clickhouse-server"}[5m]))
```

The `job="clickhouse-server"` selector is not optional: `ClickHouseMetrics_*`
names overlap between the server (`:9363`) and Keeper (`:7000`) scrapes, and
Keeper's series carry no `replica` label.

## Mitigation

1. **Quorum problem**: fix Keeper first — the linked runbooks. The session
   re-establishes on its own within seconds of a leader existing.
2. **This pod only**: check `configs/network-policies/` for a recent change
   affecting `monitoring`; test port 2181 from the pod. Restarting the replica
   pod forces a fresh session and is safe — the other two keep serving.
3. **Session back but tables still readonly**: `SYSTEM RESTART REPLICA
   otel.<table>` on the affected pod, or restart the pod.
4. Do **not** delete Keeper PVCs to "reset" — they hold the raft log and the
   table metadata every replica registers against.

## Escalation

Ticket for one replica. Page if all three read 0 — that is a write outage on
the store — or if `ClickHouseKeeperNoLeader` co-fires. What not to do: scale
the CHK while the quorum is unhealthy; the `< 2` literal in
`ClickHouseKeeperQuorumDegraded` and the raft configuration both assume three.

## Related

- [ClickHouseKeeperNoLeader](ClickHouseKeeperNoLeader.md), [ClickHouseKeeperQuorumDegraded](ClickHouseKeeperQuorumDegraded.md) — the quorum's side.
- [ClickHouseZooKeeperExceptions](ClickHouseZooKeeperExceptions.md) — the rate that precedes this.
- [ClickHouseReadonlyReplica](ClickHouseReadonlyReplica.md) — what follows after 30 s.

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `ClickHouseZooKeeperConnectionIssues`; `for` 2m instead of 3m, job filter added)_
