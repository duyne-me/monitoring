# KubeDeploymentReplicasMismatch

| | |
|---|---|
| **Severity** | warning |
| **Category** | workloads |
| **Source** | `kubernetes/infra/configs/observability/metrics/prometheusrules/kubernetes/workload-alerts.yaml` |
| **Metrics** | `kube_deployment_spec_replicas`, `kube_deployment_status_replicas_ready` (kube-state-metrics) — note the word order: `..._status_replicas_ready`. This rule used `..._status_ready_replicas` until 2026-09-06, a name KSM does not publish, so it matched nothing and could never fire |
| **Status** | active |
| **Dashboard** | Observability → Kubernetes cluster overview |
| **Local-stack** | not present — no Kubernetes in the compose stack |

## Meaning

Deployment desired replicas != ready replicas for 15 minutes. A normal rollout
passes through this state briefly; fifteen minutes of mismatch means pods are
failing to schedule, start, or pass readiness.

## Impact

The service is running degraded — fewer ready replicas than it was sized for —
and can't absorb its designed load or a further pod loss. If ready replicas
hit zero, this is an outage wearing a warning label.

## Diagnosis

### kubectl / logs

```bash
# Check deployment status
kubectl get deployment -n $NAMESPACE $DEPLOYMENT
kubectl describe deployment -n $NAMESPACE $DEPLOYMENT

# Check replica set events
kubectl get rs -n $NAMESPACE -l app=$DEPLOYMENT
kubectl describe rs -n $NAMESPACE $(kubectl get rs -n $NAMESPACE -l app=$DEPLOYMENT --sort-by=.metadata.creationTimestamp -o name | tail -1)
```

### PromQL

```promql
# Alert expr
kube_deployment_spec_replicas
!= kube_deployment_status_replicas_ready

# Verify mismatch
kube_deployment_spec_replicas{namespace="$NAMESPACE", deployment="$DEPLOYMENT"}
- kube_deployment_status_replicas_ready{namespace="$NAMESPACE", deployment="$DEPLOYMENT"}
```

## Mitigation

1. Check if pods are stuck in Pending (resource constraints) or
   CrashLoopBackOff.
2. If during rollout: wait for completion or rollback with
   `kubectl rollout undo`.
3. Check HPA if autoscaling is active.

## Escalation

Ticket by default — one missing replica with the rest healthy is degraded, not
down. Page if ready replicas reach zero, or if
[KubePodCrashLooping](KubePodCrashLooping.md) /
[KubePodNotReady](KubePodNotReady.md) co-fires on this Deployment's pods.
Do not `kubectl scale` the replica count up to paper over the gap: the new
pods will fail for the same reason, and on a Flux-managed Deployment the
GitOps reconciler reverts the edit anyway.

## Related

- [KubePodCrashLooping](KubePodCrashLooping.md), [KubePodNotReady](KubePodNotReady.md)
  — the usual reasons a replica never becomes ready.
- [KubeHPAMaxedOut](KubeHPAMaxedOut.md) — when autoscaling owns the replica count.

---
_Last updated: 2026-08-19 — split out of infrastructure-alerts.md into the kubernetes/ domain folder_
