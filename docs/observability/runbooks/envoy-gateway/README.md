# Envoy Gateway Edge Alert Runbooks

Per-alert investigation guides for the platform edge (ADR-044). Thirteen files
cover sixteen alerts: the paired High/Critical severities share one runbook,
because the investigation is identical and only the urgency differs.

| Quick facts | |
|---|---|
| Alert rules | [`prometheusrules/envoy-gateway/alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/envoy-gateway/alerts.yaml) |
| Recording rules | [`prometheusrules/envoy-gateway/recording-rules.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/envoy-gateway/recording-rules.yaml) |
| Data-plane scrape | [`podmonitors/envoy-gateway-proxy.yaml`](../../../../kubernetes/infra/configs/observability/metrics/podmonitors/envoy-gateway-proxy.yaml) — `job="envoy-gateway"` |
| Control-plane scrape | [`servicemonitors/envoy-gateway-controller.yaml`](../../../../kubernetes/infra/configs/observability/metrics/servicemonitors/envoy-gateway-controller.yaml) — `job="envoy-gateway-controller"` |
| Alert catalog | [§ Envoy Gateway edge](../../alerting/alert-catalog.md) |
| Edge architecture | [`platform/envoy-gateway.md`](../../../platform/envoy-gateway.md) |

## Two jobs, two failure stories

The split matters more here than anywhere else on the platform, because the
halves fail independently and only one of them is visible to users:

| Job | What it is | When it breaks |
|-----|------------|----------------|
| `envoy-gateway` | the proxy fleet — the request path | users feel it immediately |
| `envoy-gateway-controller` | the control plane — translates Gateway API into xDS | traffic is unaffected **until** a config change or a proxy restart |

An `envoy_*` series always comes from the data plane; `status_update_total`,
`xds_snapshot_*` and `watchable_*` always come from the control plane. Envoy's
latency histograms are in **milliseconds**, while application OTLP histograms
are in seconds — the single most common misreading of an edge dashboard.

## Runbooks

| Alert(s) | Runbook | The question it answers |
|----------|---------|------------------------|
| `EdgeDown` | [EdgeDown](EdgeDown.md) | Is the fleet down, or is the scrape blind? |
| `Edge5xxRatioHigh` · `Edge5xxRatioCritical` | [Edge5xxRatio](Edge5xxRatio.md) | Whose 5xx — a backend's, or Envoy's own? |
| `EdgeLatencyP95High` · `EdgeLatencyP95Critical` | [EdgeLatencyP95](EdgeLatencyP95.md) | Is the time spent in the edge or upstream? |
| `EdgeNoTraffic` | [EdgeNoTraffic](EdgeNoTraffic.md) | Healthy fleet, zero requests — which route stopped matching? |
| `Edge429RatioHigh` | [Edge429RatioHigh](Edge429RatioHigh.md) | Abusive client contained, or real users clipped? |
| `EdgeUpstreamUnhealthy` | [EdgeUpstreamUnhealthy](EdgeUpstreamUnhealthy.md) | Does Kubernetes agree the endpoints are unhealthy? |
| `EdgeUpstreamNoHealthyEndpoints` | [EdgeUpstreamNoHealthyEndpoints](EdgeUpstreamNoHealthyEndpoints.md) | Zero healthy — are the pods down, or did only Envoy give up on them? |
| `EdgeUpstreamTimeoutRatioHigh` | [EdgeUpstreamTimeoutRatioHigh](EdgeUpstreamTimeoutRatioHigh.md) | Is the backend slow, throttled, or waiting on its own dependency? |
| `EdgeCertExpiringSoon` · `EdgeCertExpired` | [EdgeCertExpiry](EdgeCertExpiry.md) | Did renewal fail, or did the renewed Secret never reach the proxies? |
| `EdgeJWKSFetchFailing` | [EdgeJWKSFetchFailing](EdgeJWKSFetchFailing.md) | How long until cached keys expire and everything 401s? |
| `EdgeAuthDeniedRatioHigh` | [EdgeAuthDeniedRatioHigh](EdgeAuthDeniedRatioHigh.md) | Mass 401s — expired keys, a broken realm, or an attack? |
| `EnvoyGatewayControllerDown` | [EnvoyGatewayControllerDown](EnvoyGatewayControllerDown.md) | What breaks next, given traffic is still fine? |
| `EnvoyGatewayReconcileErrors` | [EnvoyGatewayReconcileErrors](EnvoyGatewayReconcileErrors.md) | Which resource failed to reach the fleet? |

## Local-stack equivalents

Every PromQL query here also works against local-stack: vmagent scrapes the same
two jobs there (`envoy` for the proxy's `/stats/prometheus` on `:19005`,
`envoy-gateway` for the control plane on `:19001` — see
[`local-stack/observability/vmagent/prometheus.yml`](../../../../local-stack/observability/vmagent/prometheus.yml)),
and the same upstream dashboards are provisioned under the Grafana folder
`Gateway`. The **job names differ**: the cluster's data plane is
`job="envoy-gateway"` while local-stack's is `job="envoy"`, because in Host mode
the proxy's stats had to be published on a bootstrap-added listener rather than
the port a PodMonitor would select. Substitute accordingly when reproducing an
alert locally.

## Template

New runbooks follow the canonical [`../_TEMPLATE.md`](../_TEMPLATE.md) — one
template for every runbooks folder; the rows and dialect below are this
domain's additions.

## Domain specifics

- **Two scrape jobs, two planes:** `job="envoy-gateway"` is the data plane
  (proxy stats), `job="envoy-gateway-controller"` the control plane — a query
  against the wrong job silently returns nothing.
- **Histogram units trap:** `envoy_http_downstream_rq_time` buckets are
  **milliseconds**, unlike the seconds-based `http_request_duration_seconds`
  the services expose — never mix them in one panel or ratio.
- **Local-stack:** job names differ (see the section above) but every query
  ports once the job label is substituted.

---
_Last updated: 2026-09-08 — three runbooks added from the awesome-prometheus-alerts audit (`EdgeUpstreamNoHealthyEndpoints`, `EdgeUpstreamTimeoutRatioHigh`, the shared `EdgeCertExpiry`); 10 files / 12 alerts → 13 / 16. Previously 2026-08-19 — template pointer added (canonical template lives at the runbooks parent)_
