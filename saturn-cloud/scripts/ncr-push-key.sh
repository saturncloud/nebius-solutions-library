#!/usr/bin/env bash
# Keeps Secret saturn/saturn-container-registry holding a working push key for
# this install's Nebius Container Registry, so Atlas can push Saturn image
# builds (GENERIC_DOCKER_REGISTRY_*).
#
# Runs on every `terraform apply` (registry.tf) and is idempotent:
#   - Secret present, for this registry, its key still exists and expires more
#     than ROTATE_BEFORE_DAYS from now: nothing changes.
#   - Otherwise (no Secret, other registry, key deleted, near expiry, or
#     FORCE_ROTATE=1): issue a new key, write the Secret, restart Atlas, then
#     delete every older key of the push service account.
# The key is never printed, never passed on a command line and never written
# to Terraform state: it goes from the CLI's JSON (a 0600 temp file) into
# `kubectl apply` on stdin.
set -euo pipefail

: "${CLUSTER_ID:?}" "${PROJECT_ID:?}" "${PUSH_SA_ID:?}" "${REGISTRY_HOST:?}" "${KEY_NAME:?}"
NAMESPACE=${NAMESPACE:-saturn}
SECRET=${SECRET:-saturn-container-registry}
KEY_LIFETIME_DAYS=${KEY_LIFETIME_DAYS:-180}
ROTATE_BEFORE_DAYS=${ROTATE_BEFORE_DAYS:-30}
NAMESPACE_WAIT_SECONDS=${NAMESPACE_WAIT_SECONDS:-1800}

for tool in nebius kubectl jq; do
  command -v "$tool" >/dev/null || { echo "ncr-push-key: $tool is required on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
export KUBECONFIG="$work/kubeconfig"
nebius mk8s v1 cluster get-credentials --id "$CLUSTER_ID" --external --kubeconfig "$KUBECONFIG" --force >/dev/null

# The saturn namespace is created by the operator chart; wait for it rather
# than creating it here (the chart owns it).
waited=0
until kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; do
  if [ "$waited" -ge "$NAMESPACE_WAIT_SECONDS" ]; then
    echo "ncr-push-key: namespace $NAMESPACE did not appear in ${NAMESPACE_WAIT_SECONDS}s; re-run terraform apply once Saturn is installed" >&2
    exit 1
  fi
  sleep 15; waited=$((waited + 15))
done

current_key_id=""
if kubectl -n "$NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; then
  host=$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.GENERIC_DOCKER_REGISTRY_HOST}' | base64 -d)
  current_key_id=$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.metadata.annotations.saturncloud\.io/static-key-id}')
  if [ "${FORCE_ROTATE:-0}" != 1 ] && [ "$host" = "$REGISTRY_HOST" ] && [ -n "$current_key_id" ]; then
    expires=$(nebius iam static-key get --id "$current_key_id" --format json 2>/dev/null | jq -r '.spec.expiresAt // .spec.expires_at // empty' || true)
    if [ -n "$expires" ] && [ "$(date -u -d "$expires" +%s)" -gt "$(date -u -d "+${ROTATE_BEFORE_DAYS} days" +%s)" ]; then
      echo "ncr-push-key: $NAMESPACE/$SECRET is current (key $current_key_id expires $expires)"
      exit 0
    fi
  fi
fi

expires_at=$(date -u -d "+${KEY_LIFETIME_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
umask 077
nebius iam static-key issue --parent-id "$PROJECT_ID" --account-service-account-id "$PUSH_SA_ID" \
  --service container_registry --name "$KEY_NAME-$(date -u +%Y%m%d%H%M%S)" --expires-at "$expires_at" \
  --format json >"$work/key.json" 2>/dev/null
new_key_id=$(jq -r '.resource_id // .operation.resource_id // .metadata.id // empty' "$work/key.json")
jq -e -r '.token' "$work/key.json" >/dev/null || { echo "ncr-push-key: static-key issue returned no token" >&2; exit 1; }
# The old-key cleanup below keeps only this id: never run it without one.
[[ "$new_key_id" == statickey-* ]] || { echo "ncr-push-key: could not read the new key's id" >&2; exit 1; }

jq -n --arg ns "$NAMESPACE" --arg name "$SECRET" --arg host "$REGISTRY_HOST" --arg id "$new_key_id" \
  --arg exp "$expires_at" --rawfile key "$work/key.json" '
  {apiVersion: "v1", kind: "Secret", type: "Opaque",
   metadata: {name: $name, namespace: $ns,
     labels: {"app.kubernetes.io/managed-by": "nebius-saturn-cloud-module"},
     annotations: {"saturncloud.io/static-key-id": $id, "saturncloud.io/static-key-expires-at": $exp}},
   stringData: {GENERIC_DOCKER_REGISTRY_HOST: $host, GENERIC_DOCKER_REGISTRY_USER: "iam",
     GENERIC_DOCKER_REGISTRY_PASSWORD: ($key | fromjson | .token)}}' \
  | kubectl apply --server-side --force-conflicts --field-manager=nebius-saturn-cloud-module -f - >/dev/null
echo "ncr-push-key: wrote $NAMESPACE/$SECRET (key $new_key_id, expires $expires_at)"

# Atlas reads the Secret at start.
if kubectl -n "$NAMESPACE" get deployment saturn-cloud >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" rollout restart deployment saturn-cloud >/dev/null
fi

# Older keys of the push account are no longer used: delete them so a key
# that left the cluster cannot outlive the rotation.
nebius iam static-key list --parent-id "$PROJECT_ID" --format json \
  | jq -r --arg sa "$PUSH_SA_ID" --arg keep "$new_key_id" \
      '.items[]? | select(.spec.account.service_account.id == $sa and .metadata.id != $keep) | .metadata.id' \
  | while read -r old; do
      nebius iam static-key delete --id "$old" >/dev/null && echo "ncr-push-key: deleted old key $old"
    done
