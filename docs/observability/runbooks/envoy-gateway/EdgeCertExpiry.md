# EdgeCertExpiry

Covers `EdgeCertExpiringSoon` (warning, < 7 days) and `EdgeCertExpired`
(critical, < 1 day). Same investigation, different urgency.

| | |
|---|---|
| **Severity** | warning at `< 7` days / critical at `< 1` day |
| **Category** | availability |
| **Source** | [`envoy-gateway/alerts.yaml`](../../../../kubernetes/infra/configs/observability/metrics/prometheusrules/envoy-gateway/alerts.yaml) |
| **Metrics** | `min(envoy_server_days_until_first_cert_expiring{job="envoy-gateway"})` |
| **Status** | active — VERIFY-AT-KIND (added 2026-09-08; confirm the gauge tracks the SDS cert, expected 75–90 on a fresh Kind) |
| **Dashboard** | Gateway → Envoy Global (server row) |
| **Local-stack** | not present — the compose edge terminates TLS with a static file cert; `job="envoy"` exposes the same gauge if needed |

## Meaning

The proxy fleet is **serving** a certificate that expires within 7 days (or
within its last day). The gauge is Envoy's own count of days until the
soonest-expiring certificate it has loaded — SDS-delivered certificates
included — and it floors at 0 once a cert has expired, which is why the
critical rule is `< 1` and not `< 0`.

`configs/envoy-gateway/certificate.yaml` issues the edge cert for 90 days and
renews 15 days ahead, so a healthy edge never reads below about 15. Reading 7
means renewal or delivery has been broken for more than a week.

This is deliberately a different question from the cert-manager alerts
(`CertManagerCertExpiringSoon`, `CertManagerCertNotReady`). Those watch the
`Certificate` resource and fire when **renewal** fails. They cannot see the
last hop: the renewed Secret has to reach the proxies through the controller's
SDS push. A stalled push leaves the Certificate `Ready` and the listener on the
old cert.

## Impact

At 0 days every HTTPS client rejects the handshake — the SPA, every API call on
`:443`, and the Keycloak and OpenBAO hairpin through the edge (ADR-062). Plain
HTTP on `:80` keeps working, which on Kind is most local traffic; on anything
public it is the whole platform.

## Diagnosis

### PromQL

```promql
min(envoy_server_days_until_first_cert_expiring{job="envoy-gateway"})
# Per proxy — one replica behind the other means a stalled SDS push, not a renewal failure
envoy_server_days_until_first_cert_expiring{job="envoy-gateway"}
# Did the controller fail to push anything?
sum(rate(xds_snapshot_update_total{job="envoy-gateway-controller", status="failure"}[10m]))
```

### kubectl / logs

```bash
# 1. What cert-manager thinks — notAfter and renewal time
kubectl -n envoy-gateway get certificate -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,NOTAFTER:.status.notAfter,RENEW:.status.renewalTime'

# 2. What the Secret actually holds
kubectl -n envoy-gateway get secret <tls-secret> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate

# 3. What the proxy is serving (from inside the cluster)
kubectl -n envoy-gateway run -it --rm curl --image=curlimages/curl:8.10.1 --restart=Never -- \
  sh -c 'echo | openssl s_client -connect envoy-envoy-gateway-platform-<hash>.envoy-gateway.svc:443 -servername <host> 2>/dev/null | openssl x509 -noout -enddate'

# 4. Envoy's own list of loaded certs (admin API, per pod)
POD=$(kubectl -n envoy-gateway get pod -l gateway.envoyproxy.io/owning-gateway-name=platform -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway exec "$POD" -- wget -qO- http://127.0.0.1:19000/certs
```

Read the three dates against each other:

| Certificate notAfter | Secret enddate | Proxy enddate | Where it is stuck |
|---|---|---|---|
| far | far | **near** | SDS push — controller or proxy did not pick up the new Secret |
| far | **near** | near | cert-manager wrote status but not the Secret — rare; check cert-manager logs |
| **near** | near | near | renewal failed — issuer, ACME, or the homelab CA (see the CA-rebirth note in [`docs/secrets`](../../../secrets/README.md)) |

## Mitigation

1. **Renewal failed**: `kubectl -n envoy-gateway describe certificate` and the
   cert-manager logs name the reason. `cmctl renew <name>` forces an attempt
   once the cause is fixed.
2. **Push stalled, controller healthy**: `kubectl -n envoy-gateway rollout
   restart deploy envoy-gateway` re-snapshots xDS; the proxies pick up the
   Secret within seconds. If [EnvoyGatewayControllerDown](EnvoyGatewayControllerDown.md)
   or [EnvoyGatewayReconcileErrors](EnvoyGatewayReconcileErrors.md) is firing,
   fix that first — this alert is a symptom of it.
3. **Push stalled, one proxy only**: restart that proxy pod; the PDB keeps the
   other serving.
4. Do **not** hand-edit the Secret. Flux and cert-manager both own it and will
   revert or fight the change.

## Escalation

Ticket at 7 days — there is a week. Page at `EdgeCertExpired`, or earlier if
the Certificate itself is not Ready and the issuer is down, because the fix
then has a dependency. What not to do: extend the Certificate `duration` to buy
time; the proxy still holds the old cert until a push delivers the new one.

## Related

- `CertManagerCertExpiringSoon` / `CertManagerCertNotReady` (§ GitOps in the
  catalog) — the renewal side of the same certificate.
- [EnvoyGatewayReconcileErrors](EnvoyGatewayReconcileErrors.md) — a failing xDS
  snapshot is the usual reason a renewed cert never reaches the fleet.

```bash
git log --oneline -5 -- kubernetes/infra/configs/envoy-gateway/certificate.yaml
```

---
_Last updated: 2026-09-08 — created from the awesome-prometheus-alerts audit (upstream `EnvoySSLCertificateExpiringSoon` / `EnvoySSLCertificateExpired`; the upstream `< 0` critical can never fire on an unsigned day gauge, so ours is `< 1`)_
