# EdgeUpstreamNoHealthyEndpoints

| | |
|---|---|
| **Severity** | critical |
| **Category** | availability |
| **Source** | [`envoy-gateway/alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/envoy-gateway/alerts.yaml) |
| **Metrics** | `envoy_cluster_membership_healthy` == 0 while `envoy_cluster_membership_total` > 0, per `envoy_cluster_name` |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08, not yet run in both forms) |
| **Dashboard** | Gateway → Envoy Clusters (membership row) |
| **Local-stack** | `job="envoy"` instead of `job="envoy-gateway"` |

## Meaning

For one upstream cluster, every endpoint Envoy knows about is out of rotation
for 2 minutes: ejected by the active health check or by passive outlier
detection that every `BackendTrafficPolicy` in `policies/btp-api.yaml`
configures. The cluster name is the route — `httproute/<namespace>/<name>/rule/<n>`.

This is the end state [EdgeUpstreamUnhealthy](EdgeUpstreamUnhealthy.md) warns
about. That rule fires at the first ejection; this one fires when there is
nobody left. The `membership_total > 0` arm excludes a Service with no
endpoints at all — that is a service not deployed, not a service ejected, and it
reads as 503/NC rather than 503/UH.

## Impact

Every request on that route gets a 503 from the edge with response flag `UH`
(no healthy upstream). Nothing reaches the backend, so the backend's own metrics
go quiet rather than red — the failure is visible only at the edge. If the route
is `checkout` or `cart`, shoppers cannot buy; if it is the SPA route, nobody can
load the storefront.

## Diagnosis

### PromQL

```promql
# The alert expr, then how many endpoints Envoy expects
sum by (envoy_cluster_name) (envoy_cluster_membership_healthy{job="envoy-gateway"}) == 0
  and sum by (envoy_cluster_name) (envoy_cluster_membership_total{job="envoy-gateway"}) > 0
sum by (envoy_cluster_name) (envoy_cluster_membership_total{job="envoy-gateway"})

# Active health check vs passive ejection — which mechanism took them out
rate(envoy_cluster_health_check_failure{job="envoy-gateway"}[5m])
envoy_cluster_outlier_detection_ejections_active{job="envoy-gateway"}

# The symptom clients see
edge_cluster:rq_5xx:rate5m
```

### kubectl / logs

```bash
# From envoy_cluster_name=httproute/<ns>/<route>/rule/<n>
NS=<ns>; ROUTE=<route>
kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{.spec.rules[*].backendRefs[*].name}'; echo
SVC=<backend service from the line above>
kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name="$SVC"
kubectl -n "$NS" get pods -l app.kubernetes.io/name="$SVC" -o wide
kubectl -n "$NS" logs -l app.kubernetes.io/name="$SVC" --tail=100
```

Two cases look identical in the metric. **Kubernetes agrees** (pods NotReady,
EndpointSlice empty of ready addresses): it is that service's incident and its
own alerts — `MicroserviceDown`, the CNPG rules, `KubePodCrashLooping` — say
why. **Kubernetes disagrees** (pods Ready, EndpointSlice populated): Envoy alone
took them out, which points at the health-check path answering non-2xx, at
timeouts or resets on the request path, or at a NetworkPolicy that lets the
kubelet probe in and the proxy not.

### Grafana

- **Gateway → Envoy Clusters** — healthy vs total per cluster, ejections,
  upstream latency; this alert is the membership panel reading zero.

## Mitigation

1. Pods NotReady: fix the service. The edge re-admits endpoints on its own once
   the health check passes; nothing to do at the gateway.
2. Pods Ready but ejected: confirm the health-check path in the route's
   `BackendTrafficPolicy` still exists on the service (a renamed `/healthz`
   after a service release ejects a perfectly healthy fleet). Check for a
   NetworkPolicy change that blocks `envoy-gateway` → service.
3. If the route must serve now and the backend is genuinely sick, a
   `kubectl rollout restart` of the backend clears passive ejection faster than
   waiting for the base ejection time to expire.
4. Do **not** remove `healthCheck` or `outlierDetection` from the policy to
   silence the alert. That turns a route that fails fast into a route that
   serves errors slowly.

## Escalation

Page — a route with zero healthy endpoints is down, whatever Kubernetes says.
If several clusters hit zero at once, the cause is shared: the health-check
NetworkPolicy, a node, or the controller pushing a bad cluster config (check
`EnvoyGatewayReconcileErrors`). Downgrade to the backend team's incident once
Kubernetes confirms the pods are the problem.

## Related

- [EdgeUpstreamUnhealthy](EdgeUpstreamUnhealthy.md) — the warning that precedes this.
- [Edge5xxRatio](Edge5xxRatio.md) — follows if the route carries enough traffic.
- [EdgeUpstreamTimeoutRatioHigh](EdgeUpstreamTimeoutRatioHigh.md) — a slow
  backend gets ejected by outlier detection; timeouts often come first.

```bash
git log --oneline -5 -- kubernetes/infra/configs/envoy-gateway/policies/
```

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `EnvoyClusterMembershipEmpty`, re-keyed on `envoy_cluster_name`)_
