# TemporalPersistenceErrorRateHigh

| | |
|---|---|
| **Severity** | warning |
| **Category** | workflow |
| **Source** | `kubernetes/infra/configs/temporal/prometheusrule.yaml` |
| **Metrics** | `persistence_error_with_type` (excluding `serviceerror_*NotFound`), `persistence_requests` — Temporal **server** metrics |
| **Status** | active |
| **Dashboard** | Temporal → Server · Temporal Web (`temporal.duynh.me`) |
| **Local-stack** | present — the compose stack runs Temporal on Postgres too |

## Meaning

```promql
sum(rate(persistence_error_with_type{error_type!~"serviceerror_.*NotFound"}[5m]))
  / clamp_min(sum(rate(persistence_requests[5m])), 1) > 0.02
```

More than 2% of Temporal's database operations are failing. `clamp_min(…, 1)`
keeps the ratio finite while idle rather than producing a divide-by-zero.

**Read this alert as "Temporal cannot talk to its database well", not "the
database is unhealthy".** Those are different, and on this platform the
difference has already bitten once.

## Impact

Escalates in a specific order, and knowing the order saves time:

1. Persistence calls slow down or fail.
2. History cannot acquire or renew its shards → `shard status unknown`.
3. Matching cannot register worker deployment versions.
4. Workers poll and are told `task queue is not ready to process polls from
   this deployment version`.
5. `WorkerDeployment` CRs never report a `currentVersion`, and `apps-local`
   fails its health check.

The visible failure is therefore four layers away from the cause, in Flux.

## Diagnosis

**Compare both ends of the same operation.** This is the step that matters:

```promql
# What Temporal thinks persistence costs
sum(rate(persistence_latency_sum[5m])) / sum(rate(persistence_latency_count[5m]))

# Break the errors down by operation
topk(10, sum by (operation, error_type) (rate(persistence_error_with_type[5m])))
# ^ deliberately UNFILTERED: run this one first. If the top rows are
#   serviceerror_NotFound on GetCurrentExecution or GetTaskQueueUserData, that is
#   Temporal control flow -- a lookup that legitimately missed -- and the alert
#   should not have fired. Those two types are excluded from the alert since
#   2026-09-06; anything else here is a real persistence problem.
```

```bash
# What Postgres thinks the same statements cost
kubectl exec -n platform platform-db-1 -c postgres -- psql -U postgres -P pager=off -c "
  SELECT calls, round(mean_exec_time::numeric,2) mean_ms, round(max_exec_time::numeric,1) max_ms,
         substring(regexp_replace(query,'\s+',' ','g'),1,60) q
  FROM pg_stat_statements s JOIN pg_database d ON d.oid=s.dbid
  WHERE d.datname LIKE 'temporal%' ORDER BY calls DESC LIMIT 8"
```

**A large gap between the two numbers means the time is not in the database.**
That has a specific meaning here: Temporal's own SQL connection pool. Measured
during the 2026-09-05 incident, `GetTimerTasks` read **17.97 s** on Temporal's
metric while Postgres executed the same statements at **0.41 ms** — a ~45,000×
discrepancy, with Postgres idle at 46 of 200 connections.

Check the pool directly:

```bash
kubectl exec -n temporal <history-pod> -- sh -c \
  'grep -E "maxConns|maxIdleConns" /etc/temporal/config/config_template.yaml'

# How many connections history actually holds
HIP=$(kubectl get pods -n temporal -l app.kubernetes.io/component=history -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n platform platform-db-1 -c postgres -- psql -U postgres -P pager=off -c "
  SELECT datname, state, count(*) FROM pg_stat_activity WHERE client_addr='$HIP' GROUP BY 1,2"
```

`numHistoryShards` is **512** and is immutable after first deployment. A shard is
the vendor's unit of *concurrent database operations*, so the pool has to be
sized against it — leaving `maxConns` unset means the server default, which was
measured holding four connections for all 512 shards.

Also check the other end — the database itself, so you can rule it out rather
than assume it:

```bash
kubectl get cluster -n platform platform-db
kubectl exec -n platform platform-db-1 -c postgres -- psql -U postgres -tAc \
  "SELECT 'backends='||count(*) FROM pg_stat_activity"
```

## Mitigation

1. **Postgres slow or unhealthy** → work the CNPG cluster; this alert is a
   symptom.
2. **Postgres fast and idle while Temporal reports seconds** → the pool. Size
   `maxConns` / `maxIdleConns` on both datastores in the Temporal HelmRelease.
   Note the config file is **shared** by frontend, history, matching and worker,
   so the ceiling is 4 services × 2 datastores × `maxConns` against
   `platform-db`'s usable connections.
3. Do not restart history to clear it. The errors are a rate, not a stuck state,
   and a restart drops the shard ownership you are trying to re-establish.

## Escalation

Warning, but escalate early if `shard status unknown` is appearing in history
logs — that is the point where the failure stops being about latency and starts
costing shard ownership.

```bash
kubectl logs -n temporal deploy/temporal-history --since=2m | grep -c 'shard status unknown'
```

## Related

- [TemporalServiceErrorRateHigh](TemporalServiceErrorRateHigh.md) — the RPC-layer
  view of the same trouble.
- [TemporalServerDown](TemporalServerDown.md)
- [TemporalWorkerRequestErrorRateHigh](TemporalWorkerRequestErrorRateHigh.md) —
  what the SDK sees when the server is struggling.

---
_Last updated: 2026-09-05 — created; the temporal alert group had no runbooks at all_
