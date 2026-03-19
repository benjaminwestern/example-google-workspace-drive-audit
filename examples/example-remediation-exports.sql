-- Run this after loading `load-redacted-example-data.sql`. The generated CSVs
-- match the shapes expected by `./remove-drive-sharing.sh`. Run it from the
-- `google-drive-auditing/` directory so the relative output paths land in the
-- repository's `examples/` directory.

COPY (
  SELECT
    item_id AS file_id,
    permission_id,
    shared_drive_name,
    item_path,
    permission_type,
    permission_role,
    permission_email_address,
    permission_domain,
    permission_is_direct,
    permission_is_inherited_only
  FROM shared_drive_sharing_audit_example
  WHERE permission_type IN ('user', 'group')
    AND permission_email_address NOT LIKE '%@company.example'
) TO 'examples/revoke-permissions-example.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT DISTINCT
    item_id AS file_id,
    shared_drive_name,
    item_path
  FROM shared_drive_sharing_audit_example
  WHERE shared_drive_name = 'Shared Drive Alpha'
) TO 'examples/unshare-files-example.csv' (HEADER, DELIMITER ',');
