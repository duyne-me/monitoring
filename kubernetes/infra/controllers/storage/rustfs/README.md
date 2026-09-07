# RustFS - S3-Compatible Object Storage

RustFS is a high-performance, distributed object storage system (S3-compatible) built in Rust.

## Deployment Modes

| Mode | Pods | PVCs | Use Case |
|------|------|------|----------|
| **Standalone** | 1 | 1 | Local/dev (current) |
| **Distributed** | 4 | 16 (4 per pod) | Default production |
| **Distributed** | 16 | 16 (1 per pod) | Large scale |

## Current Config (Standalone)

- **Namespace:** rustfs
- **Mode:** Standalone (1 pod, 1 PVC)
- **Service:** ClusterIP on port 9000 (API), 9001 (Console)
- **Ingress:** Disabled (no ingress controller in local Kind)
- **ingress.className:** nginx (avoids TraefikService CRD - cluster has no Traefik)

## Access

```bash
# Port-forward for local access
kubectl port-forward -n rustfs svc/rustfs-svc 9000:9000 9001:9001

# API: http://localhost:9000
# Console: http://localhost:9001
# Credentials: stored in OpenBAO at secret/local/infra/rustfs/root
#              synced into Secret/rustfs-credentials by ExternalSecret.
# Read with:
#   kubectl -n rustfs get secret rustfs-credentials \
#     -o jsonpath='{.data.RUSTFS_ACCESS_KEY}' | base64 -d
```

## Switch to Distributed Mode

Edit `helmrelease.yaml`:

```yaml
mode:
  standalone:
    enabled: false
  distributed:
    enabled: true

# Style 1: 4 pods, 4 PVCs each (default)
replicaCount: 4

# Style 2: 16 pods, 1 PVC each
replicaCount: 16
```

## StorageClass

Uses `standard` StorageClass (Kind default). If your cluster uses `local-path`, set:

```yaml
storageclass:
  name: local-path
```

Kind clusters typically have `standard` (provisioner: rancher.io/local-path).

## Changing `config.*` — two traps, both silent

On 2026-08-21 rustfs wrote **34 GB of log in two hours** and filled the whole
100 GB podman machine, taking the API server, the admission webhooks and the
Flux chain with it. Nothing in that cascade named a disk. Fixing it took three
attempts, because each of the first two *looked* applied:

**1. The keys live under `config.rustfs`, not `config`.** Chart 0.12.0 nests them
one level deeper than the obvious place. Set them at `config.log_level` and Helm
accepts the values, renders nothing, and the ConfigMap keeps its defaults. Never
verify a values change by reading the values file:

```bash
kubectl -n rustfs get cm rustfs-config -o jsonpath='{.data}' | tr , '\n' | grep LOG
# want: LOGGER_LEVEL=warn, LOG_KEEP_FILES=3,
#       LOG_ROTATION_SIZE_MB=50, LOG_ROTATION_TIME=hour
```

**2. A correct ConfigMap does not reach a running pod.** The container takes its
environment through `envFrom: configMapRef`, and chart 0.12.0 puts **no
annotations at all** on the pod template — no `checksum/config`. So Helm updates
the ConfigMap, the Deployment spec is unchanged, no rollout happens, and the
process keeps the environment it started with. Recreate the pod and check the
process, not the object:

```bash
kubectl -n rustfs rollout restart deploy/rustfs
kubectl -n rustfs rollout status deploy/rustfs

P=$(kubectl -n rustfs get pods -l app.kubernetes.io/name=rustfs -o jsonpath='{.items[0].metadata.name}')
kubectl -n rustfs exec "$P" -- sh -c 'env | grep RUSTFS_OBS_LOG'
```

This is an upstream gap: the chart should carry a `checksum/config` annotation.
Until it does, **every** `config.*` change here needs the restart above, and the
change is invisible without it.

## Why the log volume needs a cap at all

The log is not error output. It is span noise from the `s3s` crate at `INFO` —
a `new`/`close` pair per S3 request signature — so the volume tracks **traffic**,
not incidents. Barman WAL archiving, Tempo and Pyroscope push objects
continuously, which on this cluster came to roughly **17 GB/hour**. That
measurement predates [RFC-0027](../../../../../docs/proposals/rfc/RFC-0027/README.md):
Tempo is retired, so **two** writers remain and the figure is an upper bound now.

Hourly rotation was already working; the files were named by hour. The cap that
was missing is the one on **size**, which is why a single hour reached 19 GB.

**The invariant to keep:** `log_rotation.size × log_rotation.keep_files` must
stay **below** `storageclass.logStorageSize` (today 50 MB × 3 = 150 MB < 256Mi).
`logStorageSize` enforces nothing on its own — local-path is hostPath-backed, so
`requests.storage` is advisory and a "256Mi" PVC grew to 34 GB.

Nothing alerted, and on Kind nothing could:
`KubePersistentVolumeFillingUp` and `CNPGClusterLowDiskSpace*` are marked
*inactive on Kind* because local-path reports no `kubelet_volume_stats_*`
(see [`alert-catalog.md`](../../../../../docs/observability/alerting/alert-catalog.md)).
The cap is the control; there is no safety net behind it.
