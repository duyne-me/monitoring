# EdgeUpstreamTimeoutRatioHigh

| | |
|---|---|
| **Severity** | warning |
| **Category** | latency |
| **Source** | [`envoy-gateway/alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/envoy-gateway/alerts.yaml) |
| **Metrics** | `envoy_cluster_upstream_rq_timeout` / `envoy_cluster_upstream_rq_completed`, per `envoy_cluster_name`, with a >0.05 req/s traffic guard |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; confirm the timeout counter exists per cluster at rest) |
| **Dashboard** | Gateway → Envoy Clusters (upstream latency P95 per cluster) |
| **Local-stack** | `job="envoy"` instead of `job="envoy-gateway"` |

## Meaning

More than 5% of upstream requests to one cluster hit the 15-second
`requestTimeout` every `BackendTrafficPolicy` in `policies/btp-api.yaml` sets,
sustained for 10 minutes, on a route carrying at least ~3 requests a minute.
The edge answers those with 504 and response flag `UT`.

The ratio is per route against that route's own traffic, which is what
[Edge5xxRatio](Edge5xxRatio.md) cannot give you: one slow service on a
low-traffic route never moves the platform-wide 5xx ratio. The checkout
CPU-limit incident had exactly that shape — a 50m limit throttled one service
past 15 s, that route served 504/UT, and the edge-wide ratio stayed under
threshold.

## Impact

Clients on that route wait 15 s and then get a 504. For the storefront this is
the worst failure mode: a spinner, then an error, on every attempt. Retries
configured in the same policy multiply the load on a backend that is already
too slow, so the condition tends to worsen rather than clear on its own.

## Diagnosis

### PromQL

```promql
# The alert expr
(
  sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_timeout{job="envoy-gateway"}[5m]))
  / sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_completed{job="envoy-gateway"}[5m]))
) > 0.05

# Is the backend slow, or is the edge waiting on something else?
edge_cluster:upstream_latency_ms:p95_5m{envoy_cluster_name="<cluster>"}
edge:latency_ms:p95_5m

# The usual cause on this platform: CPU throttling on the backend
# (kube_pod_* series need exported_namespace here, not namespace)
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{container!="",pod=~"<service>.*"}[5m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{container!="",pod=~"<service>.*"}[5m]))

# Is the backend's own p95 also high (seconds, not ms)?
histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{service_name="<service>"}[5m])))
```

If Envoy's per-cluster P95 is high **and** the service's own P95 is high, the
backend is slow. If Envoy's is high and the service's is normal, the time is
lost between them — connection setup, a saturated connection pool, or a pod
that accepts connections and never answers (check `envoy_cluster_upstream_cx_connect_fail`
and `upstream_rq_pending_overflow`).

### kubectl / logs

```bash
NS=<ns>; SVC=<service>
kubectl -n "$NS" top pods -l app.kubernetes.io/name="$SVC"
kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
# Access log lines with the UT flag name the route and the upstream host
kubectl -n envoy-gateway logs -l gateway.envoyproxy.io/owning-gateway-name=platform --tail=2000 \
  | grep '"response_flags":"UT"' | tail -20
```

### VictoriaLogs / traces

Edge access logs are ClickHouse-only (ADR-061): in Grafana's ClickHouse
datasource, filter `otel.otel_logs` on `response_flags = 'UT'` and group by
`upstream_cluster` and `upstream`. A trace for one timed-out request shows where
the 15 s went — the edge span ends at the timeout, the service span keeps going.

## Mitigation

1. Throttled backend: raise its CPU limit (the checkout fix was 50m → 500m).
   Peak latency under throttling scales roughly as `L / (1 - throttle_ratio)`,
   so a limit that looks generous on average still fails at peak.
2. Slow dependency (DB, Valkey, another service): follow that service's
   runbooks — `PgxPoolNearExhaustion`, the Valkey latency rules.
3. Do **not** raise `requestTimeout` to make the alert stop. Fifteen seconds
   is already past what the SPA waits for; a longer timeout hides the failure
   from this alert and shows it to shoppers instead.
4. If retries are amplifying load, temporarily set `retry.numRetries: 0` for
   that route's policy — reversible, and it lets the backend recover.

## Escalation

Ticket while the ratio hovers near 5% on one route. Page when it climbs past
50% (the route is effectively down) or when
[EdgeUpstreamNoHealthyEndpoints](EdgeUpstreamNoHealthyEndpoints.md) co-fires —
outlier detection is ejecting the slow endpoints and the route is about to have
none. What makes it worse: scaling the backend up while its dependency is the
bottleneck.

## Related

- [EdgeLatencyP95](EdgeLatencyP95.md) — edge-wide latency; this alert is the
  per-route version.
- [EdgeUpstreamUnhealthy](EdgeUpstreamUnhealthy.md) — slow endpoints get ejected.
- `KubePodCPUThrottlingHigh` (§5 of the catalog) — the cause, seen from kubelet.

```bash
git log --oneline -5 -- kubernetes/infra/configs/envoy-gateway/policies/btp-api.yaml
```

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `EnvoyHighClusterUpstreamRequestTimeoutRate`, plus the job filter, per-cluster key and traffic guard)_
