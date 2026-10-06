# Architecture

## What this is

A single-pod OpenClaw Gateway deployed by Kustomize, acting as an in-cluster
Kubernetes SRE assistant. The agent shell runs inside the gateway container,
uses a staged `kubectl`, and authenticates with the pod's own ServiceAccount.

## Upstream recipe → this repo

Adapted from the author's own
`nemoclaw-community/aguda/nemoclaw-kubernetes` recipe
`examples/recipes/nvidia/kubernetes-sre-assistant` (Apache-2.0). Component by
component:

| Upstream (NemoClaw recipe) | This repo | Notes |
| --- | --- | --- |
| Helm chart (`Chart.yaml`, templates, values) | Kustomize (root `kustomization.yaml`, resources under `deploy/`) | Follows the OpenClaw install model: single container, config seeds, no chart plumbing. |
| NemoClaw/Hermes agent behind OpenShell gateway | OpenClaw Gateway (`ghcr.io/openclaw/openclaw:2026.9.8-slim`) | Same workspace/AGENTS.md/skills conventions; OpenClaw's own exec tooling replaces the sandbox shell. |
| SRE API proxy (`templates/sre-proxy.yaml`) + agent-only kubeconfig | Not ported | Biggest trust-model change; see below. |
| `kubernetes-sre` skill (invoked `/chart-bin/oc --kubeconfig $SRE_KUBECONFIG`) | Same skill re-expressed for `kubectl` + in-cluster SA (`agent/skills/kubernetes-sre/SKILL.md`) | Contract preserved: inspect-first, scale-only, refuse-delete. |
| Safe-mode RBAC ClusterRole | `deploy/rbac.yaml` (ClusterRole `aiops-agent-sre`) | NVIDIA API groups (kserve, NIM) and NVIDIA annotations dropped (see removals doc). |
| `broad-no-delete` RBAC mode | Not ported | Opt-in escalation mode; deliberately omitted from v1. Add a second ClusterRole if wanted, at your own risk review. |
| `oc` client pinning from NVIDIA mirrors | `kubectl` v1.36.2 pinned from `dl.k8s.io`, sha256-verified | Init container stages it onto the PVC (`deploy/deployment.yaml`). |
| Skills bundle ConfigMap chunking (Python builder) | Kustomize `configMapGenerator` + init-container seed | The three workspace files (`openclaw.json`, `AGENTS.md`, skill) mount as plain ConfigMap data. |
| `openshift-llm-deploy` skill | Not ported | Dynamo/NIM/vLLM deployment flows are NVIDIA-stack specific and out of scope. |
| `charts/sre-autoheal-agent` controller | `autoheal/` runtime sources + tests + opt-in Kustomize root at `autoheal/` (applied only by `scripts/deploy.sh --with-autoheal`) | Ported 2026-10-05, de-branded: annotation vocabulary `sre-autoheal.nvidia.com/*` → `aiops.autoheal/*`, NVIDIA SPDX headers stripped, Helm chart plumbing re-expressed as Kustomize. The overlay's kustomization root is `autoheal/` itself — kustomize's root-only load restrictor requires generator inputs (the `sre_autoheal/` runtime sources) to live inside the root, so the overlay cannot live under `deploy/`. Runs as its own workload (`autoheal` ServiceAccount, `safe`-profile ClusterRole) and never widens the assistant's reach; `nvidia.com/gpu` strings kept — functional resource name, not branding. Default policy mode `assisted`. |
| Deployer plumbing (`agentEnv`, `networkPoliciesTemplate`, `seedPlugins`) | Dropped | Single-tenant default-mesh deployment doesn't need them. |

## Trust model (and its delta vs upstream)

Upstream: the Hermes agent ran in an OpenShell sandbox and only ever talked
to the cluster through an authenticating SRE proxy — the agent never saw a
raw Kubernetes credential, and the proxy enforced `GET`-only plus
`/scale`-only mutations independent of RBAC.

This repo: OpenClaw runs the agent's shell inside the gateway pod
(read-only rootfs, dropped capabilities, non-root UID, no privilege
escalation), and mounts the in-cluster ServiceAccount token next to it.
Consequences:

- **Cluster blast radius is still bounded by RBAC.** The `aiops-agent-sre`
  ClusterRole is read-mostly; the only mutations are `patch`/`update` on
  `deployments/scale` and `statefulsets/scale`. No delete verbs, no secrets,
  no exec/attach, no RBAC writes, no node access.
- **In-pod credential visibility is a real degradation.** The agent's shell
  can read the ServiceAccount token, the same-namespace `openclaw-secrets`
  via the API (no: secrets RBAC is absent), and the pod environment
  including `OPENROUTER_API_KEY`. Keys and tokens are exfiltratable if
  the model misbehaves. v1 accepts this with RBAC-only containment and
  hard-coded skill rules; a follow-up can re-introduce an authenticating
  proxy so the agent never holds raw credentials again.
- The Control UI is on loopback in-pod; access is `kubectl port-forward`
  (or your own Ingress + TLS + auth layer if you change the gateway bind).

If you require the upstream property (agent never sees a credential), do not
deploy this as-is; port `templates/sre-proxy.yaml` and store the agent
kubeconfig in the gateway config only.

## Pod anatomy

```
init-config   seeds openclaw.json + workspace/AGENTS.md + kubernetes-sre skill
              onto the PVC from the openclaw-config ConfigMap (only-if-missing)
init-kubectl  stages kubectl v1.36.2 (sha256-pinned from dl.k8s.io) onto the
              PVC at /home/node/.openclaw/bin (on PATH)
gateway       node /app/dist/index.js gateway run  (OpenClaw Gateway)
              SA: aiops-sre (ClusterRole aiops-agent-sre)
```

Model access: custom provider `openrouter`
(`https://openrouter.ai/api/v1`, OpenAI-compatible) with
`moonshotai/kimi-k3` primary and `deepseek/deepseek-v4.1-flash` fallback.
The key is read from the `OPENROUTER_API_KEY` environment variable
(see the providers `apiKey` marker in `agent/openclaw.json`).

## Skills

The workspace (`~/.openclaw/workspace`) follows the OpenClaw convention:
`skills/<name>/SKILL.md` with YAML front-matter (`name`, `description`). v1
ships one skill (`kubernetes-sre`); `scripts/install-aiops-skills.sh` copies
the SRE and Kubernetes skill families from the
[aiops](https://github.com/anuguda/aiops) library into the live workspace.

## Update flow

The PVC copy of `openclaw.json`, `AGENTS.md`, and skills owns the config after
first boot (so OpenClaw-side edits survive restarts). After changing files
here, reseed deliberately:

```bash
kubectl exec -n aiops-agent deploy/openclaw -- rm /home/node/.openclaw/openclaw.json
kubectl rollout restart -n aiops-agent deploy/openclaw
```
