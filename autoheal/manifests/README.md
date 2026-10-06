# autoheal (opt-in controller)

The `sre_autoheal` controller in this directory tree is the de-branded port of
the upstream Kubernetes "sre-autoheal-agent" chart: an autonomous detect ->
diagnose -> decide -> act -> verify -> learn -> notify loop over the cluster.
It is **not part of the default deployment** — nothing in this tree is
referenced by the base kustomization; it is applied when you deploy with
`scripts/deploy.sh --with-autoheal` or by applying the tree's Kustomize
root (`autoheal/kustomization.yaml`) explicitly:

```sh
kubectl kustomize autoheal | kubectl apply -n aiops-agent -f -
kubectl patch clusterrolebinding autoheal --type=json \
  -p '[{"op":"replace","path":"/subjects/0/namespace","value":"aiops-agent"}]'
kubectl patch -n aiops-agent rolebinding autoheal-memory --type=json \
  -p '[{"op":"replace","path":"/subjects/0/namespace","value":"aiops-agent"}]'
kubectl rollout status deployment/autoheal -n aiops-agent
```

## Why a separate ServiceAccount

`autoheal` runs with its own identity and a ClusterRole (`rbac.yaml`, profile
`safe`) that grants mutations the interactive assistant's `aiops-sre` role
does **not** have: delete Pods, patch Deployments/StatefulSets/DaemonSets,
scale subresources. Opt-in means the base trust model is unchanged until you
apply this overlay; revoking the controller never touches the assistant.

## Defaults shipped here

| Setting | Value | Meaning |
|---|---|---|
| policy.mode | `assisted` | SAFE tier auto-executes; MEDIUM tier needs an operator's approval annotation |
| RBAC profile | `safe` | no nodes patch, no Secrets read, never deletes anything except Pods |
| run mode | `watch` (Deployment) | loop every `detection.interval_seconds` (60s) |
| memory backend | `configmap` (`autoheal-memory` | learned outcomes persist across restarts, no PVC needed |
| LLM | OpenRouter `moonshotai/kimi-k3` via `SRE_AUTOHEAL_LLM_API_KEY` | reuses `openclaw-secrets.OPENROUTER_API_KEY`; absent key -> rule-based only |
| scope | all namespaces except kube-system, kube-public, kube-node-lease, openshift* | |
| opt-out label | `aiops.autoheal/managed=false` | never remediate a workload carrying it |
| approval | `aiops.autoheal/approve` | annotation carrying an action id, `*` or the finding fingerprint |

The LLM only ever **chooses** an action id from the allow-listed catalog
(`sre_autoheal/actions.py`); it cannot invent commands. `drain_node` and
`approve_csr` are documented for humans and are not in RBAC at all.

## Operating it

```sh
kubectl logs -n aiops-agent deployment/autoheal -f

# propose-then-approve a MEDIUM-tier action the agent escalated:
kubectl annotate deployment/<name> -n <ns> aiops.autoheal/approve=<action-id> --overwrite

# permanently exclude a workload:
kubectl label deployment/<name> -n <ns> aiops.autoheal/managed=false

# dry-run an entire cycle against any cluster (no mutations):
kubectl exec -n aiops-agent deployment/autoheal -- python3 -m sre_autoheal heal --once --dry-run
```

Read-only trial: set `"policy": {"mode": "observe"}` in `config.json`, apply,
and the agent detects/diagnoses/notifies without ever acting.

## Enabling guarded PVC expansion (storage healing)

Off by default. In `config.json` set `"storage": {"enabled": true, ...}`
(see `sre_autoheal/config.py` DEFAULTS for all knobs: exact targets, thresholds,
storage-class allow-list, metrics endpoint). Automatic mode additionally
requires per-target namespace Roles granting `patch` on exactly the target
PVC — never a ClusterRole write. The controller refuses to resize anything
that is not an exact configured target with the `aiops.autoheal/storage=true`
opt-in label, and honors the global `managed=false` opt-out.

## Source changes do not auto-roll

ConfigMaps use stable names, so the kubelet refreshes mounted files in-place
but the running loop keeps old code until restart:

```sh
kubectl rollout restart deployment/autoheal -n aiops-agent
```

Prefer periodic one-shots instead of a long-running loop? Replace the
Deployment with a CronJob using args `["heal", "--once"]` — the upstream chart
default cadence was `*/5 * * * *`.
