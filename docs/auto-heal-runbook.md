# Auto-heal runbook

The interactive healing loop for the SRE assistant: you bring a symptom,
the assistant inspects and diagnoses, and the only mutation it can make —
a Deployment or StatefulSet replica delta — happens after you explicitly
confirm the exact before → after change. Nothing runs unattended.

This is deliberately **not** the upstream `sre-autoheal-agent` controller
(a standalone LLM-driven controller with no OpenClaw dependency — that
subtree was not ported; see the mapping table in
[architecture.md](architecture.md) and item 8 of
[nvidia-content-removals.md](nvidia-content-removals.md)). Run that
controller separately if you want autonomous healing; see the last section
for what a port must decide. Everything below is the loop v1 actually
ships.

## The loop

1. **Symptom.** There is no alert integration — the loop starts when you
   bring the signal (an alert you paste, a user report, or a hunch) to the
   assistant in the Control UI chat.
2. **Inspect first.** Before proposing anything, the assistant gathers
   evidence with read-only `kubectl`: `get`, `describe`, `logs`, `events`,
   `top` (skill contract rules 1–2 in
   `agent/skills/kubernetes-sre/SKILL.md`).
3. **Diagnosis and proposal.** It states a diagnosis together with the
   evidence it used. If the fix is a replica delta, it proposes the new
   replica count.
4. **Confirmation gate.** It shows the exact intended delta — replicas
   before → after — and waits for your explicit go-ahead (contract rule 6).
   No confirmation, no mutation.
5. **Mutation.** On your go-ahead it performs the only mutation RBAC
   grants: `patch`/`update` on `deployments/scale` or `statefulsets/scale`.
6. **Verify.** It re-reads the target (current/desired replicas, rollout
   status, fresh events) and reports what actually changed.

Anything outside that boundary is never executed: the assistant refuses
and prints the exact, human-reviewable `kubectl` command for you to run
(contract rule 5). A forbidden-verb error from RBAC means stop, not retry
with a variation (rule 3).

## The action boundary

Enforced by `deploy/rbac.yaml` (ClusterRole `aiops-agent-sre`,
cluster-wide). The skill contract mirrors the role, but RBAC is the actual
guarantee.

| Category | Resources | Verbs |
| --- | --- | --- |
| Read — core | namespaces, nodes, pods, pods/log, services, endpoints, events, configmaps, persistentvolumeclaims, persistentvolumes, resourcequotas, limitranges | `get` `list` `watch` |
| Read — apps | deployments, statefulsets, daemonsets, replicasets | `get` `list` `watch` |
| Read — batch / autoscaling / networking | jobs, cronjobs, horizontalpodautoscalers, ingresses, networkpolicies | `get` `list` `watch` |
| Read — OpenShift compatibility | routes (`route.openshift.io`), deploymentconfigs (`apps.openshift.io`); inert on vanilla Kubernetes | `get` `list` `watch` |
| Read — metrics | `metrics.k8s.io` nodes, pods | `get` `list` |
| Health / discovery | `/healthz` `/livez` `/readyz` `/version` `/api` `/apis` (+subpaths) | `get` |
| **Mutate** | **`deployments/scale`, `statefulsets/scale`** | **`get` `patch` `update`** |

Never granted, anywhere: `delete` (no delete verb exists on any resource),
Secrets (read or create), `exec`/`attach`, RBAC writes, node or
security-policy writes. If the target is HPA-managed the assistant can
see it (`get` on `horizontalpodautoscalers`), but a manual scale delta
contends with the controller — make it confirm HPA ownership before
confirming any replica change.

## Failure patterns

What to bring, what the assistant will read first, and where the hard
boundary falls for the common degradations:

| Symptom | First reads the assistant runs | In reach vs. printed for you |
| --- | --- | --- |
| CrashLoopBackOff | `get`/`describe pod`, container logs, events | Diagnosis in reach (probe/limits/command/image). If config is broken, scaling won't fix it — it prints the human command (e.g. rollout undo / apply). |
| OOMKilled | `describe pod`, `top pods`, `get limitrange`, event reasons | Scale **in** reach if pressure is load-driven (before → after delta + confirmation). Request/limit changes are out of reach — printed. |
| ImagePullBackOff / ErrImagePull | `describe pod`, pod events | Diagnosis only (tag/registry/credential). No image mutation is possible — the fix is printed. |
| Rollout stuck | `rollout status`, `get replicasets`, events on the replicaset | Scale-out in reach if more replicas unblocks capacity. Rollback is out of reach — `kubectl rollout undo` printed. |
| Workload scaling to zero / crashed replicas | `get deployment`, `get statefulset`, HPA if present | The core auto-heal action: propose the exact replica delta, confirm, patch `/scale`, verify. |
| PVC Pending / binding problems | `get pvc`, `get pv`, `get storageclass`, events | Read-only diagnosis. No storage mutation is possible — printed. |
| Node pressure / unschedulable pods | `top nodes`, `describe node`, cluster events | Diagnosis (which workloads suffer) in reach. Cordon/drain are node mutations — printed, never run. |

The upstream controller's GPU-event knowledge base (its
`knowledge/failure_patterns.json` with `nvidia.com/gpu` pattern strings)
was not ported; accelerated-hardware diagnosis on this assistant is
whatever generic pod/event/`describe node` evidence shows, nothing more.

## Verified behavior (lived, on the reference cluster)

- **Scale path works**: an in-pod `kubectl scale deployment/openclaw
  --replicas=1` against the live cluster succeeded under this RBAC
  (`deployment.apps/openclaw scaled`).
- **Delete is refused, not redirected**: asked to delete a live pod, the
  assistant refused the bare delete, surfaced the exact resource identity,
  and printed the human-reviewable `kubectl delete` command instead; when
  remediation options were offered it required an explicit confirmation
  before acting. Deletion required a human hand by construction (no delete
  verb exists to "accidentally" succeed).
- **Model failover is transparent to the contract**: on an OpenRouter
  balance that cannot reserve the primary's `maxTokens`, turns fall back
  `kimi-k3` → `deepseek-v4.1-flash` (logged), with identical RBAC behavior.

Operating wrinkles to keep in mind (see README "Known wrinkles"):

- `kubectl auth can-i` (v1.36.2) misreports subresource verdicts —
  `deployments/scale` prints `no` while the real scale PATCH succeeds.
  Trust `auth can-i --list` or a real operation.
- Run the loop interactively through the gateway UI / port-forward. Heavy
  headless `agent exec` inside the 2 Gi gateway pod stacks a second agent
  runtime and can OOM the pod during QA-scale sessions.

## The upstream controller (opt-in, now shipped)

The interactive loop above is the default healing path. Autonomous,
unattended healing is available too — as a strictly opt-in overlay that
shipped with this repo on 2026-10-05:

```bash
./scripts/deploy.sh --with-autoheal      # or: kubectl kustomize autoheal | kubectl apply -n <ns> -f -
```

- It runs as its own workload (`deployment/autoheal`) with its own
  ServiceAccount and `safe`-profile ClusterRole — no OpenClaw dependency,
  and never the assistant's session: an unattended healer needs mutations
  the assistant must not have, so the two credentials are deliberately
  separable and independently revocable.
- The annotation vocabulary is de-branded to `aiops.autoheal/*`: opt out
  per workload with `kubectl label <resource> aiops.autoheal/managed=false`;
  approve an escalated MEDIUM-tier action with
  `kubectl annotate <resource> aiops.autoheal/approve=<action-id>`.
- Policy modes: `observe` (notify only), `assisted` (SAFE tier auto-executes,
  MEDIUM tier requires the approval annotation), `automatic`. Shipped
  default: `assisted`. `drain_node`/`approve_csr` are never granted by the
  shipped RBAC.
- `knowledge/failure_patterns.json` retains its `nvidia.com/gpu`
  event-pattern strings: they match the standard Kubernetes GPU resource
  name, harmless on clusters without GPU nodes.
- Operating details (memory ConfigMap, storage-expansion enablement,
  source-change restarts, CronJob alternative): `autoheal/manifests/README.md`.
