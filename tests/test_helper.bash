#!/usr/bin/env bash

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${PROJECT_DIR}/audit-shared-drive-content.sh"
REMOVE_SCRIPT="${PROJECT_DIR}/remove-drive-sharing.sh"
ORIGINAL_PATH="${PATH}"

assert_eq() {
  local expected="$1"
  local actual="$2"

  if [[ "${expected}" != "${actual}" ]]; then
    printf 'expected %s, got %s\n' "${expected}" "${actual}" >&2
    return 1
  fi
}

assert_file_exists() {
  local target="$1"

  [[ -f "${target}" ]]
}

assert_file_contains() {
  local target="$1"
  local needle="$2"

  grep -Fq -- "${needle}" "${target}"
}

assert_file_not_contains() {
  local target="$1"
  local needle="$2"

  if grep -Fq -- "${needle}" "${target}"; then
    printf 'did not expect to find %s in %s\n' "${needle}" "${target}" >&2
    return 1
  fi
}

duckdb_scalar() {
  local sql="$1"

  duckdb -csv -c "${sql}" | tail -n +2 | tr -d '\r'
}

summary_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^- ${key}=//p" "${file}"
}

write_fake_gws() {
  local target="$1"

  cat > "${target}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

params='{}'
args=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --params|--json)
      params="$2"
      shift 2
      ;;
    --page-all|--dry-run)
      shift
      ;;
    --format|--api-version|--output|-o|--upload|--upload-content-type|--page-limit|--page-delay|--sanitize)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cmd="${args[*]}"

if [[ -n "${FAKE_GWS_LOG_FILE:-}" ]]; then
  printf '%s\t%s\n' "${cmd}" "${params}" >> "${FAKE_GWS_LOG_FILE}"
fi

profile="${FAKE_GWS_PROFILE:-default}"

if [[ "${profile}" == "auth-failure" && "${cmd}" == "drive about get"* ]]; then
  printf 'mock auth failure\n' >&2
  exit 2
fi

if [[ "${cmd}" == "drive about get"* ]]; then
  printf '%s\n' '{"user":{"displayName":"Audit Admin","emailAddress":"admin@example.com"}}'
  exit 0
fi

if [[ "${cmd}" == "drive drives list"* ]]; then
  printf '%s\n' '{"drives":[{"id":"drive-alpha","name":"Operations"}]}'
  exit 0
fi

if [[ "${cmd}" == "drive files list"* ]]; then
  drive_id="$(jq -r '.driveId // empty' <<<"${params}")"
  if [[ "${drive_id}" == "drive-alpha" ]]; then
    printf '%s\n' '{"files":[{"id":"folder-1","name":"Shared folder","mimeType":"application/vnd.google-apps.folder","parents":[],"driveId":"drive-alpha","webViewLink":"https://example.com/folder-1","createdTime":"2026-03-01T00:00:00Z","modifiedTime":"2026-03-05T00:00:00Z","hasAugmentedPermissions":true,"inheritedPermissionsDisabled":false},{"id":"file-1","name":"Quarterly plan","mimeType":"application/vnd.google-apps.document","parents":["folder-1"],"driveId":"drive-alpha","webViewLink":"https://example.com/file-1","createdTime":"2026-03-02T00:00:00Z","modifiedTime":"2026-03-06T00:00:00Z","size":"1024","hasAugmentedPermissions":true,"inheritedPermissionsDisabled":false},{"id":"file-2","name":"Internal notes","mimeType":"application/vnd.google-apps.document","parents":["folder-1"],"driveId":"drive-alpha","webViewLink":"https://example.com/file-2","createdTime":"2026-03-03T00:00:00Z","modifiedTime":"2026-03-07T00:00:00Z","size":"2048","hasAugmentedPermissions":false,"inheritedPermissionsDisabled":false}]}'
  else
    printf '%s\n' '{"files":[]}'
  fi
  exit 0
fi

if [[ "${cmd}" == "drive permissions list"* ]]; then
  file_id="$(jq -r '.fileId // empty' <<<"${params}")"
  case "${file_id}" in
    folder-1)
      printf '%s\n' '{"permissions":[{"id":"perm-domain","type":"domain","role":"reader","domain":"example.com","displayName":"example.com","allowFileDiscovery":false,"permissionDetails":[{"permissionType":"file","role":"reader","inherited":false}]}]}'
      ;;
    file-1)
      printf '%s\n' '{"permissions":[{"id":"perm-user","type":"user","role":"reader","emailAddress":"outside@vendor.com","displayName":"Vendor User","permissionDetails":[{"permissionType":"file","role":"reader","inherited":false}]},{"id":"perm-team","type":"group","role":"writer","emailAddress":"team@example.com","displayName":"Team","permissionDetails":[{"permissionType":"member","role":"writer","inherited":true,"inheritedFrom":"drive-alpha"}]}]}'
      ;;
    file-2)
      printf '%s\n' '{"permissions":[{"id":"perm-anyone","type":"anyone","role":"reader","allowFileDiscovery":false,"permissionDetails":[{"permissionType":"file","role":"reader","inherited":false}]}]}'
      ;;
    file-3)
      printf '%s\n' '{"permissions":[{"id":"perm-organizer","type":"user","role":"organizer","emailAddress":"owner@example.com","displayName":"Owner User","permissionDetails":[{"permissionType":"file","role":"organizer","inherited":false}]},{"id":"perm-user-3","type":"user","role":"reader","emailAddress":"contractor@example.com","displayName":"Contractor","permissionDetails":[{"permissionType":"file","role":"reader","inherited":false}]}]}'
      ;;
    *)
      printf '%s\n' '{"permissions":[]}'
      ;;
  esac
  exit 0
fi

if [[ "${cmd}" == "drive permissions delete"* ]]; then
  file_id="$(jq -r '.fileId // empty' <<<"${params}")"
  permission_id="$(jq -r '.permissionId // empty' <<<"${params}")"
  printf '%s\n' "{\"fileId\":\"${file_id}\",\"permissionId\":\"${permission_id}\",\"deleted\":true}"
  exit 0
fi

printf 'unexpected gws invocation: %s\n' "${cmd}" >&2
exit 1
EOF

  chmod +x "${target}"
}

setup_sandbox() {
  TEST_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/google-drive-auditing.XXXXXX")"
  mkdir -p "${TEST_SANDBOX}/bin" "${TEST_SANDBOX}/output"

  FAKE_GWS_LOG_FILE="${TEST_SANDBOX}/gws.log"
  write_fake_gws "${TEST_SANDBOX}/bin/gws"

  export TEST_SANDBOX
  export FAKE_GWS_LOG_FILE
  export PATH="${TEST_SANDBOX}/bin:${ORIGINAL_PATH}"
  export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
}

teardown_sandbox() {
  PATH="${ORIGINAL_PATH}"
  unset FAKE_GWS_LOG_FILE
  unset FAKE_GWS_PROFILE
  unset GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND

  if [[ -n "${TEST_SANDBOX:-}" && -d "${TEST_SANDBOX}" ]]; then
    rm -rf "${TEST_SANDBOX}"
  fi

  unset TEST_SANDBOX
}

run_audit() {
  local -a env_args

  env_args=(
    "PATH=${TEST_SANDBOX}/bin:${ORIGINAL_PATH}"
    "FAKE_GWS_LOG_FILE=${FAKE_GWS_LOG_FILE}"
    "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file"
  )

  if [[ -n "${FAKE_GWS_PROFILE:-}" ]]; then
    env_args+=("FAKE_GWS_PROFILE=${FAKE_GWS_PROFILE}")
  fi

  run env "${env_args[@]}" bash "${AUDIT_SCRIPT}" \
    --output-dir "${TEST_SANDBOX}/output" "$@"
}

run_remove_sharing() {
  local -a env_args

  env_args=(
    "PATH=${TEST_SANDBOX}/bin:${ORIGINAL_PATH}"
    "FAKE_GWS_LOG_FILE=${FAKE_GWS_LOG_FILE}"
    "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file"
  )

  if [[ -n "${FAKE_GWS_PROFILE:-}" ]]; then
    env_args+=("FAKE_GWS_PROFILE=${FAKE_GWS_PROFILE}")
  fi

  run env "${env_args[@]}" bash "${REMOVE_SCRIPT}" \
    --output-dir "${TEST_SANDBOX}/remediation-output" "$@"
}
