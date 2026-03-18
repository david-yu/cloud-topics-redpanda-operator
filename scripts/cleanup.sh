#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="redpanda-test"

echo "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
