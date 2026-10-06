#!/usr/bin/env bash
# Deploy the aiops-agent OpenClaw SRE assistant to Kubernetes.
#
# Secrets are generated in a temp directory and applied server-side.
# No secret material is ever written to the repo checkout.
#
# Usage:
#   export OPENROUTER_API_KEY="..."   # model provider key (required on first deploy)
#   ./scripts/deploy.sh                     # deploy (creates secret from env if needed)
#   ./scripts/deploy.sh --with-autoheal        # deploy base plus the opt-in autoheal controller
#   ./scripts/deploy.sh --create-secret     # create/update the Secret without deploying
#   ./scripts/deploy.sh --show-token         # print the gateway token
#   ./scripts/deploy.sh --delete-resources   # delete aiops-agent resources, keep the namespace
#   ./scripts/deploy.sh --delete-namespace    # delete the namespace and everything in it
#
# Environment:
#   AIOPS_NAMESPACE   Kubernetes namespace (default: aiops-agent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUSTOMIZE_ROOT="$REPO_DIR"
NS="${AIOPS_NAMESPACE:-aiops-agent}"
SECRET_NAME=openclaw-secrets

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

for cmd in kubectl openssl; do
  command -v "$cmd" &>/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done
kubectl cluster-info &>/dev/null || { echo "Cannot connect to cluster. Check kubeconfig." >&2; exit 1; }

ensure_namespace() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

ensure_secret() {
  ensure_namespace
  # Env-provided values override; absent values are resolved from the live
  # Secret. Only the two managed keys are ever patched, so keys an operator
  # added to the live Secret survive untouched by design.
  local tmp
  tmp="$(mktemp -d)"

  # The temp dir holds plaintext secret material; every exit path below
  # scrubs it explicitly (RETURN traps outlive this function in bash).
  kubectl get secret "$SECRET_NAME" -n "$NS" -o json >/dev/null 2>&1 && \
    kubectl get secret "$SECRET_NAME" -n "$NS" \
      -o jsonpath='{.data}' >"$tmp/existing.json" || echo '{}' >"$tmp/existing.json"

  if [ ! -s "$tmp/existing.json" ] || [ "$(cat "$tmp/existing.json")" = "" ]; then
    echo '{}' >"$tmp/existing.json"
  fi

  existing_token=""
  if command -v jq >/dev/null 2>&1; then
    existing_token="$(jq -r '."OPENCLAW_GATEWAY_TOKEN" // empty' "$tmp/existing.json" | base64 -d 2>/dev/null || true)"
  else
    existing_token="$(python3 -c '
import json, base64, sys
try:
    d = json.load(open("'"$tmp"'/existing.json"))
    v = d.get("OPENCLAW_GATEWAY_TOKEN")
    print(base64.b64decode(v).decode() if v else "")
except Exception:
    print("")
')"
  fi

  gateway_token="${existing_token:-$(openssl rand -hex 32)}"

  # Resolve the provider key from the live Secret when the env var is
  # absent: the merge-patch below writes a value for every managed key,
  # and the deployment's gateway env consumes this too.
  openrouter_key="${OPENROUTER_API_KEY:-}"
  if [ -z "$openrouter_key" ]; then
    if command -v jq >/dev/null 2>&1; then
      openrouter_key="$(jq -r '."OPENROUTER_API_KEY" // empty' "$tmp/existing.json" | base64 -d 2>/dev/null || true)"
    else
      openrouter_key="$(python3 -c '
import json, base64
try:
    d = json.load(open("'"$tmp"'/existing.json"))
    v = d.get("OPENROUTER_API_KEY")
    print(base64.b64decode(v).decode() if v else "")
except Exception:
    print("")
')"
    fi
  fi
  if [ -z "$openrouter_key" ]; then
    echo "OPENROUTER_API_KEY is not set and not present in the existing Secret." >&2
    echo "Export it and re-run, or run with --create-secret after exporting." >&2
    rm -rf "$tmp"
    exit 1
  fi

  # Update via merge-patch, never whole-object apply: the patch touches
  # exactly the two managed keys, so keys an operator added to the live
  # Secret survive untouched whatever kubectl does with apply deletions.
  if command -v jq >/dev/null 2>&1; then
    inner="$(jq -nc --arg t "$gateway_token" --arg k "$openrouter_key" \
      '{OPENCLAW_GATEWAY_TOKEN: $t, OPENROUTER_API_KEY: $k}')"
  else
    inner="$(python3 -c 'import json, sys
print(json.dumps({"OPENCLAW_GATEWAY_TOKEN": sys.argv[1], "OPENROUTER_API_KEY": sys.argv[2]}))' \
      "$gateway_token" "$openrouter_key")"
  fi

  if kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    kubectl -n "$NS" patch secret "$SECRET_NAME" --type=merge \
      -p "{\"stringData\":$inner}" >/dev/null
  else
    {
      echo "apiVersion: v1"
      echo "kind: Secret"
      echo "metadata:"
      echo "  name: $SECRET_NAME"
      echo "  namespace: $NS"
      echo "type: Opaque"
      printf 'stringData: %s\n' "$inner"
    } >"$tmp/secret.yaml"
    kubectl apply -f "$tmp/secret.yaml" >/dev/null
  fi
  rm -rf "$tmp"
  echo "Secret $SECRET_NAME ready in namespace $NS."
}

show_token() {
  kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d
  echo
}

delete_resources() {
  echo "Deleting aiops-agent resources in namespace $NS (namespace preserved)."
  kubectl delete -n "$NS" --ignore-not-found \
    deployment/openclaw service/openclaw pvc/openclaw-home-pvc \
    configmap/openclaw-config secret/openclaw-secrets serviceaccount/aiops-sre
  kubectl delete --ignore-not-found \
    clusterrole/aiops-agent-sre clusterrolebinding/aiops-agent-sre
  # Opt-in controller resources (see autoheal/): deleted with the same
  # umbrella so a --delete-resources leaves nothing stale behind.
  kubectl delete -n "$NS" --ignore-not-found \
    deployment/autoheal serviceaccount/autoheal \
    role/autoheal-memory rolebinding/autoheal-memory \
    configmap/autoheal-config configmap/autoheal-agent \
    configmap/autoheal-knowledge configmap/autoheal-memory
  kubectl delete --ignore-not-found \
    clusterrole/autoheal clusterrolebinding/autoheal
}

deploy() {
  ensure_secret
  # Build the base with kustomize and apply with an explicit namespace
  # target: manifests carry no inline namespace, so -n places the
  # namespaced objects (Cluster* excluded) into $AIOPS_NAMESPACE.
  kubectl kustomize "$KUSTOMIZE_ROOT" | kubectl apply -n "$NS" -f - >/dev/null
  # The ClusterRoleBinding subject namespace is hardcoded to the default;
  # rewrite it so the role binding tracks AIOPS_NAMESPACE.
  kubectl patch clusterrolebinding aiops-agent-sre --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"$NS\"}]"
  kubectl rollout status deployment/openclaw -n "$NS" --timeout=300s
  echo
  echo "Deployed. Gateway token:"
  show_token
  echo "Access the Control UI:"
  echo "  kubectl port-forward svc/openclaw 18789:18789 -n $NS"
  echo "  open http://127.0.0.1:18789"
}

deploy_autoheal() {
  ensure_namespace
  # Opt-in autoheal overlay, applied only here — the plain deploy path
  # never touches it. The kustomize root is autoheal/ itself: the root-only
  # load restrictor requires generator inputs (runtime sources in
  # sre_autoheal/) to live inside the root.
  kubectl kustomize "$REPO_DIR/autoheal" | kubectl apply -n "$NS" -f - >/dev/null
  # Same namespace-tracking patch as the base's ClusterRoleBinding.
  kubectl patch clusterrolebinding autoheal --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"$NS\"}]"
  # Role subjects too: same caveat — apply -n does not rewrite them.
  kubectl patch -n "$NS" rolebinding autoheal-memory --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"$NS\"}]"
  kubectl rollout status deployment/autoheal -n "$NS" --timeout=300s
  echo
  echo "Autoheal controller deployed: policy mode 'assisted', RBAC profile 'safe'."
  echo "Tail it with: kubectl logs -n $NS deployment/autoheal -f"
}

case "${1:-}" in
  -h|--help) usage ;;
  --create-secret) ensure_secret ;;
  --show-token) show_token ;;
  --delete-resources) delete_resources ;;
  --delete-namespace)
    echo "Deleting namespace $NS and everything in it."
    kubectl delete namespace "$NS" --ignore-not-found
    kubectl delete --ignore-not-found \
      clusterrole/aiops-agent-sre clusterrolebinding/aiops-agent-sre \
      clusterrole/autoheal clusterrolebinding/autoheal
    ;;
  --with-autoheal) deploy_autoheal ;;
  "") deploy ;;
  *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
esac
