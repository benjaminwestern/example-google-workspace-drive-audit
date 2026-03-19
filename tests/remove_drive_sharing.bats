#!/usr/bin/env bats

load 'test_helper.bash'

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "revoke-permission dry-run plans a delete without sending it" {
  local input_csv summary_file results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role
file-1,perm-user,Operations / Shared folder / Quarterly plan,outside@vendor.com,user,reader
EOF

  run_remove_sharing --input "${input_csv}" --mode revoke-permission

  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/remediation-output/reports/remediation-summary.txt"
  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_exists "${summary_file}"
  assert_file_exists "${results_file}"
  assert_file_contains "${results_file}" $'dry-run\trevoke-permission\tfile-1\tperm-user'
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" 'drive permissions delete'
}

@test "revoke-permission execute deletes the requested permission" {
  local input_csv results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role
file-1,perm-user,Operations / Shared folder / Quarterly plan,outside@vendor.com,user,reader
EOF

  run_remove_sharing --input "${input_csv}" --mode revoke-permission --execute

  [ "${status}" -eq 0 ]

  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" 'drive permissions delete'
  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-1","permissionId":"perm-user","supportsAllDrives":true'
  assert_file_contains "${results_file}" $'deleted\trevoke-permission\tfile-1\tperm-user'
}

@test "revoke-permission refuses inherited-only input rows" {
  local input_csv summary_file results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role,permission_is_inherited_only
file-1,perm-team,Operations / Shared folder / Quarterly plan,team@example.com,group,writer,true
EOF

  run_remove_sharing --input "${input_csv}" --mode revoke-permission --execute

  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/remediation-output/reports/remediation-summary.txt"
  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${summary_file}" "planned_delete_actions=0"
  assert_file_exists "${results_file}"
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" 'drive permissions delete'
}

@test "revoke-permission validates live permissions before delete" {
  local input_csv summary_file results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role
file-1,perm-team,Operations / Shared folder / Quarterly plan,team@example.com,group,writer
EOF

  run_remove_sharing --input "${input_csv}" --mode revoke-permission --execute

  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/remediation-output/reports/remediation-summary.txt"
  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" 'drive permissions list'
  assert_file_contains "${summary_file}" "planned_delete_actions=0"
  assert_file_exists "${results_file}"
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" '"permissionId":"perm-team"'
}

@test "revoke-permission skips management roles by default" {
  local input_csv summary_file results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role
file-3,perm-organizer,Operations / Management file,owner@example.com,user,organizer
EOF

  run_remove_sharing --input "${input_csv}" --mode revoke-permission --execute

  [ "${status}" -eq 0 ]

  summary_file="${TEST_SANDBOX}/remediation-output/reports/remediation-summary.txt"
  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-3","supportsAllDrives":true'
  assert_file_contains "${summary_file}" "planned_delete_actions=0"
  assert_file_exists "${results_file}"
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" '"permissionId":"perm-organizer"'
}

@test "revoke-permission can include management roles" {
  local input_csv results_file

  input_csv="${TEST_SANDBOX}/revoke.csv"
  cat > "${input_csv}" <<'EOF'
item_id,permission_id,item_path,permission_email_address,permission_type,permission_role
file-3,perm-organizer,Operations / Management file,owner@example.com,user,organizer
EOF

  run_remove_sharing \
    --input "${input_csv}" \
    --mode revoke-permission \
    --include-management-roles \
    --execute

  [ "${status}" -eq 0 ]

  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-3","permissionId":"perm-organizer","supportsAllDrives":true'
  assert_file_contains "${results_file}" $'deleted\trevoke-permission\tfile-3\tperm-organizer'
}

@test "unshare-all-direct execute removes only direct item permissions" {
  local input_csv results_file

  input_csv="${TEST_SANDBOX}/unshare.csv"
  cat > "${input_csv}" <<'EOF'
file_id,item_path
file-1,Operations / Shared folder / Quarterly plan
EOF

  run_remove_sharing --input "${input_csv}" --mode unshare-all-direct --execute

  [ "${status}" -eq 0 ]

  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" 'drive permissions list'
  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-1","supportsAllDrives":true'
  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-1","permissionId":"perm-user","supportsAllDrives":true'
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-1","permissionId":"perm-team","supportsAllDrives":true'
  assert_file_contains "${results_file}" $'deleted\tunshare-all-direct\tfile-1\tperm-user'
}

@test "unshare-all-direct skips management roles by default" {
  local input_csv results_file

  input_csv="${TEST_SANDBOX}/unshare.csv"
  cat > "${input_csv}" <<'EOF'
file_id,item_path
file-3,Operations / Management file
EOF

  run_remove_sharing --input "${input_csv}" --mode unshare-all-direct --execute

  [ "${status}" -eq 0 ]

  results_file="${TEST_SANDBOX}/remediation-output/reports/remediation-results.tsv"

  assert_file_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-3","permissionId":"perm-user-3","supportsAllDrives":true'
  assert_file_not_contains "${FAKE_GWS_LOG_FILE}" '"fileId":"file-3","permissionId":"perm-organizer","supportsAllDrives":true'
  assert_file_contains "${results_file}" $'deleted\tunshare-all-direct\tfile-3\tperm-user-3'
}
