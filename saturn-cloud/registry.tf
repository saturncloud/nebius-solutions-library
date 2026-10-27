############################
# Container registry for Saturn image builds
############################
# Atlas pushes the images users build in Saturn (Images -> build) to this
# install's own Nebius Container Registry. Nodes already pull from it through
# the ncr_nodes service account (viewers group, mk8s.tf).
#
# Push access is scoped to this one registry: a dedicated service account in a
# dedicated group whose only permission is `editor` on the registry. Its static
# key is issued by scripts/ncr-push-key.sh straight into the cluster Secret
# saturn/saturn-container-registry, so the key is never in Terraform state or
# in helm values. See README "Image builds" for rotation.

resource "nebius_registry_v1_registry" "images" {
  count       = var.enable_image_builds ? 1 : 0
  parent_id   = var.project_id
  name        = "${var.cluster_name}-images"
  description = "Saturn image builds for ${var.cluster_name}"
}

resource "nebius_iam_v1_service_account" "ncr_push" {
  count       = var.enable_image_builds ? 1 : 0
  parent_id   = var.project_id
  name        = "${var.cluster_name}-ncr-push"
  description = "Pushes Saturn image builds to ${var.cluster_name}-images only"
}

resource "nebius_iam_v1_group" "ncr_push" {
  count     = var.enable_image_builds ? 1 : 0
  parent_id = var.project_id
  name      = "${var.cluster_name}-ncr-push"
}

resource "nebius_iam_v1_group_membership" "ncr_push" {
  count     = var.enable_image_builds ? 1 : 0
  parent_id = nebius_iam_v1_group.ncr_push[0].id
  member_id = nebius_iam_v1_service_account.ncr_push[0].id
}

resource "nebius_iam_v1_access_permit" "ncr_push" {
  count       = var.enable_image_builds ? 1 : 0
  parent_id   = nebius_iam_v1_group.ncr_push[0].id
  resource_id = nebius_registry_v1_registry.images[0].id
  role        = "editor"
}

locals {
  # Images live under cr.<region>.nebius.cloud/<registry ID without "registry-">.
  saturn_image_registry_host = var.enable_image_builds ? format(
    "%s/%s",
    nebius_registry_v1_registry.images[0].status.registry_fqdn,
    trimprefix(nebius_registry_v1_registry.images[0].id, "registry-"),
  ) : ""
}

# Runs on every apply: the script is idempotent (it re-issues only when the
# Secret is missing, points elsewhere, or its key is gone or within 30 days of
# expiry), so a deleted Secret is restored by the next apply.
resource "terraform_data" "ncr_push_key" {
  count            = var.enable_image_builds && var.manage_helm ? 1 : 0
  triggers_replace = [plantimestamp()]

  provisioner "local-exec" {
    command = "${path.module}/scripts/ncr-push-key.sh"
    environment = {
      CLUSTER_ID    = nebius_mk8s_v1_cluster.saturn_cluster.id
      PROJECT_ID    = var.project_id
      PUSH_SA_ID    = nebius_iam_v1_service_account.ncr_push[0].id
      REGISTRY_HOST = local.saturn_image_registry_host
      KEY_NAME      = "${var.cluster_name}-ncr-push"
    }
  }

  depends_on = [
    nebius_iam_v1_group_membership.ncr_push,
    nebius_iam_v1_access_permit.ncr_push,
  ]
}

output "saturn_image_registry" {
  description = "Registry that Saturn image builds push to (empty when enable_image_builds is false)"
  value       = local.saturn_image_registry_host
}
