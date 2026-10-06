#!/usr/bin/env bash
# Install SRE skills from the aiops skills library
# (https://github.com/anuguda/aiops) into the deployed assistant's workspace.
#
# Usage:
#   ./scripts/install-aiops-skills.sh [ref]     # ref defaults to main
#
# Environment:
#   AIOPS_NAMESPACE   Kubernetes namespace (default: aiops-agent)
set -euo pipefail

NS="${AIOPS_NAMESPACE:-aiops-agent}"
REF="${1:-main}"
WORKSPACE=/home/node/.openclaw/workspace

for cmd in kubectl curl tar; do
  command -v "$cmd" &>/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done
kubectl cluster-info &>/dev/null || { echo "Cannot connect to cluster." >&2; exit 1; }
kubectl get deployment openclaw -n "$NS" >/dev/null 2>&1 || {
  echo "Deployment openclaw not found in namespace $NS; deploy first." >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching aiops@$REF ..."
curl -fsSL "https://codeload.github.com/anuguda/aiops/tar.gz/refs/heads/$REF" \
  -o "$tmp/aiops.tar.gz"
tar -xzf "$tmp/aiops.tar.gz" -C "$tmp"
SRC="$tmp/aiops-$REF/skills/operations/infrastructure"
[ -d "$SRC" ] || { echo "Expected skills tree not found in aiops@$REF." >&2; exit 1; }

installed=0
for group in sre kubernetes; do
  [ -d "$SRC/$group" ] || continue
  for skill_dir in "$SRC/$group"/*; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    name="$(basename "$skill_dir")"
    kubectl exec -n "$NS" deployment/openclaw -- \
      sh -c "mkdir -p '$WORKSPACE/skills/$name'"
    kubectl exec -i -n "$NS" deployment/openclaw -- \
      sh -c "cat > '$WORKSPACE/skills/$name/SKILL.md'" <"$skill_dir/SKILL.md"
    echo "installed: skills/$name"
    installed=$((installed + 1))
  done
done

echo
echo "Installed $installed skills into the workspace. Restart the deployment"
echo "to make a freshly installed skill load in a new session if needed:"
echo "  kubectl rollout restart deployment/openclaw -n $NS"
