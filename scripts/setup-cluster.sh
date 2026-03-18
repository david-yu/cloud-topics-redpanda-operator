#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NAMESPACE="redpanda"
CLUSTER_NAME="redpanda-test"

echo "=== Step 1: Create kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${MANIFESTS_DIR}/kind-config.yaml" --name "${CLUSTER_NAME}"
fi

echo ""
echo "=== Step 2: Install cert-manager ==="
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager \
  --set crds.enabled=true \
  --namespace cert-manager \
  --create-namespace \
  --wait --timeout 3m

echo ""
echo "=== Step 3: Install Redpanda Operator ==="
helm repo add redpanda https://charts.redpanda.com 2>/dev/null || true
helm repo update redpanda
helm upgrade --install redpanda-controller redpanda/operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version v25.3.1 \
  --set crds.enabled=true \
  --wait --timeout 3m

echo ""
echo "=== Cluster setup complete ==="
kubectl get nodes
