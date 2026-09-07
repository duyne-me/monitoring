#!/usr/bin/env bash

# Validate Flux custom resources and kustomize overlays using kubeconform.
# Based on: https://github.com/fluxcd/flux2-kustomize-helm-example/blob/main/scripts/validate.sh
#
# Prerequisites:
#   - yq >= 4.50
#   - kustomize >= 5.8
#   - kubeconform >= 0.7
#   - curl
#
# Usage:
#   ./scripts/flux-validate.sh

set -o errexit
set -o pipefail

kustomize_flags=("--load-restrictor=LoadRestrictionsNone")

# ClickHouseInstallation is skipped, and the reason is a stale upstream schema
# rather than a shortcut: the datree CRDs-catalog copy of
# clickhouseinstallation_v1.json declares spec.configuration.zookeeper with
# additionalProperties:false and without the `keeper` property that operator
# 0.27.1 added, so it rejects a CORRECT manifest
# ("additional properties 'keeper' not allowed" — reproduced 2026-08-28).
# -ignore-missing-schemas does not help: the schema is found, it is just old.
# The ClickHouseKeeperInstallation schema IS current and does validate, which is
# the CR this train adds and the one a typo would most likely land in.
kubeconform_flags=("-skip=Secret,ClickHouseInstallation")
kubeconform_config=(
  "-strict" 
  "-ignore-missing-schemas" 
  "-schema-location" "default" 
  "-schema-location" "/tmp/flux-crd-schemas/{{.ResourceKind}}-fluxcd-{{.ResourceAPIVersion}}.json"
  "-schema-location" "/tmp/flux-crd-schemas/{{.ResourceKind}}-helm-{{.ResourceAPIVersion}}.json"
  "-schema-location" "/tmp/flux-crd-schemas/{{.ResourceKind}}-source-{{.ResourceAPIVersion}}.json"
  "-schema-location" "/tmp/flux-crd-schemas/{{.ResourceKind}}-image-{{.ResourceAPIVersion}}.json"
  "-schema-location" "/tmp/flux-crd-schemas/{{.ResourceKind}}-notification-{{.ResourceAPIVersion}}.json"
  # Community CRD schemas (datree CRDs-catalog): validates ExternalSecret,
  # DatabaseRole/Database, ServiceMonitor/PrometheusRule and — next train —
  # Gateway API CRs, which -ignore-missing-schemas used to wave through.
  "-schema-location" "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  "-verbose"
)

# Kustomize overlays that Flux actually reconciles (matches Flux Kustomization paths).
# These are the ONLY overlays we kustomize-build; auto-discovery causes parent/child
# collisions when intermediate kustomization.yaml files reference subdirectories.
kustomize_overlays=(
  "kubernetes/clusters/local"
  "kubernetes/infra/controllers"
  # temporal/ is excluded from controllers/kustomization.yaml (it needs its own
  # Kustomization so apps-local can depend on a Ready server), so a build of
  # controllers never reaches it — without these lines nothing validated it.
  "kubernetes/infra/controllers/temporal"
  # keycloak/ is excluded from controllers/kustomization.yaml for the same
  # reason (its own Kustomization, keycloak-local) — validate it explicitly.
  "kubernetes/infra/controllers/keycloak"
  # keda/ is excluded from controllers/kustomization.yaml for the same reason
  # (its own Kustomization, keda-local; ADR-055) — validate it explicitly.
  "kubernetes/infra/controllers/keda"
  "kubernetes/infra/configs/temporal"
  # clickhouse/ has its own Kustomization (clickhouse-local), so a build of
  # configs/ never reached it — before RFC-0028 it got nothing but a bare
  # yq syntax check, so a structurally broken overlay passed validate. The
  # ClickHouseKeeperInstallation is now really schema-validated here; the CHI is
  # skipped by kubeconform_flags for the stale-schema reason recorded above.
  "kubernetes/infra/configs/clickhouse"
  "kubernetes/infra/configs/clickhouse-schema"
  "kubernetes/infra/configs/databases"
  "kubernetes/infra/configs/observability"
  "kubernetes/infra/configs/secrets"
  "kubernetes/infra/configs/kyverno"
  "kubernetes/infra/configs/network-policies"
  # Envoy Gateway train (RFC-0024 P2): each excluded from controllers/
  # kustomization.yaml (own Flux Kustomizations) — validate them explicitly.
  "kubernetes/infra/controllers/gateway-api-crds"
  "kubernetes/infra/controllers/envoy-gateway"
  "kubernetes/infra/configs/envoy-gateway"
)

check_prerequisites() {
  local missing=0
  for cmd in yq kustomize kubeconform curl kyverno; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "ERROR - $cmd is not installed" >&2
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

download_schemas() {
  echo "INFO - Downloading Flux OpenAPI schemas"
  mkdir -p /tmp/flux-crd-schemas

  # Flux Operator schemas
  echo "  fetching flux-operator schemas"
  curl -sL https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/crd-schemas.tar.gz | \
    tar zxf - -C /tmp/flux-crd-schemas
  
  # Flux CD v2 schemas
  echo "  fetching flux2 schemas"
  curl -sL https://github.com/fluxcd/flux2/releases/latest/download/crd-schemas.tar.gz | \
    tar zxf - -C /tmp/flux-crd-schemas
}

validate_yaml_syntax() {
  echo "INFO - Validating YAML syntax"
  local count=0
  local failed=0
  while IFS= read -r -d $'\0' file; do
    if ! yq e 'true' "$file" > /dev/null 2>&1; then
      echo "  FAIL - $file"
      yq e 'true' "$file"
      failed=1
    fi
    count=$((count + 1))
  done < <(find kubernetes/ -path '*/.*' -prune -o -type f -name '*.yaml' -print0)
  echo "  checked $count files"
  if [[ $failed -ne 0 ]]; then
    echo "ERROR - YAML syntax validation failed" >&2
    exit 1
  fi
}

validate_standalone_manifests() {
  echo "INFO - Validating standalone Kubernetes manifests"
  local count=0
  while IFS= read -r -d $'\0' f; do
    kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}" "$f"
    count=$((count + 1))
  done < <(find kubernetes/apps/ -type f -name '*.yaml' -print0)
  echo "  validated $count app manifests"
}

validate_kustomize_overlays() {
  echo "INFO - Validating kustomize overlays"
  for overlay in "${kustomize_overlays[@]}"; do
    if [[ ! -d "$overlay" ]]; then
      echo "  SKIP - $overlay (not found)"
      continue
    fi
    echo "  building $overlay"
    kustomize build "$overlay" "${kustomize_flags[@]}" | \
      kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}"
    if [[ ${PIPESTATUS[0]} != 0 || ${PIPESTATUS[1]} != 0 ]]; then
      echo "ERROR - kustomize overlay validation failed: $overlay" >&2
      exit 1
    fi
  done
}

validate_production() {
  if [[ -d "kubernetes/clusters/production" ]]; then
    echo "INFO - Validating production cluster overlay"
    kustomize build "kubernetes/clusters/production" "${kustomize_flags[@]}" | \
      kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}"
    if [[ ${PIPESTATUS[0]} != 0 || ${PIPESTATUS[1]} != 0 ]]; then
      echo "ERROR - production overlay validation failed" >&2
      exit 1
    fi
  fi
}


# Worker Versioning wiring, RFC-0026 / ADR-054 shape.
#
# The controller now owns the version identity: it derives the Build ID and
# injects TEMPORAL_DEPLOYMENT_NAME + TEMPORAL_WORKER_BUILD_ID into every pod of
# every version it creates. So the three-way build-id comparison this function
# used to make has nothing left to compare — there is one file, and it states the
# Build ID nowhere. What replaces it are the mistakes that ARE still reachable,
# and every one of them fails the same way the old drift did: silently, with new
# workflows pinned to a version no worker serves.
#
# Written to fail LOUDLY rather than skip: every path that cannot make a
# comparison exits non-zero. A guard that silently compares nothing is worse than
# no guard, because its green line reads as proof.
validate_worker_versioning() {
  # ADR-064: EVERY Temporal worker is a WorkerDeployment under the controller,
  # so both files get the same checks. (Until 2026-08-27 checkout-worker was a
  # HelmRelease and this function policed that it stayed UNversioned; that
  # asymmetry is retired.)
  local wd
  for wd in kubernetes/apps/order-worker.yaml kubernetes/apps/checkout-worker.yaml; do

  if [[ ! -f "${wd}" ]]; then
    echo "ERROR - ${wd} is missing; cannot verify the Worker Versioning wiring" >&2
    exit 1
  fi

  # --- No per-build files may survive the cutover. One left behind means the old
  # HelmRelease and the controller both write Deployments for one deployment name,
  # and the loser is whichever reconciles second.
  local -a legacy=()
  local f
  for f in "${wd%.yaml}"-*.yaml; do
    [[ -f "${f}" ]] && legacy+=("${f}")
  done
  if [[ ${#legacy[@]} -gt 0 ]]; then
    echo "ERROR - per-build worker manifests still present (${legacy[*]}). ADR-054 replaced them with the single ${wd}; two writers of one deployment name is the drift this check used to police." >&2
    exit 1
  fi

  # --- The WorkerDeployment and its Connection must both be there, and the
  # connectionRef must resolve. A dangling ref leaves the controller unable to
  # reach Temporal, which surfaces as a version that is never registered.
  local kinds conn_name ref_name
  kinds=$(yq eval-all '[.kind] | join(",")' "${wd}")
  if [[ "${kinds}" != *"WorkerDeployment"* || "${kinds}" != *"Connection"* ]]; then
    echo "ERROR - ${wd}: expected both a Connection and a WorkerDeployment, found kinds [${kinds}]" >&2
    exit 1
  fi
  conn_name=$(yq eval-all 'select(.kind == "Connection") | .metadata.name' "${wd}")
  ref_name=$(yq eval-all 'select(.kind == "WorkerDeployment") | .spec.workerOptions.connectionRef.name' "${wd}")
  if [[ -z "${conn_name}" || "${conn_name}" == "null" || "${ref_name}" != "${conn_name}" ]]; then
    echo "ERROR - ${wd}: workerOptions.connectionRef.name (${ref_name}) does not name the Connection in this file (${conn_name})" >&2
    exit 1
  fi

  # --- The pod template must NOT hand-set the identity the controller injects.
  # Both spellings are rejected, and this is the ONLY guard against either:
  # pkg/temporalx reads one name per variable, so it cannot see a hand-set value
  # disagree with an injected one -- it exits only on HALF a config. A hand-set
  # TEMPORAL_DEPLOYMENT_NAME therefore reaches the process silently, and the
  # retired TEMPORAL_WORKER_DEPLOYMENT_NAME is a variable no binary reads at all
  # -- a manifest that lies quietly. Hence the check lives here.
  local stray
  stray=$(yq eval-all '[select(.kind == "WorkerDeployment") | .spec.template.spec.containers[].env[]? | select(.name == "TEMPORAL_DEPLOYMENT_NAME" or .name == "TEMPORAL_WORKER_BUILD_ID" or .name == "TEMPORAL_WORKER_DEPLOYMENT_NAME")] | length' "${wd}")
  if [[ -n "${stray}" && "${stray}" != "null" && "${stray}" -ne 0 ]]; then
    echo "ERROR - ${wd}: the pod template hand-sets versioning env. The controller injects TEMPORAL_DEPLOYMENT_NAME and TEMPORAL_WORKER_BUILD_ID per version (internal/k8s/deployments.go); a hand-set copy is a second identity." >&2
    exit 1
  fi

  # --- spec.replicas must be ABSENT (ADR-055). It is the controller's mode
  # switch: set, and the controller rewrites every active version's replicas on
  # each reconcile, fighting the KEDA HPA that owns them; nil is the documented
  # external-autoscaler mode (api/v1alpha1/workerdeployment_types.go, v1.9.0).
  local replicas
  replicas=$(yq eval-all 'select(.kind == "WorkerDeployment") | .spec.replicas' "${wd}")
  if [[ -n "${replicas}" && "${replicas}" != "null" ]]; then
    echo "ERROR - ${wd}: spec.replicas is set (${replicas}). KEDA owns replicas per version (ADR-055); a controller-managed count is a second writer on the same field. Remove the key." >&2
    exit 1
  fi

  echo "INFO - $(basename "${wd}" .yaml) versioning: single WorkerDeployment wired to Connection '${conn_name}', no per-build manifests, no hand-set version identity, replicas left to the autoscaler"

  done
}

# Kyverno policy behaviour. kubeconform only checks SHAPE, and it runs with
# -ignore-missing-schemas, so a Kyverno CRD whose schema is absent is waved
# through silently -- schema validation is not policy validation. `kyverno test`
# asks the only question that matters: given this manifest, does this policy
# pass or fail? That is the class of bug this repo has actually shipped. The
# first run of these fixtures found one: require-probes returned `error`, not a
# verdict, for any Pod with no ownerReferences.
#
# Pin the CLI to the engine the cluster runs (chart 3.8.2 -> v1.18.2). A CLI
# ahead of the engine can agree with itself and disagree with admission.
# The schema bootstrap Job asserts a replica count, and that number is stated in
# two files: the CHI's layout and the Job's EXPECTED_REPLICAS. Discovering it at
# runtime instead was tried and failed — the operator publishes the cluster
# definition asynchronously, so the Job "verified" 2 of 2 on a 3-replica store
# and went green (RFC-0028). Duplicating the intent is the safer trade, provided
# nothing lets the two drift. This is that guard.
# The CHI carries raw XML inside `spec.configuration.files`, and NOTHING else in
# this repo looks at it. kustomize sees a YAML string; kubeconform sees a string;
# the CRD schema sees a string. ClickHouse is the first thing to parse it, at
# startup, and it does not degrade -- a malformed file is
# `SAXParseException: Invalid token`, the server refuses to boot, and the operator
# rolls it into CrashLoopBackOff one replica at a time.
#
# Measured 2026-09-06, the hard way: an em-dash written as `--` inside an XML
# comment. XML forbids `--` in a comment. `make validate` passed, the sync went
# out, and chi-clickhouse-otel-0-0-0 crash-looped until the file was fixed. This
# check is four lines and would have caught it before the push.
validate_clickhouse_embedded_xml() {
  echo "INFO - Validating XML embedded in the ClickHouseInstallation"
  local chi="kubernetes/infra/configs/clickhouse/clickhouseinstallation.yaml"
  if [[ ! -f "$chi" ]]; then
    echo "  SKIP - CHI manifest not found"
    return 0
  fi
  local names
  names=$(yq e '.spec.configuration.files | keys | .[]' "$chi" 2>/dev/null)
  if [[ -z "$names" ]]; then
    echo "  SKIP - no configuration.files on the CHI"
    return 0
  fi
  local f
  for f in $names; do
    if ! yq e ".spec.configuration.files.\"${f}\"" "$chi" \
         | python3 -c 'import sys,xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())' 2>/dev/null; then
      echo "ERROR - ${chi}: configuration.files[\"${f}\"] is not well-formed XML." >&2
      echo "        ClickHouse refuses to start on a malformed config file, so this" >&2
      echo "        would crash-loop every replica. Common cause: \`--\` inside an" >&2
      echo "        XML comment, which XML forbids -- keep prose in YAML comments" >&2
      echo "        above the block instead." >&2
      exit 1
    fi
    echo "  ${f} parses"
  done
}

validate_clickhouse_replica_count() {
  echo "INFO - Validating ClickHouse replica count agreement"
  local chi="kubernetes/infra/configs/clickhouse/clickhouseinstallation.yaml"
  local job="kubernetes/infra/configs/clickhouse-schema/job.yaml"
  if [[ ! -f "$chi" || ! -f "$job" ]]; then
    echo "  SKIP - ClickHouse manifests not found"
    return 0
  fi
  local want got
  want=$(yq e '.spec.configuration.clusters[0].layout.replicasCount' "$chi")
  got=$(yq e '.spec.template.spec.containers[0].env[] | select(.name == "EXPECTED_REPLICAS") | .value' "$job")
  if [[ -z "$want" || "$want" == "null" ]]; then
    echo "ERROR - could not read replicasCount from $chi" >&2
    exit 1
  fi
  if [[ -z "$got" || "$got" == "null" ]]; then
    echo "ERROR - could not read EXPECTED_REPLICAS from $job" >&2
    exit 1
  fi
  if [[ "$want" != "$got" ]]; then
    echo "ERROR - replica count drift: CHI layout says $want, schema Job expects $got" >&2
    echo "        The Job asserts total_replicas against its own number, so a" >&2
    echo "        mismatch either fails the wave or, worse, passes on the wrong" >&2
    echo "        topology. Update both." >&2
    exit 1
  fi
  echo "  CHI replicasCount=$want matches schema Job EXPECTED_REPLICAS=$got"
}

validate_kyverno_policies() {
  local dir="kubernetes/infra/configs/kyverno/tests"
  if [[ ! -d "$dir" ]]; then
    echo "ERROR - $dir is missing; the policy fixtures are not optional" >&2
    exit 1
  fi
  local count
  count=$(find "$dir" -name 'kyverno-test.yaml' | wc -l | tr -d ' ')
  if [[ "$count" -eq 0 ]]; then
    echo "ERROR - no kyverno-test.yaml found under $dir" >&2
    exit 1
  fi
  echo "INFO - Running $count Kyverno policy test suite(s)"
  if ! kyverno test "$dir"; then
    echo "ERROR - Kyverno policy tests failed" >&2
    exit 1
  fi
  echo "INFO - Kyverno policy tests passed"
}

# Main
check_prerequisites
download_schemas
validate_yaml_syntax
validate_standalone_manifests
validate_kustomize_overlays
validate_worker_versioning
# The RustFS bucket list lives in two places -- the run-once setup Job and the
# 30-minute CronJob -- and the Job's header says to keep them in step. Nothing
# did until now.
validate_rustfs_bucket_lists() {
  echo "INFO - Validating RustFS bucket lists agree"
  local job="kubernetes/infra/controllers/storage/rustfs/job-setup-buckets.yaml"
  local cron="kubernetes/infra/controllers/storage/rustfs/helmrelease-cronjobs.yaml"
  if [[ ! -f "$job" || ! -f "$cron" ]]; then
    echo "  SKIP - RustFS bucket manifests not found"
    return 0
  fi
  local a b
  a=$(grep -ohE 'BUCKETS="[^"]*"' "$job" | head -1)
  b=$(grep -ohE 'BUCKETS="[^"]*"' "$cron" | head -1)
  if [[ -z "$a" || "$a" != "$b" ]]; then
    echo "ERROR - RustFS bucket lists differ: ${job} has ${a:-<none>}, ${cron} has ${b:-<none>}" >&2
    exit 1
  fi
  echo "  ${a}"
}

validate_kyverno_policies
validate_clickhouse_embedded_xml
validate_clickhouse_replica_count
validate_rustfs_bucket_lists
validate_production
echo "INFO - All validations passed"
