# Cloud Topics - Redpanda Operator Testing

This repository contains the test plan, Kubernetes manifests, and results for validating the `redpanda.storage.mode` topic property and `default_redpanda_storage_mode` cluster property introduced in [redpanda-data/redpanda#29352](https://github.com/redpanda-data/redpanda/pull/29352).

## Overview

Redpanda now supports an explicit `redpanda.storage.mode` topic property with four values:

| Mode | Description |
|------|-------------|
| `unset` | Legacy behavior. `redpanda.remote.read` and `redpanda.remote.write` control tiered storage permissions. |
| `local` | Local-only topic. Equivalent to legacy `remote.read=false`, `remote.write=false`. |
| `tiered` | Tiered storage topic. Equivalent to legacy `remote.read=true`, `remote.write=true`. |
| `cloud` | Cloud Topics infrastructure. Requires `cloud_topics_enabled=true`. `remote.read`/`remote.write` have no meaning. |

The cluster-level default is controlled by `default_redpanda_storage_mode` (defaults to `unset`).

**Key behavior**: When `redpanda.storage.mode` is set to anything other than `unset`, the legacy `redpanda.remote.read` and `redpanda.remote.write` topic properties have **no effect** on the topic's storage permissions.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/)
- Docker
- Redpanda image: `redpandadata/redpanda-unstable:v26.1.1-rc3`

## Quick Start

```bash
# 1. Create kind cluster
./scripts/setup-cluster.sh

# 2. Deploy Redpanda with cloud storage (MinIO)
./scripts/deploy-redpanda.sh

# 3. Run all tests
./scripts/run-tests.sh
```

## Repository Structure

```
.
├── README.md                          # This file
├── TEST_PLAN.md                       # Detailed test plan and results
├── manifests/
│   ├── kind-config.yaml               # kind cluster configuration
│   ├── minio.yaml                     # MinIO deployment for S3-compatible storage
│   ├── cloud-storage-secret.yaml      # Kubernetes Secret for MinIO credentials
│   ├── redpanda-cluster.yaml          # Redpanda cluster CR (base config)
│   ├── redpanda-cluster-cloud.yaml    # Redpanda cluster CR with cloud_topics_enabled
│   └── topics/
│       ├── test-default-mode.yaml
│       ├── test-cloud-inherit.yaml
│       ├── test-cloud-override-local.yaml
│       ├── test-tiered-inherit.yaml
│       ├── test-local-inherit.yaml
│       ├── test-unset-legacy-tiered.yaml
│       ├── test-unset-legacy-local.yaml
│       ├── test-tiered-ignores-legacy.yaml
│       ├── test-local-ignores-legacy.yaml
│       └── test-cloud-ignores-legacy.yaml
└── scripts/
    ├── setup-cluster.sh               # Create kind cluster + cert-manager + operator
    ├── deploy-redpanda.sh             # Deploy MinIO + Redpanda cluster
    ├── run-tests.sh                   # Run all test scenarios
    └── cleanup.sh                     # Tear down kind cluster
```

## References

- [Redpanda PR #29352 - redpanda.storage.mode](https://github.com/redpanda-data/redpanda/pull/29352)
- [Redpanda Operator Local Guide](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/local-guide/)
- [Configure Helm Chart - Cluster Properties](https://docs.redpanda.com/current/manage/kubernetes/k-configure-helm-chart/#set-redpanda-cluster-properties)
