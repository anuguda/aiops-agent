# aiops-agent

An OpenClaw-based **Kubernetes SRE assistant** that runs in-cluster, inspects
the cluster it lives in, and answers questions with evidence from `kubectl`.

Chat with it through the OpenClaw Control UI (or your own integration), and
it will run read-only `kubectl` commands against the live cluster — pod
status, events, logs, resource pressure, rollout state — under a deliberately
narrow RBAC role: **read almost everything, mutate nothing except Deployment
and StatefulSet replicas, never delete**.

Adapted by the original author from the Apache-2.0
`nemoclaw-community` recipe `kubernetes-sre-assistant`
(GitHub: `agudanv/nemoclaw-community`, branch `aguda/nemoclaw-kubernetes`),
re-targeted from NemoClaw to OpenClaw and de-branded:
see [docs/nvidia-content-removals.md](docs/nvidia-content-removals.md) for
the complete removals record and [docs/architecture.md](docs/architecture.md)
for the component-by-component mapping and trust model.

## What you get

- An OpenClaw Gateway pod (`openclaw` namespace object, default namespace
  `aiops-agent`) with its agent workspace (AGENTS.md persona +
  `kubernetes-sre` skill) and a pinned, checksum-verified `kubectl`
  staged onto a PVC.
- A ServiceAccount (`aiops-sre`) bound to the `aiops-agent-sre` ClusterRole:
  read-mostly, `patch`/`update` on `deployments/scale` and
  `statefulsets/scale` only, no secrets, no delete, no exec.
- Model access via a custom provider block (`openrouter`) over the
  OpenAI-compatible API — primary `moonshotai/kimi-k3`, fallback
  `deepseek/deepseek-v4.1-flash`.

## Prerequisites

- A Kubernetes cluster with `default` (or equivalent dynamic) storage
  provisioning, and `kubectl` with cluster admin on the deploy machine.
- A model provider key — an OpenRouter API key (`OPENROUTER_API_KEY`
  by default), for the endpoint recorded in `agent/openclaw.json`.

## Quickstart

```bash
export OPENROUTER_API_KEY="your-key-here"
./scripts/deploy.sh
```

The deploy script creates the namespace
(`AIOPS_NAMESPACE=<other-name>` to override), secrets, and the manifests
(Kustomize at the repo root, resources under `deploy/`). Then:

```bash
kubectl port-forward svc/openclaw 18789:18789 -n aiops-agent
open http://127.0.0.1:18789
```

Gateway token for the Control UI login:

```bash
kubectl get secret openclaw-secrets -n aiops-agent \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d
```

## What the assistant will and won't do

- **Will**: `get`/`describe`/`logs`/`events`/`top` on common resources;
  watch rollouts; scale crashed Deployments and StatefulSets back up after
  showing you the exact replica delta; print human-reviewable commands for
  anything outside its reach.
- **Won't**: delete anything (refuses and shows you the command instead),
  read Secrets, exec into other pods, change images/commands/ServiceAccounts,
  grant RBAC, or touch nodes/ClusterRoles.

Hard limits live in `deploy/rbac.yaml`. The skill contract
(`agent/skills/kubernetes-sre/SKILL.md`) and the persona
(`agent/AGENTS.md`) enforce the same rules at prompt level, with RBAC as
the actual guarantee.

## Add skills from the aiops library

The [aiops skills library](https://github.com/anuguda/aiops) ships a larger
set of SRE and Kubernetes skills written to the same `SKILL.md` front-matter
convention (this project also publishes from that repo). To copy them into
the live workspace:

```bash
./scripts/install-aiops-skills.sh main
```

## Update agent content

The workspace copy on the PVC owns `openclaw.json`, `AGENTS.md`, and skills
after the first boot, so OpenClaw-side edits survive restarts; ConfigMap edits
need an explicit reseed and restart:

```bash
kubectl exec -n aiops-agent deploy/openclaw -- rm /home/node/.openclaw/openclaw.json
kubectl rollout restart -n aiops-agent deploy/openclaw
```

## Security notes

Read [docs/architecture.md](docs/architecture.md#trust-model-and-its-delta-vs-upstream)
before pointing this at a production cluster. Upstream ran the agent through
an authenticating proxy without exposing raw cluster credentials; this
OpenClaw port runs the agent shell in the gateway pod with the
ServiceAccount token mounted — convenient, auditable via RBAC, but the shell
can read its own secrets, so the role here is intentionally narrow, and
re-introducing the proxy is the documented follow-up.

## Commands

| Command | Effect |
| --- | --- |
| `./scripts/deploy.sh` | Deploy everything (idempotent for redeploys) |
| `./scripts/deploy.sh --create-secret` | Create/update the secret only |
| `./scripts/deploy.sh --show-token` | Print the gateway token |
| `./scripts/deploy.sh --delete-resources` | Remove the deployment, keep the namespace |
| `./scripts/deploy.sh --delete-namespace` | Remove the namespace and resources |
| `./scripts/install-aiops-skills.sh main` | Copy SRE skills from the aiops repo into the live workspace |

## Scope of the adaptation

Faithful to the upstream recipe where it matters (agent persona, skill
contract, safe-mode RBAC), with three deliberate v1 exclusions, all
documented in `docs/architecture.md`:

- The `broad-no-delete` opt-in escalation RBAC mode.
- The `openshift-llm-deploy` skill (NVIDIA inference-stack specific).
- The `sre-autoheal-agent` controller (standalone; no OpenClaw dependency).

## License

Apache-2.0, Copyright 2026 Anurag Guda. This project borrows nothing
code-wise from any NVIDIA-licensed component at runtime — see
[NOTICES.md](NOTICES.md) for the full third-party record.

## Verified on

Deployed and exercised on a single-node kubeadm v1.36.2 cluster
(containerd 2.3.1), 2026-10-05:

- `scripts/deploy.sh` rolls out clean, is idempotent on re-run, and
  re-running without `OPENROUTER_API_KEY` exported preserves the provider
  key already in the Secret (exit 0).
- Gateway pod 1/1 Running; the staged, checksum-verified kubectl
  (v1.36.2) works in-pod.
- RBAC positives: `get pods` across all namespaces; a real
  `kubectl scale deployment/openclaw --replicas=1` in-pod succeeds
  (`deployment.apps/openclaw scaled`).
- RBAC negatives (verified via `kubectl auth can-i` and the live role):
  `delete pods`, `create secrets`, `create pods/exec` denied cluster-wide;
  there are no delete verbs anywhere in `deploy/rbac.yaml`.
- `scripts/install-aiops-skills.sh main` installs 21 skills into the live
  workspace via in-pod `kubectl exec`.
- `deploy.sh --show-token` prints the gateway token.
- Model inference runs through OpenRouter with the configured
  kimi-k3 → deepseek-v4.1-flash failover: headless `agent exec` reached
  the provider (HTTP 200), fell back on the primary's credit-reservation
  short-fall, and executed multi-round kubectl tool calls against the
  live cluster.

Known wrinkles observed during verification:

- `kubectl auth can-i` (v1.36.2) misreports subresource verdicts —
  `deployments/scale` prints `no` while the real scale PATCH succeeds.
  Trust `auth can-i --list` or a real operation for subresource proofs.
- Choosing the primary (`moonshotai/kimi-k3`) on an OpenRouter account
  whose balance cannot reserve `maxTokens: 8192` makes every turn fall
  back to `deepseek/deepseek-v4.1-flash` (graceful, logged). Top up the
  account or lower `maxTokens` in `agent/openclaw.json` to prefer the
  primary.
- Running headless `agent exec` inside the gateway pod stacks a second
  agent runtime in the same 2 Gi container and OOM-killed it during
  heavy QA; interactive sessions through the gateway are unaffected.
  For heavy headless QA, run from a throwaway pod or raise the memory
  limit first.
