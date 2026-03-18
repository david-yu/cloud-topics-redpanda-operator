# Cloud Topics: The Hard Way

Manual, step-by-step guide for testing `redpanda.storage.mode` and `default_redpanda_storage_mode` using the Redpanda Kubernetes Operator. All cluster configuration is applied exclusively through Custom Resource objects. Topic configuration is verified by reading the Topic CR status via `kubectl`. Cluster configuration is verified via `rpk cluster config get` (read-only).

**No `rpk cluster config set` or `rpk topic` commands are used.** All mutations go through CRs.

## Prerequisites

- Docker running
- [kind](https://kind.sigs.k8s.io/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/) installed

---

## Conventions Used in This Guide

### Verifying topic configuration via the Topic CR status

The Topic controller writes the full topic configuration snapshot into `.status.topicConfiguration[]`. Each entry has `name`, `value`, and `source` fields. To inspect the storage-related properties of a topic:

```bash
kubectl get topic <TOPIC_NAME> -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Example output:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=cloud (DEFAULT_CONFIG)
```

The `source` field indicates where the value came from:
- `DEFAULT_CONFIG` - inherited from cluster defaults
- `DYNAMIC_TOPIC_CONFIG` - explicitly set on the topic

### Verifying cluster configuration

Cluster-level properties are verified (read-only) via:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get <PROPERTY_NAME>
```

### Waiting for Topic CR readiness

After applying a Topic CR, wait for reconciliation:

```bash
kubectl get topic <TOPIC_NAME> -n redpanda -w
```

Wait until `READY` shows `True`, then Ctrl-C. The `.status.topicConfiguration` is only populated after successful reconciliation.

---

## Part 1: Cluster Setup

### 1.1 Create the kind cluster

```bash
cat <<EOF > /tmp/kind-config.yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF

kind create cluster --config /tmp/kind-config.yaml --name redpanda-test
```

Verify nodes are ready:

```bash
kubectl get nodes
```

Expected output (4 nodes, all `Ready`):

```
NAME                          STATUS   ROLES           AGE   VERSION
redpanda-test-control-plane   Ready    control-plane   60s   v1.35.0
redpanda-test-worker          Ready    <none>          45s   v1.35.0
redpanda-test-worker2         Ready    <none>          45s   v1.35.0
redpanda-test-worker3         Ready    <none>          45s   v1.35.0
```

### 1.2 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --set crds.enabled=true \
  --namespace cert-manager \
  --create-namespace \
  --wait --timeout 3m
```

### 1.3 Install the Redpanda Operator

```bash
helm repo add redpanda https://charts.redpanda.com
helm repo update
helm upgrade --install redpanda-controller redpanda/operator \
  --namespace redpanda \
  --create-namespace \
  --version v25.3.1 \
  --set crds.enabled=true \
  --wait --timeout 3m
```

Verify the operator is running:

```bash
kubectl get pods -n redpanda
```

Expected:

```
NAME                                            READY   STATUS    RESTARTS   AGE
redpanda-controller-operator-6f7bfd6688-xxxxx   1/1     Running   0          30s
```

---

## Part 2: Deploy MinIO (S3-Compatible Object Storage)

Cloud and tiered storage modes require object storage. We use MinIO as a local S3-compatible store.

### 2.1 Deploy MinIO pod and service

```bash
kubectl apply -n redpanda -f - <<'EOF'
---
apiVersion: v1
kind: Pod
metadata:
  name: minio
  labels:
    app: minio
spec:
  containers:
    - name: minio
      image: minio/minio:latest
      args: ["server", "/data", "--console-address", ":9001"]
      env:
        - name: MINIO_ROOT_USER
          value: "minioadmin"
        - name: MINIO_ROOT_PASSWORD
          value: "minioadmin"
      ports:
        - containerPort: 9000
        - containerPort: 9001
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9001
      targetPort: 9001
      name: console
EOF
```

Wait for MinIO to be ready:

```bash
kubectl wait --for=condition=Ready pod/minio -n redpanda --timeout=120s
```

### 2.2 Create the S3 bucket

```bash
kubectl run minio-setup --rm -i --restart=Never -n redpanda \
  --image=minio/mc:latest \
  --command -- /bin/sh -c \
  "mc alias set local http://minio:9000 minioadmin minioadmin && mc mb local/redpanda-bucket"
```

Expected:

```
Added `local` successfully.
Bucket created successfully `local/redpanda-bucket`.
```

### 2.3 Create the credentials secret

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cloud-storage-creds
type: Opaque
stringData:
  access-key: minioadmin
  secret-key: minioadmin
EOF
```

---

## Part 3: Deploy Redpanda Cluster

### 3.1 Deploy the base Redpanda cluster

This deploys a 3-node Redpanda cluster with cloud storage enabled (pointing at MinIO) and `cloud_topics_enabled: true` in the cluster config. The default `default_redpanda_storage_mode` will be `unset`.

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: redpanda
spec:
  clusterSpec:
    image:
      repository: redpandadata/redpanda-unstable
      tag: v26.1.1-rc3
    statefulset:
      replicas: 3
      initContainers:
        setDataDirOwnership:
          enabled: true
    tls:
      enabled: false
    external:
      enabled: false
    auth:
      sasl:
        enabled: false
    storage:
      persistentVolume:
        enabled: true
        size: 5Gi
      tiered:
        mountType: none
        credentialsSecretRef:
          accessKey:
            name: cloud-storage-creds
            key: access-key
          secretKey:
            name: cloud-storage-creds
            key: secret-key
        config:
          cloud_storage_enabled: true
          cloud_storage_region: us-east-1
          cloud_storage_bucket: redpanda-bucket
          cloud_storage_api_endpoint: http://minio.redpanda.svc.cluster.local:9000
          cloud_storage_api_endpoint_port: 9000
          cloud_storage_disable_tls: true
          cloud_storage_credentials_source: config_file
    config:
      cluster:
        cloud_topics_enabled: true
EOF
```

Wait for all Redpanda pods to be ready:

```bash
kubectl wait --for=condition=Ready pod/redpanda-0 pod/redpanda-1 pod/redpanda-2 \
  -n redpanda --timeout=300s
```

Verify the cluster is healthy:

```bash
kubectl get redpanda -n redpanda
```

Expected:

```
NAME       READY   STATUS
redpanda   True    Cluster ready to service requests
```

### 3.2 Activate `cloud_topics_enabled`

The base cluster config includes `cloud_topics_enabled: true`, but this property requires a broker restart to take effect. Trigger a rolling restart:

```bash
kubectl rollout restart statefulset redpanda -n redpanda
```

Wait for all pods to come back:

```bash
kubectl wait --for=condition=Ready pod/redpanda-0 pod/redpanda-1 pod/redpanda-2 \
  -n redpanda --timeout=300s
```

Verify `cloud_topics_enabled` is active:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get cloud_topics_enabled
```

Expected:

```
true
```

### 3.3 Verify default cluster storage mode

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

Expected:

```
unset
```

---

## Part 4: Test Cases

### Test 1: Default cluster storage mode is `unset`

Already verified in step 3.2 above.

**Result: PASS** - `default_redpanda_storage_mode` defaults to `unset`.

---

### Test 2: Topic with default settings inherits `storage.mode=unset`

Apply the Topic CR:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-default-mode
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready:

```bash
kubectl get topic test-default-mode -n redpanda -w
```

Once `READY` is `True`, verify via the Topic CR status:

```bash
kubectl get topic test-default-mode -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=unset (DEFAULT_CONFIG)
```

**Result: PASS** - Topic inherits `unset` from cluster default. Legacy `remote.read`/`remote.write` are `true` from cluster defaults.

---

### Test 3: Set `default_redpanda_storage_mode=cloud` via the Redpanda CR

Update the CR to set the default storage mode to `cloud`:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: redpanda
spec:
  clusterSpec:
    image:
      repository: redpandadata/redpanda-unstable
      tag: v26.1.1-rc3
    statefulset:
      replicas: 3
      initContainers:
        setDataDirOwnership:
          enabled: true
    tls:
      enabled: false
    external:
      enabled: false
    auth:
      sasl:
        enabled: false
    storage:
      persistentVolume:
        enabled: true
        size: 5Gi
      tiered:
        mountType: none
        credentialsSecretRef:
          accessKey:
            name: cloud-storage-creds
            key: access-key
          secretKey:
            name: cloud-storage-creds
            key: secret-key
        config:
          cloud_storage_enabled: true
          cloud_storage_region: us-east-1
          cloud_storage_bucket: redpanda-bucket
          cloud_storage_api_endpoint: http://minio.redpanda.svc.cluster.local:9000
          cloud_storage_api_endpoint_port: 9000
          cloud_storage_disable_tls: true
          cloud_storage_credentials_source: config_file
    config:
      cluster:
        cloud_topics_enabled: true
        default_redpanda_storage_mode: cloud
EOF
```

Wait for reconciliation:

```bash
kubectl get redpanda -n redpanda -w
```

Wait until READY is `True`, then Ctrl-C.

Verify the config was applied:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

Expected:

```
cloud
```

Also check the Redpanda CR status to confirm no configuration errors:

```bash
kubectl get redpanda redpanda -n redpanda -o jsonpath='{range .status.conditions[?(@.type=="ConfigurationApplied")]}{.type}: {.status} ({.reason}){"\n"}{end}'
```

Expected:

```
ConfigurationApplied: True (Synced)
```

---

### Test 4: Topic inherits `cloud` from cluster default

Create a topic without specifying `redpanda.storage.mode`:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-cloud-inherit
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready:

```bash
kubectl get topic test-cloud-inherit -n redpanda -w
```

Verify via the Topic CR status:

```bash
kubectl get topic test-cloud-inherit -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=cloud (DEFAULT_CONFIG)
```

**Result: PASS** - Topic inherited `cloud` from the cluster's `default_redpanda_storage_mode`. The source is `DEFAULT_CONFIG`, confirming it came from the cluster default, not an explicit topic-level setting.

---

### Test 5: Topic-level override - cluster=cloud, topic=local

Create a topic that explicitly sets `redpanda.storage.mode=local` while the cluster default is `cloud`:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-cloud-override-local
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.storage.mode: "local"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-cloud-override-local -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=local (DYNAMIC_TOPIC_CONFIG)
```

**Result: PASS** - Topic-level `local` overrides cluster `cloud` default. Source is `DYNAMIC_TOPIC_CONFIG` confirming it was set explicitly on the topic.

---

### Test 6: Set `default_redpanda_storage_mode=tiered` via CR and verify topic inheritance

Update the Redpanda CR:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: redpanda
spec:
  clusterSpec:
    image:
      repository: redpandadata/redpanda-unstable
      tag: v26.1.1-rc3
    statefulset:
      replicas: 3
      initContainers:
        setDataDirOwnership:
          enabled: true
    tls:
      enabled: false
    external:
      enabled: false
    auth:
      sasl:
        enabled: false
    storage:
      persistentVolume:
        enabled: true
        size: 5Gi
      tiered:
        mountType: none
        credentialsSecretRef:
          accessKey:
            name: cloud-storage-creds
            key: access-key
          secretKey:
            name: cloud-storage-creds
            key: secret-key
        config:
          cloud_storage_enabled: true
          cloud_storage_region: us-east-1
          cloud_storage_bucket: redpanda-bucket
          cloud_storage_api_endpoint: http://minio.redpanda.svc.cluster.local:9000
          cloud_storage_api_endpoint_port: 9000
          cloud_storage_disable_tls: true
          cloud_storage_credentials_source: config_file
    config:
      cluster:
        cloud_topics_enabled: true
        default_redpanda_storage_mode: tiered
EOF
```

Wait for reconciliation, then verify the cluster config:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

Expected: `tiered`

Create a topic:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-tiered-inherit
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-tiered-inherit -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=tiered (DEFAULT_CONFIG)
```

**Result: PASS** - Topic inherited `tiered` from cluster default.

---

### Test 7: Set `default_redpanda_storage_mode=local` via CR and verify topic inheritance

Update the Redpanda CR (change only the `default_redpanda_storage_mode` line):

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: redpanda
spec:
  clusterSpec:
    image:
      repository: redpandadata/redpanda-unstable
      tag: v26.1.1-rc3
    statefulset:
      replicas: 3
      initContainers:
        setDataDirOwnership:
          enabled: true
    tls:
      enabled: false
    external:
      enabled: false
    auth:
      sasl:
        enabled: false
    storage:
      persistentVolume:
        enabled: true
        size: 5Gi
      tiered:
        mountType: none
        credentialsSecretRef:
          accessKey:
            name: cloud-storage-creds
            key: access-key
          secretKey:
            name: cloud-storage-creds
            key: secret-key
        config:
          cloud_storage_enabled: true
          cloud_storage_region: us-east-1
          cloud_storage_bucket: redpanda-bucket
          cloud_storage_api_endpoint: http://minio.redpanda.svc.cluster.local:9000
          cloud_storage_api_endpoint_port: 9000
          cloud_storage_disable_tls: true
          cloud_storage_credentials_source: config_file
    config:
      cluster:
        cloud_topics_enabled: true
        default_redpanda_storage_mode: local
EOF
```

Wait for reconciliation, then verify the cluster config:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

Expected: `local`

Create a topic:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-local-inherit
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-local-inherit -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=local (DEFAULT_CONFIG)
```

**Result: PASS** - Topic inherited `local` from cluster default.

---

### Test 8: Set `default_redpanda_storage_mode=unset` via CR (reset to default)

Update the Redpanda CR to reset the storage mode back to `unset`:

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: redpanda
spec:
  clusterSpec:
    image:
      repository: redpandadata/redpanda-unstable
      tag: v26.1.1-rc3
    statefulset:
      replicas: 3
      initContainers:
        setDataDirOwnership:
          enabled: true
    tls:
      enabled: false
    external:
      enabled: false
    auth:
      sasl:
        enabled: false
    storage:
      persistentVolume:
        enabled: true
        size: 5Gi
      tiered:
        mountType: none
        credentialsSecretRef:
          accessKey:
            name: cloud-storage-creds
            key: access-key
          secretKey:
            name: cloud-storage-creds
            key: secret-key
        config:
          cloud_storage_enabled: true
          cloud_storage_region: us-east-1
          cloud_storage_bucket: redpanda-bucket
          cloud_storage_api_endpoint: http://minio.redpanda.svc.cluster.local:9000
          cloud_storage_api_endpoint_port: 9000
          cloud_storage_disable_tls: true
          cloud_storage_credentials_source: config_file
    config:
      cluster:
        cloud_topics_enabled: true
        default_redpanda_storage_mode: unset
EOF
```

Wait for reconciliation, then verify:

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

Expected: `unset`

**Result: PASS** - Cluster storage mode successfully reset to `unset`.

---

### Test 9: Legacy `remote.read`/`remote.write` behavior when `storage.mode=unset`

**These tests are not part of the core `redpanda.storage.mode` validation. They are included only to demonstrate backwards compatibility with the legacy `redpanda.remote.read` and `redpanda.remote.write` topic properties, which predate the `redpanda.storage.mode` feature.**

When `redpanda.storage.mode=unset`, the legacy `remote.read`/`remote.write` properties continue to control a topic's tiered storage permissions, preserving the pre-`storage.mode` behavior.

#### Test 9a: Legacy tiered - `remote.read=true`, `remote.write=true`

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-unset-legacy-tiered
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.remote.read: "true"
    redpanda.remote.write: "true"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-unset-legacy-tiered -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=unset (DEFAULT_CONFIG)
```

**Result: PASS** - With `storage.mode=unset`, `remote.read=true` and `remote.write=true` enable tiered storage via the legacy mechanism.

#### Test 9b: Legacy local - `remote.read=false`, `remote.write=false`

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-unset-legacy-local
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.remote.read: "false"
    redpanda.remote.write: "false"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-unset-legacy-local -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=false (DYNAMIC_TOPIC_CONFIG)
redpanda.remote.write=false (DYNAMIC_TOPIC_CONFIG)
redpanda.storage.mode=unset (DEFAULT_CONFIG)
```

**Result: PASS** - With `storage.mode=unset`, `remote.read=false` and `remote.write=false` disable tiered storage via the legacy mechanism. Source is `DYNAMIC_TOPIC_CONFIG` because these values were explicitly set on the topic, overriding the cluster defaults of `true`.

---

### Test 10: `storage.mode` takes precedence over legacy `remote.read`/`remote.write`

**These tests are not part of the core `redpanda.storage.mode` validation. They are included only to demonstrate backwards compatibility: when `redpanda.storage.mode` is explicitly set to any non-`unset` value, the legacy `redpanda.remote.read`/`redpanda.remote.write` properties have no effect on the topic's actual storage behavior.**

#### Test 10a: `storage.mode=tiered` ignores `remote.read/write=false`

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-tiered-ignores-legacy
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.storage.mode: "tiered"
    redpanda.remote.read: "false"
    redpanda.remote.write: "false"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-tiered-ignores-legacy -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=false (DYNAMIC_TOPIC_CONFIG)
redpanda.remote.write=false (DYNAMIC_TOPIC_CONFIG)
redpanda.storage.mode=tiered (DYNAMIC_TOPIC_CONFIG)
```

**Result: PASS** - `storage.mode=tiered` takes precedence. Although `remote.read/write` show as `false`, the topic operates as a tiered storage topic because `storage.mode=tiered` governs the behavior.

#### Test 10b: `storage.mode=local` ignores `remote.read/write=true`

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-local-ignores-legacy
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.storage.mode: "local"
    redpanda.remote.read: "true"
    redpanda.remote.write: "true"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-local-ignores-legacy -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=true (DEFAULT_CONFIG)
redpanda.remote.write=true (DEFAULT_CONFIG)
redpanda.storage.mode=local (DYNAMIC_TOPIC_CONFIG)
```

**Result: PASS** - `storage.mode=local` takes precedence. Although `remote.read/write` show as `true` (from cluster defaults), the topic operates as a local-only topic.

#### Test 10c: `storage.mode=cloud` ignores `remote.read/write=false`

```bash
kubectl apply -n redpanda -f - <<'EOF'
apiVersion: cluster.redpanda.com/v1alpha2
kind: Topic
metadata:
  name: test-cloud-ignores-legacy
  namespace: redpanda
spec:
  partitions: 1
  replicationFactor: 3
  additionalConfig:
    redpanda.storage.mode: "cloud"
    redpanda.remote.read: "false"
    redpanda.remote.write: "false"
  cluster:
    clusterRef:
      name: redpanda
EOF
```

Wait for the topic to be ready, then verify:

```bash
kubectl get topic test-cloud-ignores-legacy -n redpanda -o jsonpath='{range .status.topicConfiguration[*]}{.name}={.value} ({.source}){"\n"}{end}' | grep -E "storage\.mode|remote\.read|remote\.write"
```

Expected:

```
redpanda.remote.read=false (DYNAMIC_TOPIC_CONFIG)
redpanda.remote.write=false (DYNAMIC_TOPIC_CONFIG)
redpanda.storage.mode=cloud (DYNAMIC_TOPIC_CONFIG)
```

**Result: PASS** - `storage.mode=cloud` takes precedence. Cloud Topics use a completely different storage framework; `remote.read/write` are meaningless in this mode.

---

## Results Summary

| # | Test Case | Storage Mode | Source | Result |
|---|-----------|-------------|--------|--------|
| 1 | Default `default_redpanda_storage_mode` | `unset` | cluster config | **PASS** |
| 2 | Topic with no explicit storage mode | `unset` | `DEFAULT_CONFIG` | **PASS** |
| 3 | Set `default_redpanda_storage_mode=cloud` via CR | `cloud` | cluster config | **PASS** |
| 4 | Topic inherits `cloud` from cluster | `cloud` | `DEFAULT_CONFIG` | **PASS** |
| 5 | Topic overrides cluster `cloud` with `local` | `local` | `DYNAMIC_TOPIC_CONFIG` | **PASS** |
| 6 | Cluster `default_redpanda_storage_mode=tiered` via CR, topic inherits | `tiered` | `DEFAULT_CONFIG` | **PASS** |
| 7 | Cluster `default_redpanda_storage_mode=local` via CR, topic inherits | `local` | `DEFAULT_CONFIG` | **PASS** |
| 8 | Reset `default_redpanda_storage_mode=unset` via CR | `unset` | cluster config | **PASS** |
| 9a | *(Backwards compat)* `unset` + `remote.read/write=true` | `unset` | `DEFAULT_CONFIG` | **PASS** |
| 9b | *(Backwards compat)* `unset` + `remote.read/write=false` | `unset` | `DYNAMIC_TOPIC_CONFIG` | **PASS** |
| 10a | *(Backwards compat)* `tiered` ignores `remote.read/write=false` | `tiered` | `DYNAMIC_TOPIC_CONFIG` | **PASS** |
| 10b | *(Backwards compat)* `local` ignores `remote.read/write=true` | `local` | `DYNAMIC_TOPIC_CONFIG` | **PASS** |
| 10c | *(Backwards compat)* `cloud` ignores `remote.read/write=false` | `cloud` | `DYNAMIC_TOPIC_CONFIG` | **PASS** |

**All 13 tests passed.**

---

## Storage Mode Behavior Summary

| `redpanda.storage.mode` | Behavior | `remote.read`/`remote.write` relevance |
|--------------------------|----------|----------------------------------------|
| `unset` | Legacy mode | **Controls** tiered storage permissions |
| `local` | Local-only storage | **Ignored** |
| `tiered` | Tiered storage (read+write to object store) | **Ignored** |
| `cloud` | Cloud Topics infrastructure | **Ignored** |

---

## Cleanup

Delete all test topics:

```bash
kubectl delete topics --all -n redpanda
```

Delete the kind cluster:

```bash
kind delete cluster --name redpanda-test
```
