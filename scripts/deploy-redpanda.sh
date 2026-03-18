#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NAMESPACE="redpanda"

echo "=== Step 1: Deploy MinIO ==="
kubectl apply -n "${NAMESPACE}" -f "${MANIFESTS_DIR}/minio.yaml"
echo "Waiting for MinIO to be ready..."
kubectl wait --for=condition=Ready pod/minio -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Step 2: Create S3 bucket ==="
kubectl run minio-setup --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=minio/mc:latest \
  --command -- /bin/sh -c \
  "mc alias set local http://minio:9000 minioadmin minioadmin && mc mb --ignore-existing local/redpanda-bucket"

echo ""
echo "=== Step 3: Create cloud storage credentials secret ==="
kubectl apply -n "${NAMESPACE}" -f "${MANIFESTS_DIR}/cloud-storage-secret.yaml"

echo ""
echo "=== Step 4: Deploy Redpanda cluster ==="
kubectl apply -n "${NAMESPACE}" -f "${MANIFESTS_DIR}/redpanda-cluster.yaml"

echo ""
echo "Waiting for Redpanda pods to be ready (this may take a few minutes)..."
kubectl wait --for=condition=Ready pod/redpanda-0 pod/redpanda-1 pod/redpanda-2 \
  -n "${NAMESPACE}" --timeout=300s

echo ""
echo "=== Step 5: Enable cloud_topics_enabled ==="
kubectl apply -n "${NAMESPACE}" -f "${MANIFESTS_DIR}/redpanda-cluster-cloud.yaml"

echo "Waiting for operator reconciliation..."
sleep 30

echo "Restarting Redpanda pods for cloud_topics_enabled to take effect..."
kubectl rollout restart statefulset redpanda -n "${NAMESPACE}"
sleep 60

echo "Waiting for pods to be ready after restart..."
kubectl wait --for=condition=Ready pod/redpanda-0 pod/redpanda-1 pod/redpanda-2 \
  -n "${NAMESPACE}" --timeout=300s

echo ""
echo "=== Verifying cloud_topics_enabled ==="
kubectl exec -n "${NAMESPACE}" redpanda-0 -c redpanda -- rpk cluster config get cloud_topics_enabled

echo ""
echo "=== Redpanda deployment complete ==="
kubectl get pods -n "${NAMESPACE}"
