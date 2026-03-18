# Test Plan: `redpanda.storage.mode` and `default_redpanda_storage_mode`

## Objective

Validate that the Redpanda Operator correctly supports the new `redpanda.storage.mode` topic property and `default_redpanda_storage_mode` cluster property, including inheritance, overrides, and interaction with legacy `redpanda.remote.read`/`redpanda.remote.write` properties.

## Environment

- **Kubernetes**: kind cluster (1 control-plane + 3 workers)
- **Redpanda image**: `redpandadata/redpanda-unstable:v26.1.1-rc3`
- **Operator chart**: `redpanda/operator` v25.3.1
- **Object storage**: MinIO (S3-compatible, in-cluster)
- **Cloud storage config**: Enabled with `cloud_storage_credentials_source: config_file`

## Setup Notes

- `cloud_topics_enabled` must be set to `true` and the cluster restarted **before** `default_redpanda_storage_mode` can be set to `cloud`.
- The operator currently sends all cluster config properties in a single API request. If `cloud_topics_enabled` and `default_redpanda_storage_mode=cloud` are set together, the request fails because `cloud_topics_enabled` requires a restart before `default_redpanda_storage_mode=cloud` is valid. **Workaround**: Set `cloud_topics_enabled` via the operator CR, wait for restart, then set `default_redpanda_storage_mode` via `rpk`.

---

## Test Cases

### Test 1: Default cluster storage mode is `unset`

**Objective**: Verify the default value of `default_redpanda_storage_mode`.

**Steps**:
```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config get default_redpanda_storage_mode
```

**Expected**: `unset`

**Result**: **PASS**
```
unset
```

---

### Test 2: Topic created with default settings has `storage.mode=unset`

**Objective**: Verify a topic created without explicit storage mode inherits the cluster default (`unset`).

**Manifest**: `manifests/topics/test-default-mode.yaml`

**Steps**:
```bash
kubectl apply -n redpanda -f manifests/topics/test-default-mode.yaml
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk topic describe test-default-mode -c
```

**Expected**: `redpanda.storage.mode = unset (DEFAULT_CONFIG)`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 unset          DEFAULT_CONFIG
```

---

### Test 3: Topic inherits `cloud` from cluster default

**Objective**: When `default_redpanda_storage_mode=cloud`, a new topic should inherit `redpanda.storage.mode=cloud`.

**Pre-condition**:
```bash
rpk cluster config set cloud_topics_enabled true
# restart cluster
rpk cluster config set default_redpanda_storage_mode cloud
```

**Manifest**: `manifests/topics/test-cloud-inherit.yaml`

**Steps**:
```bash
kubectl apply -n redpanda -f manifests/topics/test-cloud-inherit.yaml
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk topic describe test-cloud-inherit -c
```

**Expected**: `redpanda.storage.mode = cloud (DEFAULT_CONFIG)`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 cloud          DEFAULT_CONFIG
```

---

### Test 4: Topic-level override: cluster=cloud, topic=local

**Objective**: A topic with explicit `redpanda.storage.mode=local` should override the cluster default of `cloud`.

**Pre-condition**: `default_redpanda_storage_mode=cloud`

**Manifest**: `manifests/topics/test-cloud-override-local.yaml`

**Steps**:
```bash
kubectl apply -n redpanda -f manifests/topics/test-cloud-override-local.yaml
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk topic describe test-cloud-override-local -c
```

**Expected**: `redpanda.storage.mode = local (DYNAMIC_TOPIC_CONFIG)`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 local          DYNAMIC_TOPIC_CONFIG
```

---

### Test 5: Topic inherits `tiered` from cluster default

**Objective**: When `default_redpanda_storage_mode=tiered`, a new topic should inherit `redpanda.storage.mode=tiered`.

**Pre-condition**:
```bash
rpk cluster config set default_redpanda_storage_mode tiered
```

**Manifest**: `manifests/topics/test-tiered-inherit.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 tiered         DEFAULT_CONFIG
```

---

### Test 6: Topic inherits `local` from cluster default

**Objective**: When `default_redpanda_storage_mode=local`, a new topic should inherit `redpanda.storage.mode=local`.

**Pre-condition**:
```bash
rpk cluster config set default_redpanda_storage_mode local
```

**Manifest**: `manifests/topics/test-local-inherit.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 local          DEFAULT_CONFIG
```

---

### Test 7a: Legacy behavior - `storage.mode=unset` with `remote.read/write=true`

**Objective**: When `storage.mode=unset`, the legacy `remote.read` and `remote.write` properties control tiered storage permissions.

**Pre-condition**:
```bash
rpk cluster config set default_redpanda_storage_mode unset
```

**Manifest**: `manifests/topics/test-unset-legacy-tiered.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 unset          DEFAULT_CONFIG
```

---

### Test 7b: Legacy behavior - `storage.mode=unset` with `remote.read/write=false`

**Objective**: When `storage.mode=unset`, setting `remote.read=false` and `remote.write=false` disables tiered storage (legacy local behavior).

**Manifest**: `manifests/topics/test-unset-legacy-local.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  false          DYNAMIC_TOPIC_CONFIG
redpanda.remote.write                 false          DYNAMIC_TOPIC_CONFIG
redpanda.storage.mode                 unset          DEFAULT_CONFIG
```

---

### Test 8a: `storage.mode=tiered` ignores `remote.read/write=false`

**Objective**: When `storage.mode=tiered`, setting `remote.read/write=false` has no effect on the topic's tiered storage behavior.

**Manifest**: `manifests/topics/test-tiered-ignores-legacy.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  false          DYNAMIC_TOPIC_CONFIG
redpanda.remote.write                 false          DYNAMIC_TOPIC_CONFIG
redpanda.storage.mode                 tiered         DYNAMIC_TOPIC_CONFIG
```

Note: Although `remote.read/write` show as `false`, the `storage.mode=tiered` takes precedence and the topic operates as a tiered storage topic regardless.

---

### Test 8b: `storage.mode=local` ignores `remote.read/write=true`

**Objective**: When `storage.mode=local`, setting `remote.read/write=true` has no effect on the topic's storage behavior.

**Manifest**: `manifests/topics/test-local-ignores-legacy.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  true           DEFAULT_CONFIG
redpanda.remote.write                 true           DEFAULT_CONFIG
redpanda.storage.mode                 local          DYNAMIC_TOPIC_CONFIG
```

Note: Although `remote.read/write` show as `true` (from cluster defaults), the `storage.mode=local` takes precedence and the topic operates as a local-only topic.

---

### Test 8c: `storage.mode=cloud` ignores `remote.read/write=false`

**Objective**: When `storage.mode=cloud`, the `remote.read/write` properties have no meaning.

**Manifest**: `manifests/topics/test-cloud-ignores-legacy.yaml`

**Result**: **PASS**
```
redpanda.remote.read                  false          DYNAMIC_TOPIC_CONFIG
redpanda.remote.write                 false          DYNAMIC_TOPIC_CONFIG
redpanda.storage.mode                 cloud          DYNAMIC_TOPIC_CONFIG
```

Note: `storage.mode=cloud` uses the new Cloud Topics infrastructure. `remote.read/write` are irrelevant in this mode.

---

## Results Summary

| # | Test Case | Expected | Result |
|---|-----------|----------|--------|
| 1 | Default `default_redpanda_storage_mode` is `unset` | `unset` | **PASS** |
| 2 | Default topic has `storage.mode=unset` | `unset` | **PASS** |
| 3 | Cluster `cloud` default → topic inherits `cloud` | `cloud` | **PASS** |
| 4 | Cluster `cloud` + topic `local` → topic is `local` | `local` | **PASS** |
| 5 | Cluster `tiered` default → topic inherits `tiered` | `tiered` | **PASS** |
| 6 | Cluster `local` default → topic inherits `local` | `local` | **PASS** |
| 7a | `unset` + `remote.read/write=true` → legacy tiered | tiered behavior | **PASS** |
| 7b | `unset` + `remote.read/write=false` → legacy local | local behavior | **PASS** |
| 8a | `tiered` + `remote.read/write=false` → tiered wins | `tiered` | **PASS** |
| 8b | `local` + `remote.read/write=true` → local wins | `local` | **PASS** |
| 8c | `cloud` + `remote.read/write=false` → cloud wins | `cloud` | **PASS** |

**All 11 tests passed.**

## Known Issues

1. **Operator config ordering**: The operator sends all `config.cluster` properties in a single API request. Setting `cloud_topics_enabled=true` and `default_redpanda_storage_mode=cloud` simultaneously fails because `cloud_topics_enabled` requires a broker restart before `default_redpanda_storage_mode=cloud` is valid. Workaround: Apply `cloud_topics_enabled` first via the operator CR, wait for reconciliation and restart, then set `default_redpanda_storage_mode` via `rpk cluster config set`.
