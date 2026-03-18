#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPICS_DIR="${SCRIPT_DIR}/../manifests/topics"
NAMESPACE="redpanda"
PASS=0
FAIL=0

rpk_exec() {
  kubectl exec -n "${NAMESPACE}" redpanda-0 -c redpanda -- rpk "$@"
}

set_cluster_storage_mode() {
  local mode="$1"
  rpk_exec cluster config set default_redpanda_storage_mode "${mode}" > /dev/null 2>&1
  echo "  Set default_redpanda_storage_mode=${mode}"
}

create_topic() {
  local file="$1"
  kubectl apply -n "${NAMESPACE}" -f "${file}" > /dev/null 2>&1
  sleep 8  # Wait for topic controller reconciliation
}

get_topic_config() {
  local topic="$1"
  local key="$2"
  rpk_exec topic describe "${topic}" -c 2>/dev/null | grep "${key}" | awk '{print $2}'
}

get_topic_config_source() {
  local topic="$1"
  local key="$2"
  rpk_exec topic describe "${topic}" -c 2>/dev/null | grep "${key}" | awk '{print $3}'
}

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  PASS: ${test_name} (expected=${expected}, got=${actual})"
    ((PASS++))
  else
    echo "  FAIL: ${test_name} (expected=${expected}, got=${actual})"
    ((FAIL++))
  fi
}

delete_test_topics() {
  kubectl delete topics --all -n "${NAMESPACE}" > /dev/null 2>&1 || true
  sleep 5
}

echo "=============================================="
echo " Cloud Topics Storage Mode - Test Suite"
echo "=============================================="
echo ""

# Clean up any existing test topics
delete_test_topics

# -----------------------------------------------
echo "--- Test 1: Default cluster storage mode ---"
actual=$(rpk_exec cluster config get default_redpanda_storage_mode 2>/dev/null | tr -d '[:space:]')
# Reset to unset in case it was changed
if [[ "${actual}" != "unset" ]]; then
  set_cluster_storage_mode unset
  actual="unset"
fi
assert_eq "default_redpanda_storage_mode default" "unset" "${actual}"
echo ""

# -----------------------------------------------
echo "--- Test 2: Topic with default settings ---"
create_topic "${TOPICS_DIR}/test-default-mode.yaml"
mode=$(get_topic_config test-default-mode "redpanda.storage.mode")
assert_eq "storage.mode" "unset" "${mode}"
echo ""

# -----------------------------------------------
echo "--- Test 3: Topic inherits cloud from cluster ---"
set_cluster_storage_mode cloud
create_topic "${TOPICS_DIR}/test-cloud-inherit.yaml"
mode=$(get_topic_config test-cloud-inherit "redpanda.storage.mode")
source=$(get_topic_config_source test-cloud-inherit "redpanda.storage.mode")
assert_eq "storage.mode" "cloud" "${mode}"
assert_eq "storage.mode source" "DEFAULT_CONFIG" "${source}"
echo ""

# -----------------------------------------------
echo "--- Test 4: Topic overrides cloud with local ---"
create_topic "${TOPICS_DIR}/test-cloud-override-local.yaml"
mode=$(get_topic_config test-cloud-override-local "redpanda.storage.mode")
source=$(get_topic_config_source test-cloud-override-local "redpanda.storage.mode")
assert_eq "storage.mode" "local" "${mode}"
assert_eq "storage.mode source" "DYNAMIC_TOPIC_CONFIG" "${source}"
echo ""

# -----------------------------------------------
echo "--- Test 5: Topic inherits tiered from cluster ---"
set_cluster_storage_mode tiered
create_topic "${TOPICS_DIR}/test-tiered-inherit.yaml"
mode=$(get_topic_config test-tiered-inherit "redpanda.storage.mode")
assert_eq "storage.mode" "tiered" "${mode}"
echo ""

# -----------------------------------------------
echo "--- Test 6: Topic inherits local from cluster ---"
set_cluster_storage_mode local
create_topic "${TOPICS_DIR}/test-local-inherit.yaml"
mode=$(get_topic_config test-local-inherit "redpanda.storage.mode")
assert_eq "storage.mode" "local" "${mode}"
echo ""

# -----------------------------------------------
echo "--- Test 7a: Legacy tiered (unset + remote.read/write=true) ---"
set_cluster_storage_mode unset
create_topic "${TOPICS_DIR}/test-unset-legacy-tiered.yaml"
mode=$(get_topic_config test-unset-legacy-tiered "redpanda.storage.mode")
read_val=$(get_topic_config test-unset-legacy-tiered "redpanda.remote.read")
write_val=$(get_topic_config test-unset-legacy-tiered "redpanda.remote.write")
assert_eq "storage.mode" "unset" "${mode}"
assert_eq "remote.read" "true" "${read_val}"
assert_eq "remote.write" "true" "${write_val}"
echo ""

# -----------------------------------------------
echo "--- Test 7b: Legacy local (unset + remote.read/write=false) ---"
create_topic "${TOPICS_DIR}/test-unset-legacy-local.yaml"
mode=$(get_topic_config test-unset-legacy-local "redpanda.storage.mode")
read_val=$(get_topic_config test-unset-legacy-local "redpanda.remote.read")
write_val=$(get_topic_config test-unset-legacy-local "redpanda.remote.write")
assert_eq "storage.mode" "unset" "${mode}"
assert_eq "remote.read" "false" "${read_val}"
assert_eq "remote.write" "false" "${write_val}"
echo ""

# -----------------------------------------------
echo "--- Test 8a: storage.mode=tiered ignores remote.read/write=false ---"
create_topic "${TOPICS_DIR}/test-tiered-ignores-legacy.yaml"
mode=$(get_topic_config test-tiered-ignores-legacy "redpanda.storage.mode")
assert_eq "storage.mode" "tiered" "${mode}"
echo ""

# -----------------------------------------------
echo "--- Test 8b: storage.mode=local ignores remote.read/write=true ---"
create_topic "${TOPICS_DIR}/test-local-ignores-legacy.yaml"
mode=$(get_topic_config test-local-ignores-legacy "redpanda.storage.mode")
assert_eq "storage.mode" "local" "${mode}"
echo ""

# -----------------------------------------------
echo "--- Test 8c: storage.mode=cloud ignores remote.read/write=false ---"
create_topic "${TOPICS_DIR}/test-cloud-ignores-legacy.yaml"
mode=$(get_topic_config test-cloud-ignores-legacy "redpanda.storage.mode")
assert_eq "storage.mode" "cloud" "${mode}"
echo ""

# -----------------------------------------------
echo "=============================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "=============================================="

if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
