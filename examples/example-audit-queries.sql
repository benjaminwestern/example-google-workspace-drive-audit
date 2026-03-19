-- Run this after loading `load-redacted-example-data.sql` into a DuckDB
-- database. The queries mirror the most common audit questions used against
-- the real CSV outputs.

SELECT
  shared_drive_name,
  COUNT(DISTINCT item_id) AS directly_shared_items
FROM shared_drive_sharing_audit_example
GROUP BY 1
ORDER BY 2 DESC, 1;

SELECT
  shared_drive_name,
  item_path,
  permission_type,
  permission_role,
  permission_email_address
FROM shared_drive_sharing_audit_example
WHERE permission_type IN ('user', 'group')
  AND permission_email_address <> ''
  AND permission_email_address NOT LIKE '%@company.example'
ORDER BY shared_drive_name, item_path, permission_email_address;

SELECT
  shared_drive_name,
  COUNT(DISTINCT item_id) AS directly_shared_folders
FROM shared_drive_sharing_audit_example
WHERE item_is_folder = TRUE
GROUP BY 1
ORDER BY 2 DESC, 1;

SELECT
  permission_role,
  COUNT(*) AS permission_rows
FROM shared_drive_sharing_audit_example
GROUP BY 1
ORDER BY 2 DESC, 1;

SELECT
  i.shared_drive_name,
  COUNT(*) AS augmented_inventory_items,
  SUM(CASE WHEN i.item_is_folder THEN 1 ELSE 0 END) AS augmented_folders
FROM shared_drive_inventory_example AS i
WHERE i.item_has_augmented_permissions = TRUE
GROUP BY 1
ORDER BY 2 DESC, 1;
