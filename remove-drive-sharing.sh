#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/google_drive_auditing.py"
RUN_TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/output/remediation-$(date '+%Y%m%d-%H%M%S')"

INPUT_CSV=""
MODE=""
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
EXECUTE=false
INCLUDE_MANAGEMENT_ROLES=false

RAW_DIR=""
WORK_DIR=""
REPORT_DIR=""
TARGETS_JSONL=""
PLANNED_ACTIONS_JSONL=""
SKIPS_JSONL=""
RESULTS_FILE=""
SUMMARY_FILE=""
LIST_FAILURES_FILE=""

PERMISSIONS_FIELDS="nextPageToken,permissions(id,type,role,emailAddress,domain,displayName,allowFileDiscovery,deleted,expirationTime,view,pendingOwner,inheritedPermissionsDisabled,permissionDetails)"

usage() {
  cat <<'EOF'
Usage:
  ./remove-drive-sharing.sh --input INPUT.csv --mode revoke-permission|unshare-all-direct [options]

Modes:
  revoke-permission
      Validate each input row against the current live permission snapshot,
      then delete the matching direct item-level permission.
      Required columns: file_id or item_id, and permission_id.

  unshare-all-direct
      For each file_id or item_id in the input CSV, list current permissions and
      delete every direct item-level permission except owner, organizer, and
      fileOrganizer by default. Inherited permissions are never deleted by this
      mode.

Options:
  --input PATH
      Read remediation targets from PATH. This must be a CSV with a header row.

  --mode revoke-permission|unshare-all-direct
      Choose whether each row deletes one known permission or whether each file
      should have all direct item-level shares removed.

  --output-dir DIR
      Write planning artifacts, raw permission snapshots, and execution reports
      to DIR. Default: ./output/remediation-<timestamp>

  --execute
      Actually send delete requests. Default: dry-run only.

  --include-management-roles
      Also delete direct owner, organizer, and fileOrganizer permissions after
      validating the live permission snapshot. This is intentionally off by
      default.

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
  if [[ -f "${target}" ]]; then
    awk 'END { print NR }' "${target}"
  else
    printf '0\n'
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input)
        [[ $# -ge 2 ]] || die "--input requires a value"
        INPUT_CSV="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        case "$2" in
          revoke-permission|unshare-all-direct)
            MODE="$2"
            ;;
          *)
            die "--mode must be revoke-permission or unshare-all-direct"
            ;;
        esac
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir requires a value"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --execute)
        EXECUTE=true
        shift
        ;;
      --include-management-roles)
        INCLUDE_MANAGEMENT_ROLES=true
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

  [[ -n "${INPUT_CSV}" ]] || die "--input is required"
  [[ -n "${MODE}" ]] || die "--mode is required"
  [[ -f "${INPUT_CSV}" ]] || die "Input CSV not found: ${INPUT_CSV}"
}

init_layout() {
  RAW_DIR="${OUTPUT_DIR}/raw"
  WORK_DIR="${OUTPUT_DIR}/work"
  REPORT_DIR="${OUTPUT_DIR}/reports"
  TARGETS_JSONL="${WORK_DIR}/targets.jsonl"
  PLANNED_ACTIONS_JSONL="${WORK_DIR}/planned-actions.jsonl"
  SKIPS_JSONL="${WORK_DIR}/skips.jsonl"
  RESULTS_FILE="${REPORT_DIR}/remediation-results.tsv"
  SUMMARY_FILE="${REPORT_DIR}/remediation-summary.txt"
  LIST_FAILURES_FILE="${REPORT_DIR}/permission-list-failures.tsv"

  mkdir -p "${RAW_DIR}/permissions" "${RAW_DIR}/delete-responses" \
    "${WORK_DIR}" "${REPORT_DIR}"

  : > "${SKIPS_JSONL}"
  : > "${LIST_FAILURES_FILE}"
}

build_targets() {
  python3 "${PYTHON_HELPER}" build-remediation-targets \
    "${INPUT_CSV}" \
    "${MODE}" \
    "${TARGETS_JSONL}" \
    "${SKIPS_JSONL}"
}

fetch_permission_snapshots() {
  local target_json file_id item_path pages_file stderr_file permission_params

  while IFS= read -r target_json; do
    [[ -n "${target_json}" ]] || continue

    file_id="$(jq -r '.file_id' <<<"${target_json}")"
    item_path="$(jq -r '.item_path // .file_id' <<<"${target_json}")"
    pages_file="${RAW_DIR}/permissions/${file_id}.ndjson"
    stderr_file="${RAW_DIR}/permissions/${file_id}.stderr.log"

    if [[ -s "${pages_file}" ]]; then
      continue
    fi

    permission_params="$(jq -nc \
      --arg fileId "${file_id}" \
      --arg fields "${PERMISSIONS_FIELDS}" '
        {
          fileId: $fileId,
          supportsAllDrives: true,
          fields: $fields
        }
      '
    )"

    log "Listing current permissions for ${item_path}"
    if ! gws drive permissions list --params "${permission_params}" --page-all \
      >"${pages_file}" 2>"${stderr_file}"; then
      printf '%s\t%s\t%s\n' "${file_id}" "${item_path}" \
        "${stderr_file}" >> "${LIST_FAILURES_FILE}"
      rm -f "${pages_file}"
      log "Skipping ${item_path} because permission listing failed"
    fi
  done < "${TARGETS_JSONL}"
}

build_delete_actions() {
  python3 "${PYTHON_HELPER}" build-delete-actions \
    "${TARGETS_JSONL}" \
    "${RAW_DIR}/permissions" \
    "${PLANNED_ACTIONS_JSONL}" \
    "${SKIPS_JSONL}" \
    "${INCLUDE_MANAGEMENT_ROLES}"
}

write_results_header() {
  cat > "${RESULTS_FILE}" <<'EOF'
status	mode	file_id	permission_id	shared_drive_name	item_path	permission_type	permission_role	permission_email_address	permission_domain	reason
EOF
}

append_result() {
  local status="$1"
  local action_json="$2"
  local reason="$3"

  local mode file_id permission_id shared_drive_name item_path permission_type
  local permission_role permission_email_address permission_domain

  mode="$(jq -r '.mode // ""' <<<"${action_json}")"
  file_id="$(jq -r '.file_id // ""' <<<"${action_json}")"
  permission_id="$(jq -r '.permission_id // ""' <<<"${action_json}")"
  shared_drive_name="$(jq -r '.shared_drive_name // ""' <<<"${action_json}")"
  item_path="$(jq -r '.item_path // ""' <<<"${action_json}")"
  permission_type="$(jq -r '.permission_type // ""' <<<"${action_json}")"
  permission_role="$(jq -r '.permission_role // ""' <<<"${action_json}")"
  permission_email_address="$(
    jq -r '.permission_email_address // ""' <<<"${action_json}"
  )"
  permission_domain="$(jq -r '.permission_domain // ""' <<<"${action_json}")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${status}" "${mode}" "${file_id}" "${permission_id}" \
    "${shared_drive_name}" "${item_path}" "${permission_type}" \
    "${permission_role}" "${permission_email_address}" \
    "${permission_domain}" "${reason}" >> "${RESULTS_FILE}"
}

execute_actions() {
  local action_json file_id permission_id item_path delete_params response_file
  local stderr_file

  write_results_header

  while IFS= read -r action_json; do
    [[ -n "${action_json}" ]] || continue

    file_id="$(jq -r '.file_id' <<<"${action_json}")"
    permission_id="$(jq -r '.permission_id' <<<"${action_json}")"
    item_path="$(jq -r '.item_path // .file_id' <<<"${action_json}")"

    if [[ "${EXECUTE}" == "false" ]]; then
      append_result "dry-run" "${action_json}" "would delete permission"
      continue
    fi

    delete_params="$(jq -nc \
      --arg fileId "${file_id}" \
      --arg permissionId "${permission_id}" '
        {
          fileId: $fileId,
          permissionId: $permissionId,
          supportsAllDrives: true
        }
      '
    )"

    response_file="${RAW_DIR}/delete-responses/${file_id}__${permission_id}.json"
    stderr_file="${RAW_DIR}/delete-responses/${file_id}__${permission_id}.stderr.log"

    log "Deleting permission ${permission_id} from ${item_path}"
    if gws drive permissions delete --params "${delete_params}" \
      >"${response_file}" 2>"${stderr_file}"; then
      append_result "deleted" "${action_json}" ""
    else
      rm -f "${response_file}"
      append_result "delete-failed" "${action_json}" "${stderr_file}"
      log "Delete failed for ${item_path}; see ${stderr_file}"
    fi
  done < "${PLANNED_ACTIONS_JSONL}"
}

count_results_with_status() {
  local status="$1"
  awk -F'\t' -v wanted="${status}" '
    NR > 1 && $1 == wanted { count++ }
    END { print count + 0 }
  ' "${RESULTS_FILE}"
}

write_summary() {
  local target_count planned_action_count skip_count list_failure_count
  local dry_run_count deleted_count delete_failed_count

  target_count="$(line_count "${TARGETS_JSONL}")"
  planned_action_count="$(line_count "${PLANNED_ACTIONS_JSONL}")"
  skip_count="$(line_count "${SKIPS_JSONL}")"
  list_failure_count="$(line_count "${LIST_FAILURES_FILE}")"
  dry_run_count="$(count_results_with_status "dry-run")"
  deleted_count="$(count_results_with_status "deleted")"
  delete_failed_count="$(count_results_with_status "delete-failed")"

  cat > "${SUMMARY_FILE}" <<EOF
Run captured at: ${RUN_TIMESTAMP_UTC}
Mode: ${MODE}
Execute mode: ${EXECUTE}
Input CSV: ${INPUT_CSV}
Output directory: ${OUTPUT_DIR}

Counts
- planned_targets=${target_count}
- planned_delete_actions=${planned_action_count}
- skipped_rows_or_permissions=${skip_count}
- permission_list_failures=${list_failure_count}
- dry_run_actions=${dry_run_count}
- deleted_permissions=${deleted_count}
- delete_failures=${delete_failed_count}

Outputs
- planned_actions=${PLANNED_ACTIONS_JSONL}
- skips=${SKIPS_JSONL}
- results=${RESULTS_FILE}
- summary=${SUMMARY_FILE}
- permission_list_failures=${LIST_FAILURES_FILE}
EOF
}

main() {
  local target_summary_json action_summary_json target_count planned_action_count

  parse_args "$@"

  require_command gws
  require_command jq
  require_command python3

  init_layout

  target_summary_json="$(build_targets)"
  target_count="$(jq -r '.target_count' <<<"${target_summary_json}")"

  if [[ "${target_count}" == "0" ]]; then
    log "No eligible targets were found in ${INPUT_CSV}"
    write_results_header
    write_summary
    exit 0
  fi

  fetch_permission_snapshots

  action_summary_json="$(build_delete_actions)"
  planned_action_count="$(jq -r '.planned_action_count' \
    <<<"${action_summary_json}")"

  if [[ "${planned_action_count}" == "0" ]]; then
    log "No delete actions were planned for ${MODE}"
    write_results_header
    write_summary
    exit 0
  fi

  if [[ "${EXECUTE}" == "false" ]]; then
    log "Dry-run only. No delete requests will be sent."
  fi

  execute_actions
  write_summary

  log "Wrote remediation results to ${RESULTS_FILE}"
  log "Wrote remediation summary to ${SUMMARY_FILE}"
}

main "$@"
