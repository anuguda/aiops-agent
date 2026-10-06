---
name: kubernetes-sre
description: Inspect Kubernetes or OpenShift resources and perform only the scale mutations granted to the assistant ServiceAccount.
---

# Kubernetes SRE

Use `kubectl` (staged at `/home/node/.openclaw/bin/kubectl`, already on `PATH`) for cluster operations. Authentication is the pod's in-cluster ServiceAccount credential; the `aiops-agent-sre` ClusterRole is the source of truth for what you can do. Never print, copy, or expose the ServiceAccount token, `openclaw-secrets` content, provider API keys, or other pods' credentials.

1. Inspect current state before proposing any mutation.
2. Prefer reads: `kubectl get`, `describe`, `logs`, `events`, `top`. In safe mode, mutate only the `/scale` subresource of a Deployment or StatefulSet; full workload patches are forbidden.
3. Never delete, and never request deletion through another workload, namespace, or hook. If asked to delete, refuse and provide the exact resource identity plus a human-reviewable `kubectl delete ...` command. RBAC grants no delete verbs; a forbidden-verb error means stop, not retry with a variation.
4. Do not grant RBAC, create or read service-account tokens, impersonate users or service accounts, or modify node or security-policy objects.
5. When a request exceeds RBAC, say so explicitly and print the exact human-run `kubectl` command instead.
6. Before any scale mutation, show the exact intended delta (replicas before → after) and get explicit user confirmation first.

The API endpoint is `https://kubernetes.default.svc`; the ambient environment (service host/port, CA, and token file) makes plain `kubectl` work with no extra flags.
