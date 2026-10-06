# NVIDIA Content Removals

Every NVIDIA-affiliated copyright notice, brand, and piece of NVIDIA-specific
content that existed in the upstream source of this adaptation, and what was
done with it. Upstream source:
`github.com/agudanv/nemoclaw-community`, branch `aguda/nemoclaw-kubernetes`,
path `examples/recipes/nvidia/kubernetes-sre-assistant`
(Apache-2.0; the published repo places the recipe under a
`recipes/nvidia/` path segment that this repository does not reproduce).

The upstream material is the author's own work product, originally authored at
NVIDIA and re-published here at the author's direction. The repository itself
is stripped of NVIDIA branding per the author's explicit instruction.

## Removed / replaced, item by item

1. **SPDX NVIDIA copyright headers.** Every upstream file carried
   `SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION &
   AFFILIATES. All rights reserved.` plus `SPDX-License-Identifier:
   Apache-2.0`. No file in this repository carries a NVIDIA copyright header;
   project-level licensing moved to the top-level `LICENSE` (Apache-2.0,
   Copyright Anurag Guda 2026) and `NOTICES.md`. Upstream files with the
   header included: `Chart.yaml`, `values.yaml`, `values-scenario-*.yaml`,
   all `templates/*.yaml`, all `files/skills/*`, `scripts/build-sre-skills-bundle.py`,
   and every Python source under `files/agent/vendored/sre-autoheal/`.

2. **Recipe provenance metadata rows.** The upstream recipe's front-matter
   (`name: kubernetes-sre-assistant`, `category: NVIDIA Hyperscale / SRE`,
   `labels: nvidia`, `maintainer: NVIDIA`, `NVIDIA Recipe`-identified rows in
   recipe listings) were not carried over. This repo identifies itself as
   `aiops-agent`, maintainer Anurag Guda, no NVIDIA category or label.

3. **NemoClaw / Hermes / OpenShell stack references.** All mentions in
   README text, template comments, and skill prose (96 grep hits across the
   recipe tree) re-target OpenClaw terminology. In the ported skill
   (`agent/skills/kubernetes-sre/SKILL.md`) the upstream execution contract
   described the NemoClaw-managed OpenShell sandbox and chart proxy and was
   rewritten for the OpenClaw in-pod exec model.

4. **Kubernetes objects owning NVIDIA-annotation prefixes.** Upstream
   `ClusterRole` carried `nemoclaw.nvidia.com/delete-access` and
   `nemoclaw.nvidia.com/rbac-mode` annotations; the autoheal machinery used
   `sre-autoheal.nvidia.com/*` annotation prefixes plus opt-out/approval
   labels on workload namespaces. None are emitted by this repo's manifests.

5. **Helm chart plumbing.** `Chart.yaml` (name `kubernetes-sre-assistant`,
   description "Helm chart for deploying a NemoClaw-powered Kubernetes SRE
   assistant", `maintainers: NVIDIA`), `values.yaml` structure
   (`global.sre.*`, `agentEnv`, `extraStateMounts`, `networkPoliciesTemplate`,
   `seedPlugins`), helper templates, and the `scripts/build-sre-skills-bundle.py`
   chunking pipeline were dropped wholesale with the move to Kustomize-first
   deployment per the OpenClaw install model (see `docs/architecture.md`).

6. **NVIDIA API groups in RBAC.** Upstream safe-mode RBAC included read-only
   entries for `serving.kserve.io` (`inferenceservices`, `servingruntimes`,
   `clusterservingruntimes`) and `nim.opendatahub.io` (`nimservices`,
   `nimcaches`, `nimpipelines`). Neither group is emitted by this repo's
   `deploy/rbac.yaml`; on clusters that do define them the assistant will
   report them as out-of-scope.

7. **NVIDIA-ecosystem image pins.** Upstream `values.yaml` pinned
   `nvcr.io/...` images (NVIDIA Dynamo, TensorRT-LLM/TensorRT serving, vLLM
   variants) and the OpenShift `openshift-llm-deploy` skill referenced NIM /
   Dynamo deployment APIs (`nim.opendatahaul.io`, `inferenceservices`,
   `kserve`). The LLM-deploy skill itself is out of scope for v1 (see
   `docs/architecture.md`), so none of these references exist in this repo.
   Images referenced here are generic upstream open-source projects:
   `ghcr.io/openclaw/openclaw`, `busybox`, `curlimages/curl`, and the
   Kubernetes `kubectl` binary from `dl.k8s.io`.

8. **Autoheal controller content.** Nothing from the upstream
   `charts/sre-autoheal-agent` subtree was ported: the vendored multi-module
   Python agent (loop lease, checkpointing, `knowledge/failure_patterns.json`
   including its `nvidia.com/gpu` event-pattern strings, RedHat-OpenShift
   remediation hooks), its RBAC templates, its `sre-autoheal.nvidia.com/*`
   annotation vocabulary, and its value-scenario tests. Documented as an
   unported upstream component in `docs/architecture.md`; the interactive
   healing loop shipped instead is documented in
   `docs/auto-heal-runbook.md`.

9. **NVIDIA-authored `SOURCE_NOTICES.md`.** Upstream
   `files/skills/kubernetes-sre/SOURCE_NOTICES.md` and the repo-root
   provenance/notice blocks were rewritten as this file plus `NOTICES.md`,
   which records the Apache-2.0 lineage (same author) and third-party
   components actually used by this repo. No NVIDIA notice text is retained.

10. **`oc`/`ko` client pinning block.** Upstream `values.yaml`
    `global.sre.cli` pinned OpenShift `oc` and `dok8s` binaries with
    checksums downloaded from NVIDIA-hosted mirrors. Replaced by a pinned
    `kubectl` from the official `dl.k8s.io` CDN with an inline sha256 check
    (see `deploy/deployment.yaml`, `init-kubectl`).
11. **Model provider swap (NVIDIA inferencehub → OpenRouter).** The
    upstream recipe and the initial OpenClaw port routed models through
    the author's NVIDIA inferencehub account
    (`https://integrate.api.nvidia.com/v1`, env `NVIDIA_INFERENCE_API_KEY`
    → the `nvidia-inference` provider block in `agent/openclaw.json`).
    On 2026-10-05 that account key was expired and no other NVIDIA
    entitlement covered the target models, so per the author's provider
    decision the repository now defaults to OpenRouter
    (`https://openrouter.ai/api/v1`, env `OPENROUTER_API_KEY`, provider
    `openrouter`) with the same primary model (`moonshotai/kimi-k3`) and
    the fallback re-id'd to OpenRouter's catalog
    (`deepseek/deepseek-v4.1-flash`). No NVIDIA endpoint, credential, or
    provider block remains in the repo.

## Kept (with provenance recorded)

- The skill contract semantics of
  `files/skills/kubernetes-sre/SKILL.md` (inspect-before-mutate, scale-only
  mutation, refuse-delete, no-RBAC-granting), re-expressed for the OpenClaw
  execution model — authored by the same author as the original.
- The safe-mode RBAC resource/verb shape, minus NVIDIA API groups and
  annotation metadata.
- Third-party components are recorded in `NOTICES.md`.
