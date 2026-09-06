# Grafana Dashboard Guide

> **Audience**: SRE/DevOps Engineers  
> **Dashboard**: Microservices Observability Platform  
> **Panels**: the board now has **8 rows (~41 panels)** since RFC-0017 W3/W4. The canonical JSON lives in the [`duynhlab/helm-charts`](https://github.com/duynhlab/helm-charts) repo (`charts/grafana-dashboards/dashboards/microservices/microservices-dashboard-otel.json`), delivered to the cluster as a chart ConfigMap consumed via `GrafanaDashboard.configMapRef` — the old `duynhlab/grafana-dashboards` repo is **deprecated**. The local-stack twin is `local-stack/observability/grafana/dashboards/microservices-otel-local.json`.  
> **Last Updated**: 2026-07-16 — chart-sourced canonical + RFC-0017 W3/W4 revision note

> **Board revision note (RFC-0017 W3/W4):** scrape-era dead panels **7, 8, 16, 17, 19, 22, 32, 33 were removed** (`up`, restarts, `process_cpu`, `go_memstats_*`, `requests_in_flight`, cAdvisor); panel 18 (network) moved into the runtime row; panel 12 widened; the two gRPC rows were re-laid as signal-paired 2-column lines; a **Database (client — otelpgx)** row was added. Sections below marked **🗑 REMOVED** are kept as historical context only.

---

## Table of Contents

1. [Overview](#overview)
2. [Row 1: Overview & Key Metrics](#row-1-overview--key-metrics) (10 panels)
3. [Row 2: Traffic & Requests](#row-2-traffic--requests) (4 panels)
4. [Row 3: Errors & Performance](#row-3-errors--performance) (7 panels)
5. [Row 4: Go Runtime & HTTP I/O](#row-4-go-runtime--memory) (5 panels)
6. [Row 5: Resources & Infrastructure — 🗑 REMOVED](#row-5-resources--infrastructure---removed-rfc-0017-w3) (historical)
7. [Rows 6–8: gRPC East-West + Database](#rows-68-grpc-east-west--database-client)
7. [Common Patterns](#common-patterns)
8. [Quick Reference](#quick-reference)

---

## Overview

### Dashboard Architecture

```mermaid
graph TD
    Dashboard[Microservices Dashboard: 8 rows]
    Row1[Row 1: Overview 10 Panels]
    Row2[Row 2: Traffic 4 Panels]
    Row3[Row 3: Errors 7 Panels]
    Row4[Row 4: Runtime + HTTP I/O 5 Panels]
    Row6[Rows 5-6: gRPC East-West RED 9 Panels]
    Row8[Row 7: Database client 6 Panels]
    
    Dashboard --> Row1
    Dashboard --> Row2
    Dashboard --> Row3
    Dashboard --> Row4
    Dashboard --> Row6
    Dashboard --> Row8
    
    Row1 --> Percentiles[P99/P95/P50]
    Row1 --> Traffic[RPS Metrics]
    Row1 --> Health[Apdex/Success Rate]
    
    Row2 --> StatusCodes[Status Code Distribution]
    Row2 --> Endpoints[Endpoint Traffic]
    
    Row3 --> Errors[4xx/5xx Panels]
    Row3 --> Performance[Response Time]
    
    Row4 --> Memory[Heap/RSS]
    Row4 --> GC[GC Metrics]
    
    Row6 --> GrpcRED[Server vs Client per signal]
    Row8 --> DBHealth[Query p95 / errors / pool]
```

### Dashboard Variables

| Variable | Type | Purpose | Example |
|----------|------|---------|---------|
| `$DS_PROMETHEUS` | Datasource | Prometheus instance selector | `Prometheus` |
| `$namespace` | Multi-select | Kubernetes namespace filter | `auth`, `user` |
| `$app` | Multi-select | Service name filter | `auth`, `product` |
| `$rate` | Single-select | Rate interval for calculations | `5m` (default) |

**Variable Cascading**: `$namespace` filters `$app` options dynamically.

### PromQL Patterns

**Core Functions Used**:
- `rate()` - Per-second rate for counters (industry standard)
- `increase()` - Total increase over time range
- `histogram_quantile()` - Percentile calculation from histogram buckets
- `sum() by (label)` - Aggregation with grouping

**Metric Labels**:
- `app` - Service name (from the OTLP `service.name` resource attribute; vmagent relabels `service_name` → `app`)
- `namespace` - Kubernetes namespace (from the OTLP `k8s.namespace.name` resource attribute; vmagent relabels `k8s_namespace_name` → `namespace`)
- `http_request_method` - HTTP method (GET, POST, PUT, DELETE) - semconv attribute from the app
- `http_route` - Matched route template (`/api/v1/users`) - semconv attribute from the app
- `http_response_status_code` - HTTP status code (200, 404, 500) - semconv attribute from the app

> **No `job` label on app series.** The 10 Go services + 2 workers **push OTLP** (SDK → otel-collector → vmagent OTLP ingest → VictoriaMetrics); there is no `/metrics` scrape and therefore no `job` label. A vmagent scrape (ServiceMonitor) still exists **only for infra exporters** (postgres/pg_exporter, kube-state-metrics, cAdvisor), not the app services.

---

## Row 1: Overview & Key Metrics

### Panel 1: 99th Percentile Response Success (ID: 1)

**Type**: stat | **Unit**: seconds | **Row**: Overview & Key Metrics

**Query**:
```promql
histogram_quantile(0.99, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", http_response_status_code=~"2.."}[$rate])) by (le))
```

**Query Explanation**:
- `histogram_quantile(0.99, ...)` - Calculate 99th percentile
- `rate(..._bucket{...}[$rate])` - Per-second rate of histogram buckets
- `http_response_status_code=~"2.."` - Only successful requests (200-299)
- `sum(...) by (le)` - Aggregate across services, preserve bucket boundaries
- **Result**: 99% of successful requests complete faster than this value

**Why This Metric**:
- Tail latency indicator - shows worst-case user experience
- Google SRE: "P99 matters more than average for user satisfaction"
- Detects outliers and system degradation early
- SLO target: P99 < 1s for user-facing APIs

**Thresholds**:
- Green: < 0.5s (excellent)
- Yellow: 0.5-1s (acceptable)
- Red: > 1s (investigate)

**What to Do When**:
- **P99 > 1s**: Check P50/P95 - if also high, systemic issue; if only P99 high, investigate outliers
- **Sudden spike**: Correlate with deployment, traffic surge, or dependency issues
- **Gradual increase**: Check for memory leaks, GC pressure, or database slow queries

**Related Panels**: P95 Response (Panel 2), P50 Response (Panel 3), Response Time per Endpoint (Panel 13-15)

---

### Panel 2: 95th Percentile Response Success (ID: 2)

**Type**: stat | **Unit**: seconds | **Row**: Overview & Key Metrics

**Query**:
```promql
histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", http_response_status_code=~"2.."}[$rate])) by (le))
```

**Query Explanation**:
- Same pattern as P99 but at 95th percentile
- 95% of requests complete faster than this
- **Key SLO metric** - commonly used in SLA agreements

**Why This Metric**:
- Balance between tail latency and typical experience
- Less sensitive to extreme outliers than P99
- Industry standard for SLO definitions
- SLO target: P95 < 500ms for interactive APIs

**Thresholds**:
- Green: < 0.3s (excellent)
- Yellow: 0.3-0.5s (acceptable)
- Red: > 0.5s (investigate)

**What to Do When**:
- **P95 increasing but P50 stable**: Investigate specific slow endpoints or database queries
- **P95 and P50 both increasing**: Systemic performance degradation
- **P95 > P99**: Data issue - check metric collection

**Best Practice**: Set SLOs on P95, not P99, for more stable targets.

---

### Panel 3: 50th Percentile Response Success (ID: 3)

**Type**: stat | **Unit**: seconds | **Row**: Overview & Key Metrics

**Query**:
```promql
histogram_quantile(0.5, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", http_response_status_code=~"2.."}[$rate])) by (le))
```

**Query Explanation**:
- Median response time - 50% of requests faster, 50% slower
- Represents **typical user experience**
- Less affected by outliers

**Why This Metric**:
- Baseline performance indicator
- Detects systemic slowdowns affecting all users
- Correlates with CPU/memory usage patterns

**Thresholds**:
- Green: < 0.2s (excellent)
- Yellow: 0.2-0.3s (acceptable)
- Red: > 0.3s (investigate)

**What to Do When**:
- **P50 increases**: Check CPU usage, memory pressure, GC frequency
- **P50 stable but P95/P99 high**: Investigate specific slow endpoints
- **P50 < 100ms**: Excellent performance, maintain current capacity

**SRE Insight**: If P50 and P95 are similar, performance is consistent. Large gap indicates variable latency.

---

### Panel 4: Total RPS (All Requests) (ID: 4)

**Type**: stat | **Unit**: reqps | **Row**: Overview & Key Metrics

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate]))
```

**Query Explanation**:
- `rate(..._count{...}[$rate])` - Per-second rate of total requests
- **No status code filter** - includes 2xx, 4xx, 5xx
- `sum()` - Aggregate across all selected services
- **Result**: Total traffic volume in requests/second

**Why This Metric**:
- Traffic monitoring (RED metrics: Rate, Errors, Duration)
- Capacity planning baseline
- Detect traffic anomalies (DDoS, legitimate spikes)

**Best Practices**:
- Use `rate()` not `increase()` for operational dashboards (Google SRE)
- Choose $rate interval: 5m default, 1m for real-time, 15m for trends
- Monitor relative changes, not absolute values

**What to Do When**:
- **Sudden drop to 0**: Service down - check pod status, ingress, DNS
- **Gradual decline**: User traffic drop or upstream service issues
- **Spike > 5x normal**: Investigate load source - legitimate vs attack
- **Correlation**: Compare with Success RPS (Panel 26) to identify error traffic

**Related Panels**: Success RPS (Panel 26), Error RPS (Panel 27)

---

### Panel 26: Success RPS (2xx) (ID: 26)

**Type**: stat | **Unit**: reqps | **Row**: Overview & Key Metrics

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"2.."}[$rate]))
```

**Query Explanation**:
- `http_response_status_code=~"2.."` - Regex filter for 200-299 status codes
- Measures **productive traffic** only
- **Golden Signal**: Success rate

**Why This Metric**:
- Distinguish between total traffic and successful traffic
- SLO calculation: Success rate = Success RPS / Total RPS
- Capacity planning based on productive load

**What to Do When**:
- **Success RPS drops but Total RPS stable**: Increasing error rate - check Panel 27/30
- **Success RPS drops with Total RPS**: Traffic decline
- **Success RPS < 95% of Total RPS**: High error rate - investigate immediately

---

### Panel 27: Error RPS (4xx/5xx) (ID: 27)

**Type**: stat | **Unit**: reqps | **Row**: Overview & Key Metrics

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"4..|5.."}[$rate]))
```

**Query Explanation**:
- `http_response_status_code=~"4..|5.."` - Regex for both 400-499 and 500-599
- **Combined error rate** across client and server errors
- Rapid indicator of service health

**Why This Metric**:
- Early warning system for service degradation
- SLO tracking: Error budget consumption
- Alerts should trigger on sustained error rate increases

**Thresholds**:
- Green: < 1% of Total RPS
- Yellow: 1-5% of Total RPS
- Red: > 5% of Total RPS

**What to Do When**:
- **Spike in errors**: Check Panel 201 (4xx) and 202 (5xx) to classify
- **4xx errors dominate**: Client-side issue - check API changes, auth
- **5xx errors dominate**: Server-side issue - check logs, pod restarts
- **Both high**: Widespread issue - page on-call

**Related Panels**: Client Errors (Panel 201), Server Errors (Panel 202), Error Rate % (Panel 30)

---

### Panel 28: Success Rate % (ID: 28)

**Type**: stat | **Unit**: percent | **Row**: Overview & Key Metrics

**Query**:
```promql
(sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"2.."}[$rate])) / sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate]))) * 100
```

**Query Explanation**:
- **Numerator**: Success RPS (2xx)
- **Denominator**: Total RPS (all codes)
- `* 100` - Convert to percentage
- **Result**: Percentage of successful requests

**Why This Metric**:
- SLO tracking: "99.9% of requests succeed"
- User-friendly percentage vs raw RPS
- Easier to set alerts and thresholds

**Thresholds**:
- Green: ≥ 99% (excellent)
- Yellow: 95-99% (acceptable)
- Red: < 95% (critical)

**What to Do When**:
- **< 99%**: Investigate error panels (201, 202) immediately
- **Trending down**: Check if new deployment or traffic pattern change
- **< 95%**: Page on-call - service severely degraded

**SLO Example**: "99.5% success rate over 30 days" = 0.5% error budget = ~216 minutes of errors/month

---

### Panel 30: Error Rate % (ID: 30)

**Type**: stat | **Unit**: percent | **Row**: Overview & Key Metrics

**Query**:
```promql
(sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"4..|5.."}[$rate])) / sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate]))) * 100
```

**Query Explanation**:
- Inverse of Success Rate %
- **Error budget consumption rate**
- Direct SLO metric

**Why This Metric**:
- Error budget tracking (SRE practice)
- Alert threshold: "Error rate > 1% for 5 minutes"
- Visualizes impact of incidents

**Thresholds**:
- Green: < 1% (within SLO)
- Yellow: 1-5% (burning error budget fast)
- Red: > 5% (emergency)

**What to Do When**:
- **> 1% sustained**: Error budget burn - investigate source
- **Spike then drop**: Transient issue - post-mortem after resolution
- **Sustained > 5%**: Emergency response - all hands on deck

**Error Budget Math**:
- 99.9% SLO = 0.1% error budget = 43 minutes/month
- Current error rate 5% = burning budget 50x faster
- Time to exhaustion = 43 min / 50 = ~52 minutes

---

### Panel 6: Apdex Score (ID: 6) ⚠️ UPDATED

**Type**: stat | **Unit**: percentunit (0-1) | **Row**: Overview & Key Metrics

**Query**:
```promql
(sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", le="0.5"}[$rate])) + 0.5 * (sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", le="2"}[$rate])) - sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace", le="0.5"}[$rate])))) / (sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) > 0 or vector(1))
```

**Query Explanation**:
- **Satisfying**: Requests < 0.5s (T threshold)
- **Tolerating**: Requests 0.5-2s (4T threshold)
- **Frustrated**: Requests > 2s
- **Formula**: `(satisfying + 0.5 * tolerating) / total`
- **Defensive division**: `(... > 0 or vector(1))` prevents NaN on zero traffic
- **Result**: Score 0.0-1.0 representing user satisfaction

**Why This Metric**:
- Single metric combining latency and success rate
- Industry standard (Apdex Alliance specification)
- User-centric: models actual user satisfaction
- SLO-friendly: Apdex > 0.9 = excellent UX

**Thresholds**:
- Green: ≥ 0.7 (acceptable)
- Yellow: 0.5-0.7 (poor)
- Red: < 0.5 (unacceptable)

**What to Do When**:
- **Apdex drops but P50 stable**: Increase in slow outliers - check P95/P99
- **Apdex drops with P50**: Systemic slowdown - check CPU/memory/GC
- **Apdex = 0.0 on zero traffic**: Expected behavior (defensive handling)
- **Apdex < 0.5**: User experience severely degraded - immediate action

**BEFORE/AFTER Fix**:
- **BEFORE**: `/ 2)` caused division issues, no zero-traffic handling → NaN values
- **AFTER**: `* 0.5` cleaner syntax, defensive division → Returns 0.0 on zero traffic

**Best Practice**: Set Apdex T threshold based on user research. 0.5s is standard for interactive web apps.

---

### Panel 5: Total Requests (ID: 5)

**Type**: stat | **Unit**: short (count) | **Row**: Overview & Key Metrics

**Query**:
```promql
sum(increase(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$__range]))
```

**Query Explanation**:
- `increase(...[$__range])` - Total increase over dashboard time range
- `$__range` - Grafana variable: selected time range (5m, 1h, 24h, etc.)
- **Result**: Total request count in selected time window

**Why This Metric**:
- Historical analysis: "How many requests during the incident?"
- Capacity planning: Daily/weekly request patterns
- Correlation with business metrics (orders, signups)

**What to Do When**:
- **Correlate with incidents**: Total requests during outage window
- **Trend analysis**: Compare week-over-week growth
- **Capacity planning**: Forecast future load based on growth rate

**Note**: Use `increase()` for totals, `rate()` for per-second rates.

---

### Panel 7: Up Instances (ID: 7) 🗑 REMOVED (RFC-0017 W3)

**Type**: stat | **Unit**: short (count) | **Row**: Overview & Key Metrics

**Query**:
```promql
count(count by (app, namespace, k8s_pod_name)(go_goroutine_count{app=~"$app", namespace=~"$namespace"}))
```

**Query Explanation**:
- The 10 Go services + 2 workers push OTLP, so there is **no `up` series** for them — nothing scrapes a `/metrics` endpoint. Instead, count the pods currently emitting a heartbeat metric: every live pod reports `go_goroutine_count`.
- `count by (app, namespace, k8s_pod_name)(...)` - one entry per reporting pod
- outer `count(...)` - Number of pods currently pushing metrics
- **Result**: Running pods for the selected services

**Why This Metric**:
- Availability monitoring
- Scaling verification: "Did HPA create new pods?"
- Incident detection: Sudden drop = mass pod failures

**Liveness / down detection (D-4 heartbeat-absence)**:
With no `up` series, a downed pod is detected by the *absence* of its heartbeat rather than `up == 0`:
```promql
count by (app, namespace, k8s_pod_name)(last_over_time(go_goroutine_count{app!=""}[15m]))
  unless
count by (app, namespace, k8s_pod_name)(go_goroutine_count{app!=""})
```
Detection lags a pod kill by ~5m (VictoriaMetrics staleness) — accepted in RFC-0014 D-4.

**What to Do When**:
- **Sudden drop**: Check pod status, node health, resource limits
- **Gradual decrease**: Pods crashing - check logs, restarts (Panel 8)
- **Zero instances**: Service completely down - emergency

**Related Panels**: Restarts (Panel 8)

---

### Panel 8: Restarts (ID: 8) 🗑 REMOVED (RFC-0017 W3)

**Type**: stat | **Unit**: short (count) | **Row**: Overview & Key Metrics

**Query**:
```promql
sum(kube_pod_container_status_restarts_total{namespace=~"$namespace", pod=~"^$app-[a-z0-9]+-[a-z0-9]+$"})
```

**Query Explanation**:
- `kube_pod_container_status_restarts_total` - Kubernetes metric from kube-state-metrics
- Regex filter: `pod=~"^$app-..."` matches pod naming pattern
- **Result**: Total restarts for selected service pods

**Why This Metric**:
- OOM detection: Frequent restarts = memory limits too low
- Crash loop detection: Startup issues or missing dependencies
- Stability indicator: 0 restarts = stable deployment

**Thresholds**:
- Green: 0 restarts (stable)
- Yellow: 1-5 restarts (investigate)
- Red: > 5 restarts (critical issue)

**What to Do When**:
- **Frequent restarts**: Check pod logs, memory limits, liveness probes
- **OOM kills**: Increase memory limits or fix memory leaks (Panel 31-33)
- **Crash loops**: Check application startup logs, config issues
- **Restarts after deployment**: Expected - verify gradual rollout

**Investigation Commands**:
```bash
kubectl describe pod <pod-name> -n <namespace>  # Check restart reason
kubectl logs <pod-name> -n <namespace> --previous  # Check crashed container logs
```

---

## Row 2: Traffic & Requests

### Panel 9: Status Code Distribution (ID: 9) ⚠️ UPDATED

**Type**: piechart | **Unit**: (percentage) | **Row**: Traffic & Requests

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) by (http_response_status_code)
```

**Query Explanation**:
- `rate(..._count{...}[$rate])` - Per-second rate over time window
- `sum(...) by (http_response_status_code)` - Group by HTTP status code
- **Pie chart automatically converts to percentages**
- **Result**: Real-time traffic distribution by status code (req/sec)

**Why This Metric**:
- Quick health check: Expected ~95% code 2xx
- Pattern detection: Abnormal code distribution indicates issues
- Client vs server errors at a glance

**BEFORE/AFTER Fix**:
- **BEFORE**: `sum(http_server_request_duration_seconds_count{...}) by (http_response_status_code)` (cumulative counter)
  - **Problem**: Ever-increasing totals since pod start
  - **Result**: Misleading percentages based on historical data
- **AFTER**: `sum(rate(..._count{...}[$rate])) by (http_response_status_code)` (rate-based)
  - **Benefit**: Shows current traffic distribution (req/sec)
  - **Industry Standard**: Google SRE, Prometheus best practices

**Expected Distribution**:
- **Healthy**: 95%+ code 2xx, <5% code 4xx/5xx
- **Warning**: 90-95% code 2xx, 5-10% errors
- **Critical**: <90% code 2xx, >10% errors

**What to Do When**:
- **High 4xx %**: Check Panel 201 (Client Errors) - API misuse, auth issues
- **High 5xx %**: Check Panel 202 (Server Errors) - service bugs, infrastructure
- **High 3xx %**: Redirect loops or misconfigured routing
- **No 2xx codes**: Service completely failing - emergency

**Related Panels**: Client Errors 4xx (Panel 201), Server Errors 5xx (Panel 202)

---

### Panel 10: Total Requests by Endpoint (ID: 10)

**Type**: piechart | **Unit**: (percentage) | **Row**: Traffic & Requests

**Query**:
```promql
sum(increase(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$__range])) by (http_route)
```

**Query Explanation**:
- `increase(...[$__range])` - Total requests over dashboard time range
- `sum(...) by (http_route)` - Group by endpoint path
- **Result**: Total requests per endpoint (historical)

**Why This Metric**:
- Identify hot paths: Which endpoints receive most traffic?
- Capacity planning: Focus optimization on high-traffic endpoints
- API usage patterns: Understand client behavior

**What to Do When**:
- **Single endpoint dominates**: Optimize that endpoint first
- **Unexpected endpoint high traffic**: Investigate if legitimate or bot traffic
- **New endpoint suddenly popular**: Monitor for scaling needs

**Use Case**: "Our /api/v1/search endpoint handles 60% of traffic - prioritize its optimization."

---

### Panel 23: Request Rate by Endpoint (ID: 23)

**Type**: timeseries | **Unit**: reqps | **Row**: Traffic & Requests

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) by (http_route)
```

**Query Explanation**:
- Same as Panel 10 but with `rate()` instead of `increase()`
- **Timeseries visualization** shows trends over time
- **Result**: Real-time req/sec per endpoint

**Why This Metric**:
- Detect endpoint-specific traffic spikes
- Identify traffic pattern changes over time
- Correlate with deployments or incidents

**What to Do When**:
- **Sudden spike in one endpoint**: Investigate cause - legitimate traffic or abuse
- **Gradual increase**: Plan for capacity scaling
- **Flat line on critical endpoint**: Possible upstream service issue

**Difference vs Panel 10**: Panel 10 = historical total, Panel 23 = real-time rate

---

### Panel 12: RPS by Endpoint (ID: 12)

**Type**: timeseries | **Unit**: reqps | **Row**: Traffic & Requests

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) by (http_route)
```

**Note**: Same query as Panel 23 - likely duplicate or different visualization settings.

---

## Row 3: Errors & Performance

### Panel 24: Request Rate by Method and Endpoint (ID: 24)

**Type**: timeseries | **Unit**: reqps | **Row**: Errors & Performance

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) by (http_request_method, http_route)
```

**Query Explanation**:
- `sum(...) by (http_request_method, http_route)` - Group by **both** HTTP method and endpoint
- **Result**: Breakdown showing GET /api/v1/users, POST /api/v1/users separately

**Why This Metric**:
- Method-specific issues: "POST endpoints slow but GET fast"
- Granular traffic analysis
- Detect unusual patterns (e.g., unexpected DELETE traffic)

**What to Do When**:
- **POST/PUT high traffic**: Write-heavy load - check database write capacity
- **DELETE spike**: Investigate if legitimate cleanup or malicious
- **GET traffic drops**: Cache layer issue or upstream problem

---

### Panel 25: Error Rate by Method and Endpoint (ID: 25)

**Type**: timeseries | **Unit**: percent | **Row**: Errors & Performance

**Query**:
```promql
(sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"4..|5.."}[$rate])) by (http_request_method, http_route) / sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace"}[$rate])) by (http_request_method, http_route)) * 100 > 0
```

**Query Explanation**:
- **Numerator**: Error rate (4xx + 5xx) per method+path
- **Denominator**: Total rate per method+path
- `* 100` - Convert to percentage
- `> 0` - **Filter: only show endpoints with errors** (reduces noise)

**Why This Metric**:
- Pinpoint exact failing endpoints
- Avoid alert fatigue: only see problematic combinations
- Root cause analysis: "Only POST /api/v1/orders failing"

**Thresholds**:
- Yellow: > 1% error rate
- Red: > 5% error rate

**What to Do When**:
- **Single endpoint high error rate**: Check that endpoint's code, database queries, dependencies
- **All POST endpoints failing**: Database write issue or validation problem
- **All endpoints for one method**: Method-specific middleware or auth issue

**Best Practice**: This panel is your first stop when investigating errors - it shows exactly where the problem is.

---

### Panel 201: Client Errors (4xx) (ID: 201) ✨ NEW

**Type**: timeseries | **Unit**: reqps | **Row**: Errors & Performance

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"4.."}[$rate])) by (app)
```

**Query Explanation**:
- `http_response_status_code=~"4.."` - Regex matches 400-499 status codes
- `sum(...) by (app)` - Show 4xx rate per service
- **Result**: Client-side error rate in req/sec by service

**Why This Metric**:
- Separate client errors from server errors (different root causes)
- Client errors don't always indicate service problems
- Track API misuse and client issues

**Common 4xx Codes**:
- **400 Bad Request**: Invalid input, malformed JSON
- **401 Unauthorized**: Missing or invalid auth token
- **403 Forbidden**: Valid auth but insufficient permissions
- **404 Not Found**: Resource doesn't exist, wrong endpoint
- **429 Too Many Requests**: Rate limit exceeded

**Thresholds**:
- Green: < 0.5 req/s (normal)
- Yellow: 0.5-1 req/s (elevated)
- Orange: 1-5 req/s (high)

**What to Do When**:
- **High 400 errors**: API contract changed? Check recent client updates
- **High 401/403 errors**: Auth service issue or token expiration problems
- **High 404 errors**: Clients using wrong endpoints or broken links
- **High 429 errors**: Legitimate traffic surge or need to increase rate limits
- **Sudden spike**: New client deployment with bugs or DDoS attempt

**Investigation**:
1. Check which specific 4xx codes (use Prometheus query)
2. Check affected endpoints (Panel 25)
3. Review recent API changes or client deployments
4. Validate request samples in logs

**Note**: 4xx errors consume error budget in some SLOs, review your SLO definition.

---

### Panel 202: Server Errors (5xx) (ID: 202) ✨ NEW

**Type**: timeseries | **Unit**: reqps | **Row**: Errors & Performance

**Query**:
```promql
sum(rate(http_server_request_duration_seconds_count{app=~"$app", namespace=~"$namespace", http_response_status_code=~"5.."}[$rate])) by (app)
```

**Query Explanation**:
- `http_response_status_code=~"5.."` - Regex matches 500-599 status codes
- **Result**: Server-side error rate in req/sec by service
- **Critical metric**: 5xx = service problems, not client issues

**Why This Metric**:
- Direct indicator of service health
- Always counts against SLO/error budget
- Requires immediate investigation

**Common 5xx Codes**:
- **500 Internal Server Error**: Unhandled exception, application bug
- **502 Bad Gateway**: Upstream service unreachable, proxy issue
- **503 Service Unavailable**: Service overloaded, circuit breaker open
- **504 Gateway Timeout**: Upstream service too slow, timeout exceeded

**Thresholds**:
- Green: 0 req/s (perfect)
- Orange: 0.1-0.5 req/s (concerning)
- Red: > 0.5 req/s (critical)

**What to Do When**:
- **Any 5xx errors**: Immediate investigation required
- **High 500 errors**: Application bugs - check logs, recent deployments
- **High 502/504 errors**: Dependency issues - check upstream services
- **High 503 errors**: Service overloaded - check CPU, memory, and latency saturation (in-flight retired; see Panel 19)
- **Spike after deployment**: Rollback immediately, investigate bug
- **Gradual increase**: Resource exhaustion - check memory leaks (Panel 31-33)

**Emergency Response**:
1. Page on-call engineer
2. Check service logs for stack traces
3. Check Pod restarts (Panel 8) - OOM kills?
4. Verify dependencies are healthy
5. Consider rollback if recent deployment
6. Increase monitoring granularity

**SLO Impact**: 5xx errors always consume error budget. Even 0.1% can violate 99.9% SLO.

---

### Panel 13: Response time 95th percentile (ID: 13)

**Type**: timeseries | **Unit**: seconds | **Row**: Errors & Performance

**Query**:
```promql
histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace"}[$rate])) by (le, http_route, http_response_status_code))
```

**Query Explanation**:
- `histogram_quantile(0.95, ...)` - Calculate P95 per group
- `sum(...) by (le, http_route, http_response_status_code)` - **Per endpoint and status code**
- **Result**: P95 latency for each endpoint+code combination

**Legend Format**: `{{http_response_status_code}} {{http_route}}`
- Shows HTTP status code and endpoint path in single column
- Example: `404 /api/v1/shipping/estimate`
- **Note**: Grafana timeseries panels do not support splitting legend labels into separate columns. The code and path must remain in a single Name column.

**Why This Metric**:
- Identify which specific endpoints are slow
- Separate successful vs failed request latency
- Prioritize optimization efforts

**What to Do When**:
- **One endpoint much slower**: Optimize that endpoint (N+1 queries, inefficient logic)
- **5xx responses slow**: Slow failures - check timeout settings
- **All endpoints slow**: Systemic issue - check Panel 1-3, CPU, memory, GC

---

### Panel 14: Response time 50th percentile (ID: 14)

**Type**: timeseries | **Unit**: seconds | **Row**: Errors & Performance

**Query**:
```promql
histogram_quantile(0.50, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace"}[$rate])) by (le, http_route, http_response_status_code))
```

**Query Explanation**:
- Median latency per endpoint and status code
- Shows typical performance per endpoint

**Legend Format**: `{{http_response_status_code}} {{http_route}}`
- Example: `200 /api/v1/users`

**Use Case**: Compare with Panel 13 to understand latency distribution per endpoint.

---

### Panel 15: Response time 99th percentile (ID: 15)

**Type**: timeseries | **Unit**: seconds | **Row**: Errors & Performance

**Query**:
```promql
histogram_quantile(0.99, sum(rate(http_server_request_duration_seconds_bucket{app=~"$app", namespace=~"$namespace"}[$rate])) by (le, http_route, http_response_status_code))
```

**Query Explanation**:
- Tail latency per endpoint
- Highlights endpoints with worst outliers

**Legend Format**: `{{http_response_status_code}} {{http_route}}`
- Example: `201 /api/v1/cart`

**Use Case**: Identify which endpoints have variable latency or occasional slowness.

---

## Row 4: Go Runtime & Memory

> Row title on the board is now **🔧 Go Runtime & HTTP I/O (OTel)** — panels 31 (Memory In-Use), 20, 21 (Goroutines), 34, and 18 (network, moved here). Panels 32/33 below are removed.

### Panel 31: Heap Used Memory (ID: 31) ⚠️ UPDATED

**Type**: timeseries | **Unit**: bytes | **Row**: Go Runtime & Memory

**Status**: The client_golang `go_memstats_alloc_bytes` gauge was **retired at the P3 cutover** (no `/metrics` scrape on the OTLP path). The OTel Go runtime instrumentation reports **used memory by type**, not the client_golang heap gauges.

**Query**:
```promql
sum(go_memory_used_bytes{app=~"$app", namespace=~"$namespace"}) by (app)
```

**Query Explanation**:
- `go_memory_used_bytes` - live memory in use (OTel Go runtime metric; carries `go_memory_type=stack|other`)
- `sum(...) by (app)` - total across memory types and pods per service
- **Result**: Used memory per service (split by `go_memory_type` if you need stack vs other)

**Why This Metric**:
- Memory leak detection
- Correlation with GC pressure
- Capacity planning

**Memory Leak Pattern**:
- **Sawtooth normal**: Allocate → GC → Drop → Repeat
- **Staircase leak**: Each cycle doesn't drop to baseline → grows over time
- **Ramp leak**: Continuous growth without GC drops

**What to Do When**:
- **Steady growth without drops**: Memory leak - profile with pprof
- **Growth correlates with traffic**: Normal - check if proportional
- **Sudden jumps**: Large allocations - check recent code changes

---

### Panel 32: Used Memory by Type (ID: 32) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: bytes | **Row**: Go Runtime & Memory

**Status**: The client_golang `go_memstats_heap_inuse_bytes` gauge was **retired at the P3 cutover**. OTel reports used memory by type (`go_memory_type=stack|other`), so the heap-span breakdown is replaced with a per-type split of `go_memory_used_bytes`.

**Query**:
```promql
sum(go_memory_used_bytes{app=~"$app", namespace=~"$namespace"}) by (app, go_memory_type)
```

**Query Explanation**:
- `go_memory_type=stack` - goroutine stacks; `go_memory_type=other` - everything else the runtime tracks
- `sum(...) by (app, go_memory_type)` - one series per service per memory type
- **Difference vs Panel 31**: Panel 31 is the total used, this splits it by type

**What to Do When**:
- **`other` growing steadily**: Heap growth / possible leak - profile with pprof
- **`stack` growing**: Goroutine growth - cross-check Panel 21

---

### Panel 33: Container Working-Set Memory (ID: 33) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: bytes | **Row**: Go Runtime & Memory

**Status**: The client_golang `process_resident_memory_bytes` (RSS) gauge was **retired at the P3 cutover** — there is no process-level RSS metric on the OTLP path. Container working-set from cAdvisor is used instead; it is limits-aware and is the **same source the `MicroserviceGCThrash` / memory alerts read**.

**Query**:
```promql
sum(container_memory_working_set_bytes{namespace=~"$namespace", pod=~"^$app-[a-z0-9]+-[a-z0-9]+$", container!=""}) by (pod)
```

**Query Explanation**:
- `container_memory_working_set_bytes` - **cAdvisor metric**: memory the kernel cannot evict (what the OOM killer watches)
- cAdvisor series carry `pod`/`namespace`/`container` labels (not `app`), so match on `namespace` + a pod regex and `container!=""` to drop the pause container
- **Result**: Working-set memory per pod

**Why This Metric**:
- Detect OOM kills: working-set approaching the memory limit = danger
- Off-heap growth: working-set grows while Go used memory (Panel 31) stays flat

**What to Do When**:
- **Working-set approaching pod memory limit**: Risk of OOM kill - increase limits
- **Working-set >> Go used memory**: Off-heap allocations (CGo, file mappings) - investigate
- **Working-set stable but Go used memory growing**: Normal Go memory retention

---

### Panel 21: Goroutines (ID: 21) ⚠️ UPDATED

**Type**: timeseries | **Unit**: short (count) | **Row**: Go Runtime & Memory

**Status**: The `go_threads` (OS thread count) series is **removed / not emitted** — the OTel Go runtime set has no thread-count equivalent (same class as the retired `requests_in_flight`). The goroutine gauge remains as `go_goroutine_count`.

**Query**:
```promql
sum(go_goroutine_count{app=~"$app", namespace=~"$namespace"}) by (app)
```

**Query Explanation**:
- `go_goroutine_count` - Active goroutines (OTel Go runtime metric)

**Why This Metric**:
- **Goroutine leak detection** - common Go bug
- Steadily growing goroutines with flat traffic = goroutine leak

**Goroutine Leak Causes**:
- Forgotten `defer cancel()` in contexts
- Channels not closed
- Infinite loops without exit conditions
- HTTP clients not closing connections

**What to Do When**:
- **Goroutines steadily increasing**: Goroutine leak - capture goroutine profile
- **Thousands of goroutines**: Check for leaks with `go tool pprof`

**Investigation**:
```bash
curl http://<service>:8080/debug/pprof/goroutine?debug=2  # Goroutine stack traces
go tool pprof http://<service>:8080/debug/pprof/goroutine  # Interactive profiling
```

---

### Panel 20: GC Pressure (GC-thrash) (ID: 20) ⚠️ UPDATED

**Type**: timeseries | **Unit**: percentunit | **Row**: Go Runtime & Memory

**Status**: The Prometheus `go_gc_duration_seconds_*` pause summary is **no longer emitted** — the OTel Go runtime instrumentation has **no GC pause metric**. GC health is now tracked as *GC-thrash*: how close live heap sits to the GC goal. When used memory rides within ~5% of the goal, the collector runs back-to-back.

**Query**:
```promql
go_memory_used_bytes{app=~"$app", namespace=~"$namespace"}
  / go_memory_gc_goal_bytes{app=~"$app", namespace=~"$namespace"}
```

**Query Explanation**:
- `go_memory_used_bytes` - live heap in use (OTel Go runtime metric)
- `go_memory_gc_goal_bytes` - heap size that triggers the next GC
- **Result**: a ratio persistently near 1.0 (within 5%) indicates GC-thrash and fires the `MicroserviceGCThrash` alert

**Why This Metric**:
- Detects sustained GC pressure without a pause-time metric
- Memory pressure indicator
- Latency impact: back-to-back GC steals CPU from request handling

**What to Do When**:
- **Ratio near 1.0 sustained**: GC-thrash - reduce allocations or raise the memory limit / GOGC
- **Correlates with P95/P99 spikes**: GC stealing CPU - tune GOGC or scale out
- **Ratio low and stable**: Healthy headroom

**Go GC Tuning**:
- `GOGC=100` (default) - GC when heap doubles
- `GOGC=200` - Less frequent GC, more memory usage
- `GOGC=50` - More frequent GC, less memory usage

---

### Panel 34: GC Goal Headroom (ID: 34) ⚠️ UPDATED

**Type**: timeseries | **Unit**: bytes | **Row**: Go Runtime & Memory

**Status**: The `go_gc_duration_seconds_count` cycle counter is **no longer emitted** (no OTel equivalent), so GC *frequency* is no longer chartable. Instead, plot live heap against the GC goal to see the headroom behind Panel 20's GC-thrash ratio.

**Query**:
```promql
go_memory_used_bytes{app=~"$app", namespace=~"$namespace"}
go_memory_gc_goal_bytes{app=~"$app", namespace=~"$namespace"}
```

**Query Explanation**:
- `go_memory_used_bytes` - live heap in use
- `go_memory_gc_goal_bytes` - heap size that triggers the next GC
- **Result**: two series whose converging gap signals rising GC pressure

**Why This Metric**:
- Shrinking gap between used and goal = rising GC pressure (feeds Panel 20)
- Complements the GC-thrash ratio with absolute byte context

**What to Do When**:
- **Used approaching goal**: Reduce allocations (use sync.Pool, reuse buffers) or raise the limit
- **Goal much larger than used**: Healthy headroom
- **Gap collapsing under traffic**: Allocation pressure - profile hot paths

---

## Row 5: Resources & Infrastructure — 🗑 REMOVED (RFC-0017 W3)

> This row **no longer exists on the board**: panels 16/17/19/22/33 queried scrape-era or cluster-only metrics that the OTLP pipeline never emits, and panel 18 moved into the runtime row. Kept for historical context.

### Panel 16: Total Memory per Service (ID: 16) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: bytes | **Row**: Resources & Infrastructure

**Status**: The client_golang `go_memstats_alloc_bytes` gauge was **retired at the P3 cutover**. OTel reports used memory by type, so this aggregates `go_memory_used_bytes`.

**Query**:
```promql
sum(go_memory_used_bytes{app=~"$app", namespace=~"$namespace"}) by (app)
```

**Query Explanation**:
- `sum(...) by (app)` - **Aggregate across ALL pods and memory types in the service**
- Example: auth with 3 pods = sum of all 3 pods' used memory

**Why This Metric**:
- **Capacity planning**: Total memory footprint per service
- **Cost analysis**: Memory costs across entire service fleet
- **Scaling decisions**: "Add more pods or increase pod memory?"

**What to Do When**:
- **High total memory**: Consider horizontal scaling (more pods)
- **Memory per pod high**: Consider vertical scaling (bigger pods)
- **Total growing**: Plan for capacity expansion

---

### Panel 17: Total CPU per Service (ID: 17) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: percent | **Row**: Resources & Infrastructure

**Status**: The client_golang `process_cpu_seconds_total` counter was **retired at the P3 cutover** — no process-level CPU metric on the OTLP path. Container CPU usage from cAdvisor is used instead.

**Query**:
```promql
sum(rate(container_cpu_usage_seconds_total{namespace=~"$namespace", pod=~"^$app-[a-z0-9]+-[a-z0-9]+$", container!=""}[5m])) by (namespace) * 100
```

**Query Explanation**:
- `container_cpu_usage_seconds_total` - **cAdvisor counter**: cumulative CPU seconds per container
- `rate(...) * 100` - CPU usage as percentage (100% = 1 core)
- cAdvisor carries `pod`/`namespace`/`container` (not `app`); each service runs in its own namespace, so `by (namespace)` is the per-service total across pods

**Why This Metric**:
- Service-level CPU consumption
- Horizontal scaling trigger: "Total CPU > 200% = need more pods"
- Cost optimization: Identify CPU-hungry services

**What to Do When**:
- **Total CPU high but per-pod normal**: Add more pods (horizontal scaling)
- **Total CPU low but response time high**: Not CPU-bound - check I/O, database
- **Sudden CPU spike**: Check for code inefficiency or traffic spike

---

### Panel 18: Total Network Traffic per Service (ID: 18)

**Type**: timeseries | **Unit**: Bps (bytes/sec) | **Row**: Resources & Infrastructure

**Query**:
```promql
sum(rate(http_server_response_body_size_bytes_sum{app=~"$app", namespace=~"$namespace"}[5m])) by (app)  # TX
sum(rate(http_server_request_body_size_bytes_sum{app=~"$app", namespace=~"$namespace"}[5m])) by (app)   # RX
```

**Query Explanation**:
- `http_server_response_body_size_bytes_sum` - Total response body bytes (TX)
- `http_server_request_body_size_bytes_sum` - Total request body bytes (RX)
- **Result**: Bandwidth consumption per service

**Why This Metric**:
- Network cost analysis
- Bandwidth bottleneck detection
- Payload size optimization

**What to Do When**:
- **High TX**: Large responses - consider compression, pagination
- **High RX**: Large requests - validate payload size limits
- **TX >> RX**: Read-heavy API (typical)
- **RX >> TX**: Write-heavy API (file uploads)

**Note**: Only HTTP body size, excludes TCP/IP overhead (~5-10% additional).

---

### Panel 19: Total Requests In Flight per Service (ID: 19) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: short (count) | **Row**: Resources & Infrastructure

**Status**: **Removed / not emitted.** After the RFC-0014 metrics cutover this panel has no data source. The old `requests_in_flight` gauge came from the hand-rolled Prometheus middleware; on the OTLP push path it has **no equivalent** — otelgin v0.69 does **not** emit `http_server_active_requests` (verified live 2026-07-09). The in-flight saturation alerts were retired together with the `/metrics` scrape. Restoring an active-requests gauge is **blocked upstream** (pending otelgin support).

**Why it mattered** (for when a replacement lands):
- **Saturation signal** (4 Golden Signals: Latency, Traffic, Errors, Saturation)
- Queue depth indicator
- Service capacity verification

**Interim substitute**: use latency (Panels 1-3, 13-15) and CPU/memory saturation (Panels 16-17) as saturation proxies until an OTel active-requests metric is available.

---

### Panel 22: Allocation Rate per Service (ID: 22) 🗑 REMOVED (RFC-0017 W3)

**Type**: timeseries | **Unit**: ops (allocs/sec) | **Row**: Resources & Infrastructure

**Status**: The client_golang `go_memstats_frees_total` counter was **retired at the P3 cutover** — the OTel Go runtime set exposes **no frees counter**. Allocation churn is tracked by the allocation rate instead.

**Query**:
```promql
sum(rate(go_memory_allocations_total{app=~"$app", namespace=~"$namespace"}[5m])) by (app)
```

**Query Explanation**:
- `go_memory_allocations_total` - cumulative heap allocation count (OTel Go runtime metric); frees are not exposed
- `rate(...)` - allocations per second, the allocation-pressure signal
- **Result**: allocation rate per service

**Why This Metric**:
- Allocation pressure indicator
- Correlate with GC pressure (Panel 20)
- Optimization target: Reduce allocations

**What to Do When**:
- **High allocation rate**: Optimize hot paths to reduce allocations
- **Correlates with GC pressure**: Use sync.Pool, reuse buffers
- **Sudden increase**: Code change introduced excessive allocations

---

## Rows 6–8: gRPC East-West + Database (client)

Three rows added after this guide's per-panel sections were written; their
queries and reading guides live with their metric documentation:

- **🔗 gRPC East-West (RED)** — 3 lines, each pairing one signal **Server | Client**
  (RPS, error rate, P95 on `rpc_{server,client}_call_duration_seconds`).
  **🔗 Per Callee** — RPS | error-ratio + full-width P95 per callee.
  See [metrics-apps → gRPC instrumentation](../metrics/../../api/metrics.md#grpc-instrumentation-east-west).
- **🗄️ Database (client — otelpgx)** — query p95 by service/op
  (`db_client_operation_duration_seconds`, DB-scale buckets since pkg v0.24.0),
  operation errors, pool in-flight/saturation/contention (`pgxpool_*`).
  See [metrics-apps → DB client metrics](../metrics/../../api/metrics.md#db-client-metrics-otelpgx)
  and the four `DBClient*`/`PgxPool*` alerts in the
  [alert catalog](../alerting/alert-catalog.md#1-microservices-red-metrics).

## Common Patterns

### Pattern 1: Rate-Based Queries (Industry Standard)

```promql
rate(metric_count{...}[$rate])
```

**Why**: Google SRE and Prometheus recommend `rate()` for operational dashboards.

**Benefits**:
- Normalizes across time windows
- Handles counter resets automatically
- Per-second values easier to reason about

**When to use `increase()` instead**: Historical totals, not rates.

---

### Pattern 2: Histogram Percentiles

```promql
histogram_quantile(0.95, sum(rate(metric_bucket{...}[$rate])) by (le))
```

**Components**:
- `histogram_quantile()` - Calculate percentile from buckets
- `rate(..._bucket{...}[$rate])` - Rate of histogram buckets
- `sum(...) by (le)` - Preserve bucket boundaries (`le` label)

**Gotcha**: Must use `by (le)` or percentile calculation fails.

---

### Pattern 3: Defensive Division (Avoid NaN)

```promql
numerator / (denominator > 0 or vector(1))
```

**Why**: Prevents division by zero → NaN values.

**Example**: Apdex score returns 0.0 on zero traffic, not NaN.

---

### Pattern 4: Service-Level Aggregation

```promql
sum(metric{...}) by (app)
```

**Why**: Aggregate across all pods in a service.

**Use Case**: Capacity planning, cost analysis.

---

## Quick Reference

### Dashboard Health Checklist

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| P99 Response Time | < 500ms | 500ms-1s | > 1s |
| Success Rate % | ≥ 99% | 95-99% | < 95% |
| Error Rate % | < 1% | 1-5% | > 5% |
| Apdex Score | ≥ 0.9 | 0.7-0.9 | < 0.7 |
| 5xx Rate | 0 req/s | < 0.1 req/s | > 0.1 req/s |
| Restarts | 0 | 1-5 | > 5 |

### When to Investigate

1. **Latency Issues** → Check Panels 1-3, 13-15, 20-21, 31-34
2. **Error Spike** → Check Panels 27, 30, 201, 202, 25
3. **Traffic Drop** → Check Panels 4, 7, 23
4. **Memory Leak** → Check Panels 31-33, 20, 34
5. **Service Down** → Check Panels 7, 8, 28

### PromQL Functions Used

| Function | Purpose | Example |
|----------|---------|---------|
| `rate()` | Per-second rate over interval | `rate(http_server_request_duration_seconds_count[5m])` |
| `increase()` | Total increase over interval | `increase(http_server_request_duration_seconds_count[1h])` |
| `histogram_quantile()` | Calculate percentile | `histogram_quantile(0.95, ...)` |
| `sum()` | Aggregate values | `sum(metric) by (label)` |
| `count()` | Count time series | `count(go_goroutine_count{...})` (no `up` for OTLP-push apps) |


---
_Last updated: 2026-09-06 — removed the trailing **"Grafana Annotations (Planned
Feature)"** appendix: ~415 lines of a five-phase implementation plan for something
that was never built (`/api/annotations` returns `[]` and no Grafana manifest
configures any), written in Vietnamese inside an English-only tree, embedding a
third-party blog link, dated `2025-01-19`, and ending by proposing a
`docs/GRAFANA_ANNOTATIONS.md` that never appeared. A plan belongs in
[`docs/proposals/`](../../proposals/), not inside the page the docs index calls the
complete dashboard reference. Nothing describing the live board changed. Previously
2026-07-16 — chart-sourced canonical + RFC-0017 W3/W4 revision note._