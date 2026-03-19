#!/usr/bin/env bats

load 'test_helper.bash'

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "help output includes permissions scope" {
  run bash "${AUDIT_SCRIPT}" --help

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--permissions-scope augmented|all"* ]]
}

@test "augmented mode generates expected reports" {
  local summary_file inventory_csv audit_csv
  local inventory_count audit_count candidate_count

  run_audit
  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/output/reports/run-summary.txt"
  inventory_csv="${TEST_SANDBOX}/output/reports/shared-drive-inventory.csv"
  audit_csv="${TEST_SANDBOX}/output/reports/shared-drive-sharing-audit.csv"

  assert_file_exists "${summary_file}"
  assert_file_exists "${inventory_csv}"
  assert_file_exists "${audit_csv}"

  inventory_count="$(
    duckdb_scalar "SELECT COUNT(*) FROM read_csv_auto('${inventory_csv}');"
  )"
  audit_count="$(
    duckdb_scalar "SELECT COUNT(*) FROM read_csv_auto('${audit_csv}');"
  )"
  candidate_count="$(
    summary_value "${summary_file}" \
      "candidate_items_for_permission_expansion"
  )"

  assert_eq "3" "${inventory_count}"
  assert_eq "2" "${audit_count}"
  assert_eq "2" "${candidate_count}"
  assert_file_not_contains "${audit_csv}" "team@example.com"
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-2"'
}

@test "include inherited permissions keeps inherited rows" {
  local audit_csv audit_count

  run_audit --include-inherited-permissions
  [ "${status}" -eq 0 ]

  audit_csv="${TEST_SANDBOX}/output/reports/shared-drive-sharing-audit.csv"
  audit_count="$(
    duckdb_scalar "SELECT COUNT(*) FROM read_csv_auto('${audit_csv}');"
  )"

  assert_eq "3" "${audit_count}"
  assert_file_contains "${audit_csv}" "team@example.com"
}

@test "permissions scope all fetches non augmented items" {
  local summary_file audit_csv audit_count candidate_count

  run_audit --permissions-scope all
  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/output/reports/run-summary.txt"
  audit_csv="${TEST_SANDBOX}/output/reports/shared-drive-sharing-audit.csv"
  audit_count="$(
    duckdb_scalar "SELECT COUNT(*) FROM read_csv_auto('${audit_csv}');"
  )"
  candidate_count="$(
    summary_value "${summary_file}" \
      "candidate_items_for_permission_expansion"
  )"

  assert_eq "3" "${candidate_count}"
  assert_eq "3" "${audit_count}"
  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-2"'
  assert_file_contains "${audit_csv}" ",anyone,reader,"
}

@test "auth failure returns useful error" {
  local auth_log

  export FAKE_GWS_PROFILE="auth-failure"

  run_audit

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"gws authentication failed."* ]]

  auth_log="${TEST_SANDBOX}/output/work/auth-check.stderr.log"

  assert_file_exists "${auth_log}"
  assert_file_contains "${auth_log}" "mock auth failure"
}
