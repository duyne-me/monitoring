# Flux Operator bootstrap for the duynhlab homelab.
#
# Terraform/OpenTofu owns only the ephemeral bootstrap mechanism (namespace,
# RBAC, the bootstrap Job). The Job installs Flux Operator and applies the
# FluxInstance with create-if-missing semantics, then Flux adopts those
# resources and reconciles steady-state. When manifests are unchanged,
# `tofu plan` shows zero diff.
#
# The FluxInstance manifest is the single source of truth shared with the
# kubectl/kustomize flow it replaces:
#   kubernetes/clusters/<cluster_name>/flux-system/instance.yaml

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.8.0"

  revision = var.revision

  gitops_resources = {
    instance_yaml = file("${path.root}/../kubernetes/clusters/${var.cluster_name}/flux-system/instance.yaml")

    operator_chart = {
      # Pinned (was implicit latest): the values below depend on the web UI's
      # Web Config API, so the chart must move deliberately, not on rebuild.
      version = "0.58.1"
      # Keycloak SSO for the web UI at ui.duynh.me (ADR-062 recipe, third
      # staff client). The operator reads the rendered Web Config document
      # from the flux-web-config Secret (ExternalSecret in
      # kubernetes/infra/configs/flux-web/ — no secret literal here or in
      # git). The CA mount is the live-issuer trust anchor for the
      # https://id.duynh.me issuer (flux-web-idp-trust Certificate, same fix
      # class as openbao-idp-trust). SSL_CERT_DIR — not SSL_CERT_FILE — on
      # purpose: Go ADDS the dir's certs to the default system FILES, whereas
      # SSL_CERT_FILE would replace them and break the operator's own TLS to
      # ghcr.io (distribution manifests). Both Secrets are created by the
      # flux-web-local wave, which reconciles AFTER bootstrap — the operator
      # tolerates a missing config secret at start (UI serves anonymous-off
      # until it appears).
      values_yaml = <<-YAML
        web:
          configSecretName: flux-web-config
        extraEnvs:
          - name: SSL_CERT_DIR
            value: /etc/flux-web-idp-trust
        extraVolumes:
          - name: flux-web-idp-trust
            secret:
              secretName: flux-web-idp-trust
              optional: true
        extraVolumeMounts:
          - name: flux-web-idp-trust
            mountPath: /etc/flux-web-idp-trust
            readOnly: true
      YAML
    }
  }

  # PRODUCTION (manage the OCI/Git pull secret declaratively from an external
  # store — see module README "Managed secrets from an external secrets store").
  # Keep this commented for local: the Kind registry is HTTP/insecure and needs
  # no auth. The Secret name must match `spec.sync.pullSecret` in instance.yaml.
  #
  # managed_resources = {
  #   secrets_yaml = <<-YAML
  #     apiVersion: v1
  #     kind: Secret
  #     metadata:
  #       name: flux-system
  #       namespace: flux-system
  #     type: kubernetes.io/dockerconfigjson
  #     stringData:
  #       .dockerconfigjson: '${replace(local.ghcr_auth_dockerconfigjson, "'", "''")}'
  #   YAML
  # }
}

# PRODUCTION: build a registry pull secret from a Terraform variable or an
# external secrets data source (AWS/GCP/Azure/Vault). No secret material is
# stored in state — the module only persists a SHA-256 hash.
#
# locals {
#   ghcr_auth_dockerconfigjson = jsonencode({
#     auths = {
#       "ghcr.io" = {
#         username = "flux"
#         password = var.ghcr_token
#         auth     = base64encode("flux:${var.ghcr_token}")
#       }
#     }
#   })
# }
