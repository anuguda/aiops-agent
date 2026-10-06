# Notices

## Provenance

This project adapts material originally authored by Anurag Guda and first
published as part of the Apache-2.0 `nemoclaw-community` repository
(github.com/agudanv/nemoclaw-community, branch `aguda/nemoclaw-kubernetes`,
path `examples/recipes/nvidia/kubernetes-sre-assistant`). The adaptation
re-publishes that author's own work with NVIDIA-branded content removed at
the author's direction; see `docs/nvidia-content-removals.md` for the complete
item-by-item record.

## License

- This repository: Apache-2.0, Copyright 2026 Anurag Guda. See `LICENSE`.

## Third-party components used at runtime

- **OpenClaw** (`ghcr.io/openclaw/openclaw:2026.7.1-2-slim`) — MIT License,
  Copyright (c) 2026 OpenClaw Foundation. github.com/openclaw/openclaw.
- **kubectl** (v1.36.2, staged from dl.k8s.io) — Apache-2.0,
  Copyright The Kubernetes Authors.
- **busybox** (`busybox:1.38`) — GPLv2 (full license text at
  busybox.net). Used only in an init container.
- **curl image** (`curlimages/curl:8.16.0`) — curl is MIT-like (curl
  license); the image bundles Alpine Linux (see the image repository's
  license notices). Used only in an init container.

## Skill content

- `agent/skills/kubernetes-sre/SKILL.md` is adapted from the author's own
  Apache-2.0 skill of the same name in the source recipe above.
- Optional add-on skills installed by `scripts/install-aiops-skills.sh` come
  from github.com/anuguda/aiops (Apache-2.0, Copyright 2026 Anurag Guda).
