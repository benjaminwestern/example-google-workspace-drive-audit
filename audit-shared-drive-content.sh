#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/google_drive_auditing.py"
RUN_TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/output/$(date '+%Y%m%d-%H%M%S')"

OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
PERMISSIONS_SCOPE="augmented"
INCLUDE_INHERITED_PERMISSIONS=false
RESUME=false
DRIVE_QUERY=""
USE_DOMAIN_ADMIN_ACCESS=true
DRIVE_PAGE_SIZE=100
FILE_PAGE_SIZE=1000
PERMISSION_PAGE_SIZE=100

RAW_DIR=""
WORK_DIR=""
REPORT_DIR=""
DRIVES_PAGES=""
DRIVES_JSONL=""
INVENTORY_JSONL=""
INVENTORY_RESOLVED_JSONL=""
SHARED_ITEMS_JSONL=""
INVENTORY_CSV=""
AUDIT_CSV=""
AUTH_LOG=""
ABOUT_JSON=""
SUMMARY_FILE=""
DRIVE_FAILURES_FILE=""
PERMISSION_FAILURES_FILE=""

FOLDER_MIME_TYPE="application/vnd.google-apps.folder"
SHORTCUT_MIME_TYPE="application/vnd.google-apps.shortcut"
FILES_FIELDS="nextPageToken,files(id,name,mimeType,parents,driveId,webViewLink,createdTime,modifiedTime,size,trashed,hasAugmentedPermissions,inheritedPermissionsDisabled,shortcutDetails(targetId,targetMimeType))"
PERMISSIONS_FIELDS="nextPageToken,permissions(id,type,role,emailAddress,domain,displayName,allowFileDiscovery,deleted,expirationTime,view,pendingOwner,inheritedPermissionsDisabled,permissionDetails)"

usage() {
  cat <<'EOF'
Usage:
  ./audit-shared-drive-content.sh [options]

Options:
  --output-dir DIR
      Write raw data, working files, and CSV reports to DIR.
      Default: ./output/<timestamp>

  --permissions-scope augmented|all
      augmented: only fetch permissions for items with
      hasAugmentedPermissions=true. This is the default and is the
      practical mode for item-level sharing audits.
      all: fetch permissions for every item in every shared drive.
      This is slower and can be very expensive on large estates.

  --include-inherited-permissions
      Keep inherited permission rows in the final CSV. By default the
      audit keeps direct permission rows only.

  --drive-query QUERY
      Pass a Drive query to gws drive drives list.
      Example: "name contains 'Project'"

  --resume
      Reuse raw gws responses that already exist in the output directory.

  --no-domain-admin-access
      Disable useDomainAdminAccess on shared drive enumeration.

  -h, --help
      Show this help text.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

line_count() {
  local target="$1"
  if [[ -f "$target" ]]; then
    awk 'END { print NR }' "$target"
  else
    printf '0\n'
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir requires a value"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --permissions-scope)
        [[ $# -ge 2 ]] || die "--permissions-scope requires a value"
        case "$2" in
          augmented|all)
            PERMISSIONS_SCOPE="$2"
            ;;
          *)
            die "--permissions-scope must be augmented or all"
            ;;
        esac
        shift 2
        ;;
      --include-inherited-permissions)
        INCLUDE_INHERITED_PERMISSIONS=true
        shift
        ;;
      --drive-query)
        [[ $# -ge 2 ]] || die "--drive-query requires a value"
        DRIVE_QUERY="$2"
        shift 2
        ;;
      --resume)
        RESUME=true
        shift
        ;;
      --no-domain-admin-access)
        USE_DOMAIN_ADMIN_ACCESS=false
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

init_layout() {
  RAW_DIR="${OUTPUT_DIR}/raw"
  WORK_DIR="${OUTPUT_DIR}/work"
  REPORT_DIR="${OUTPUT_DIR}/reports"
  DRIVES_PAGES="${RAW_DIR}/drives-pages.ndjson"
  DRIVES_JSONL="${WORK_DIR}/drives.jsonl"
  INVENTORY_JSONL="${WORK_DIR}/shared-drive-inventory.jsonl"
  INVENTORY_RESOLVED_JSONL="${WORK_DIR}/shared-drive-inventory.resolved.jsonl"
  SHARED_ITEMS_JSONL="${WORK_DIR}/shared-items.jsonl"
  INVENTORY_CSV="${REPORT_DIR}/shared-drive-inventory.csv"
  AUDIT_CSV="${REPORT_DIR}/shared-drive-sharing-audit.csv"
  AUTH_LOG="${WORK_DIR}/auth-check.stderr.log"
  ABOUT_JSON="${WORK_DIR}/about.json"
  SUMMARY_FILE="${REPORT_DIR}/run-summary.txt"
  DRIVE_FAILURES_FILE="${REPORT_DIR}/drive-fetch-failures.tsv"
  PERMISSION_FAILURES_FILE="${REPORT_DIR}/permission-fetch-failures.tsv"

  mkdir -p "${RAW_DIR}/drives" "${RAW_DIR}/permissions" "${WORK_DIR}" \
    "${REPORT_DIR}"

  : > "${DRIVE_FAILURES_FILE}"
  : > "${PERMISSION_FAILURES_FILE}"
}

verify_auth() {
  local auth_params about_json auth_email auth_name

  auth_params="$(jq -nc \
    '{"fields":"user(displayName,emailAddress)"}'
  )"

  if ! about_json="$(
    gws drive about get --params "${auth_params}" 2>"${AUTH_LOG}"
  )"; then
    die "gws authentication failed. See ${AUTH_LOG} and README.md for setup."
  fi

  printf '%s\n' "${about_json}" > "${ABOUT_JSON}"

  auth_email="$(jq -r '.user.emailAddress // "unknown"' "${ABOUT_JSON}")"
  auth_name="$(jq -r '.user.displayName // "unknown"' "${ABOUT_JSON}")"
  log "Authenticated gws as ${auth_name} <${auth_email}>"
}

fetch_drives() {
  local drive_params drive_count

  drive_params="$(jq -nc \
    --argjson pageSize "${DRIVE_PAGE_SIZE}" \
    --argjson useDomainAdminAccess "${USE_DOMAIN_ADMIN_ACCESS}" \
    --arg q "${DRIVE_QUERY}" '
      {
        pageSize: $pageSize,
        useDomainAdminAccess: $useDomainAdminAccess
      }
      + (if $q == "" then {} else {q: $q} end)
    '
  )"

  log "Fetching shared drive list via gws"
  if ! gws drive drives list --params "${drive_params}" --page-all \
    >"${DRIVES_PAGES}" 2>"${WORK_DIR}/drives-list.stderr.log"; then
    die "Shared drive enumeration failed. See ${WORK_DIR}/drives-list.stderr.log."
  fi

  jq -c '.drives[]?' "${DRIVES_PAGES}" > "${DRIVES_JSONL}"
  drive_count="$(line_count "${DRIVES_JSONL}")"

  if [[ "${drive_count}" == "0" ]]; then
    die "No shared drives were returned. Check auth or adjust --drive-query."
  fi

  log "Discovered ${drive_count} shared drives"
}

fetch_inventory() {
  local drive_json drive_id drive_name drive_dir pages_file normalized_file
  local file_params stderr_file inventory_count

  : > "${INVENTORY_JSONL}"

  while IFS= read -r drive_json; do
    [[ -n "${drive_json}" ]] || continue

    drive_id="$(jq -r '.id' <<<"${drive_json}")"
    drive_name="$(jq -r '.name // .id' <<<"${drive_json}")"
    drive_dir="${RAW_DIR}/drives/${drive_id}"
    pages_file="${drive_dir}/files-pages.ndjson"
    normalized_file="${drive_dir}/files.jsonl"
    stderr_file="${drive_dir}/files.stderr.log"

    mkdir -p "${drive_dir}"

    if [[ "${RESUME}" == "true" && -s "${pages_file}" ]]; then
      log "Reusing cached file inventory for ${drive_name} (${drive_id})"
    else
      log "Fetching file inventory for ${drive_name} (${drive_id})"
      file_params="$(jq -nc \
        --arg driveId "${drive_id}" \
        --arg q "trashed=false" \
        --arg fields "${FILES_FIELDS}" \
        --argjson pageSize "${FILE_PAGE_SIZE}" '
          {
            driveId: $driveId,
            corpora: "drive",
            includeItemsFromAllDrives: true,
            supportsAllDrives: true,
            pageSize: $pageSize,
            q: $q,
            fields: $fields
          }
        '
      )"

      if ! gws drive files list --params "${file_params}" --page-all \
        >"${pages_file}" 2>"${stderr_file}"; then
        printf '%s\t%s\t%s\n' "${drive_id}" "${drive_name}" \
          "${stderr_file}" >> "${DRIVE_FAILURES_FILE}"
        log "Skipping ${drive_name} (${drive_id}) because file listing failed"
        continue
      fi
    fi

    jq -c \
      --arg driveId "${drive_id}" \
      --arg driveName "${drive_name}" '
        .files[]? | . + {auditDriveId: $driveId, auditDriveName: $driveName}
      ' "${pages_file}" > "${normalized_file}"

    cat "${normalized_file}" >> "${INVENTORY_JSONL}"
  done < "${DRIVES_JSONL}"

  inventory_count="$(line_count "${INVENTORY_JSONL}")"
  if [[ "${inventory_count}" == "0" ]]; then
    die "No shared drive items were inventoried. See ${DRIVE_FAILURES_FILE}."
  fi

  log "Captured ${inventory_count} shared drive items"
}

build_inventory_reports() {
  python3 "${PYTHON_HELPER}" build-inventory-reports \
    "${INVENTORY_JSONL}" \
    "${INVENTORY_RESOLVED_JSONL}" \
    "${INVENTORY_CSV}" \
    "${SHARED_ITEMS_JSONL}" \
    "${PERMISSIONS_SCOPE}"
}

fetch_permissions() {
  local candidate_count index item_json item_id item_path pages_file stderr_file
  local permission_params

  candidate_count="$(line_count "${SHARED_ITEMS_JSONL}")"
  if [[ "${candidate_count}" == "0" ]]; then
    log "No candidate items need permission expansion"
    return
  fi

  index=0
  while IFS= read -r item_json; do
    [[ -n "${item_json}" ]] || continue
    index=$((index + 1))

    item_id="$(jq -r '.id' <<<"${item_json}")"
    item_path="$(jq -r '.path' <<<"${item_json}")"
    pages_file="${RAW_DIR}/permissions/${item_id}.ndjson"
    stderr_file="${RAW_DIR}/permissions/${item_id}.stderr.log"

    if [[ "${RESUME}" == "true" && -s "${pages_file}" ]]; then
      if (( candidate_count <= 20 || index % 25 == 0 )); then
        log "Reusing cached permissions ${index}/${candidate_count}: ${item_path}"
      fi
      continue
    fi

    if (( candidate_count <= 20 || index % 25 == 0 )); then
      log "Fetching permissions ${index}/${candidate_count}: ${item_path}"
    fi

    permission_params="$(jq -nc \
      --arg fileId "${item_id}" \
      --arg fields "${PERMISSIONS_FIELDS}" \
      --argjson pageSize "${PERMISSION_PAGE_SIZE}" '
        {
          fileId: $fileId,
          supportsAllDrives: true,
          pageSize: $pageSize,
          fields: $fields
        }
      '
    )"

    if ! gws drive permissions list --params "${permission_params}" --page-all \
      >"${pages_file}" 2>"${stderr_file}"; then
      printf '%s\t%s\t%s\n' "${item_id}" "${item_path}" \
        "${stderr_file}" >> "${PERMISSION_FAILURES_FILE}"
      rm -f "${pages_file}"
      log "Skipping ${item_path} because permission listing failed"
      continue
    fi
  done < "${SHARED_ITEMS_JSONL}"
}

build_audit_csv() {
  python3 "${PYTHON_HELPER}" build-audit-csv \
    "${SHARED_ITEMS_JSONL}" \
    "${RAW_DIR}/permissions" \
    "${AUDIT_CSV}" \
    "${INCLUDE_INHERITED_PERMISSIONS}"
}

write_summary() {
  local auth_email auth_name drives_count inventory_count shared_item_count
  local inventory_augmented_key audit_row_count drive_failure_count
  local permission_failure_count permission_files_seen

  auth_email="$(jq -r '.user.emailAddress // "unknown"' "${ABOUT_JSON}")"
  auth_name="$(jq -r '.user.displayName // "unknown"' "${ABOUT_JSON}")"
  drives_count="$(line_count "${DRIVES_JSONL}")"
  inventory_count="$(line_count "${INVENTORY_JSONL}")"
  shared_item_count="$(line_count "${SHARED_ITEMS_JSONL}")"
  drive_failure_count="$(line_count "${DRIVE_FAILURES_FILE}")"
  permission_failure_count="$(line_count "${PERMISSION_FAILURES_FILE}")"
  inventory_augmented_key="${INVENTORY_SUMMARY_AUGMENTED_KEY}"
  permission_files_seen="${AUDIT_SUMMARY_PERMISSION_FILES}"
  audit_row_count="${AUDIT_SUMMARY_ROW_COUNT}"

  cat > "${SUMMARY_FILE}" <<EOF
Run captured at: ${RUN_TIMESTAMP_UTC}
Authenticated as: ${auth_name} <${auth_email}>
Output directory: ${OUTPUT_DIR}

Configuration
- permissions_scope=${PERMISSIONS_SCOPE}
- include_inherited_permissions=${INCLUDE_INHERITED_PERMISSIONS}
- use_domain_admin_access=${USE_DOMAIN_ADMIN_ACCESS}
- drive_query=${DRIVE_QUERY:-<none>}

Counts
- shared_drives_discovered=${drives_count}
- inventory_rows=${inventory_count}
- candidate_items_for_permission_expansion=${shared_item_count}
- permission_files_seen=${permission_files_seen}
- audit_rows=${audit_row_count}
- inventory_exposed_hasAugmentedPermissions=${inventory_augmented_key}
- drive_fetch_failures=${drive_failure_count}
- permission_fetch_failures=${permission_failure_count}

Outputs
- inventory_csv=${INVENTORY_CSV}
- sharing_audit_csv=${AUDIT_CSV}
- drive_failures=${DRIVE_FAILURES_FILE}
- permission_failures=${PERMISSION_FAILURES_FILE}
EOF
}

main() {
  local inventory_summary_json audit_summary_json inventory_count
  local shared_item_count inventory_augmented_key audit_row_count

  parse_args "$@"

  require_command gws
  require_command jq
  require_command python3

  if [[ -z "${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-}" ]]; then
    export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="file"
  fi

  export AUDIT_CAPTURED_AT="${RUN_TIMESTAMP_UTC}"
  export FOLDER_MIME_TYPE
  export SHORTCUT_MIME_TYPE

  init_layout
  verify_auth
  fetch_drives
  fetch_inventory

  inventory_summary_json="$(build_inventory_reports)"
  inventory_count="$(jq -r '.inventory_count' <<<"${inventory_summary_json}")"
  shared_item_count="$(jq -r '.shared_item_count' <<<"${inventory_summary_json}")"
  inventory_augmented_key="$(jq -r '.has_augmented_key' \
    <<<"${inventory_summary_json}")"
  INVENTORY_SUMMARY_AUGMENTED_KEY="${inventory_augmented_key}"

  log "Resolved ${inventory_count} inventory rows into ${INVENTORY_CSV}"
  log "Selected ${shared_item_count} items for permission expansion"

  if [[ "${shared_item_count}" == "0" && "${PERMISSIONS_SCOPE}" == "augmented" ]]; then
    log "No directly shared items were found. If that looks wrong, rerun with"
    log "--permissions-scope all to force a full permission sweep."
  fi

  fetch_permissions

  audit_summary_json="$(build_audit_csv)"
  AUDIT_SUMMARY_PERMISSION_FILES="$(jq -r '.permission_files_seen' \
    <<<"${audit_summary_json}")"
  audit_row_count="$(jq -r '.audit_row_count' <<<"${audit_summary_json}")"
  AUDIT_SUMMARY_ROW_COUNT="${audit_row_count}"

  write_summary

  log "Wrote inventory CSV to ${INVENTORY_CSV}"
  log "Wrote sharing audit CSV to ${AUDIT_CSV}"
  log "Wrote run summary to ${SUMMARY_FILE}"
}

main "$@"
