#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import pathlib
from typing import Any

MANAGEMENT_ROLES = {"owner", "organizer", "fileOrganizer"}


def json_compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def csv_bool(value: Any) -> str:
    if value is None:
        return ""
    return "true" if value else "false"


def load_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def build_inventory_reports(args: argparse.Namespace) -> int:
    captured_at = os.environ.get("AUDIT_CAPTURED_AT", "")
    folder_mime_type = os.environ.get(
        "FOLDER_MIME_TYPE", "application/vnd.google-apps.folder"
    )
    shortcut_mime_type = os.environ.get(
        "SHORTCUT_MIME_TYPE", "application/vnd.google-apps.shortcut"
    )

    items = load_jsonl(args.inventory_jsonl)

    drive_index: dict[str, dict[str, dict[str, Any]]] = {}
    for item in items:
        drive_id = item.get("auditDriveId") or item.get("driveId") or ""
        drive_index.setdefault(drive_id, {})[item.get("id")] = item

    def build_path(item: dict[str, Any]) -> str:
        drive_id = item.get("auditDriveId") or item.get("driveId") or ""
        drive_name = item.get("auditDriveName") or drive_id or "unknown-drive"
        parts = [item.get("name") or item.get("id") or "unknown-item"]
        seen = {item.get("id")}
        parent_ids = list(item.get("parents") or [])

        while parent_ids:
            parent_id = parent_ids[0]
            if parent_id in seen:
                break
            seen.add(parent_id)
            parent = drive_index.get(drive_id, {}).get(parent_id)
            if parent is None:
                break
            parts.append(parent.get("name") or parent_id)
            parent_ids = list(parent.get("parents") or [])

        return " / ".join([drive_name] + list(reversed(parts)))

    normalised_items: list[dict[str, Any]] = []
    shared_items: list[dict[str, Any]] = []
    has_augmented_key = False

    for item in items:
        has_augmented_permissions = item.get("hasAugmentedPermissions")
        if has_augmented_permissions is not None:
            has_augmented_key = True

        mime_type = item.get("mimeType", "")
        is_folder = mime_type == folder_mime_type
        is_shortcut = mime_type == shortcut_mime_type
        shortcut_details = item.get("shortcutDetails") or {}

        normalised = {
            **item,
            "path": build_path(item),
            "itemKind": (
                "folder"
                if is_folder
                else "shortcut"
                if is_shortcut
                else "file"
            ),
            "itemIsFolder": is_folder,
            "itemIsShortcut": is_shortcut,
            "shortcutTargetId": shortcut_details.get("targetId", ""),
            "shortcutTargetMimeType": shortcut_details.get("targetMimeType", ""),
        }
        normalised_items.append(normalised)

        if args.permissions_scope == "all" or bool(has_augmented_permissions):
            shared_items.append(normalised)

    normalised_items.sort(
        key=lambda item: (
            item.get("auditDriveName", ""),
            item.get("path", ""),
            item.get("id", ""),
        )
    )
    shared_items.sort(
        key=lambda item: (
            item.get("auditDriveName", ""),
            item.get("path", ""),
            item.get("id", ""),
        )
    )

    with open(args.resolved_jsonl, "w", encoding="utf-8") as handle:
        for item in normalised_items:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")

    inventory_columns = [
        "audit_captured_at",
        "shared_drive_id",
        "shared_drive_name",
        "item_id",
        "item_name",
        "item_path",
        "item_kind",
        "item_mime_type",
        "item_is_folder",
        "item_is_shortcut",
        "item_parent_ids_json",
        "item_web_view_link",
        "item_created_time",
        "item_modified_time",
        "item_size_bytes",
        "item_has_augmented_permissions",
        "item_inherited_permissions_disabled",
        "shortcut_target_id",
        "shortcut_target_mime_type",
    ]

    with open(args.inventory_csv, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=inventory_columns)
        writer.writeheader()
        for item in normalised_items:
            writer.writerow(
                {
                    "audit_captured_at": captured_at,
                    "shared_drive_id": item.get("auditDriveId", ""),
                    "shared_drive_name": item.get("auditDriveName", ""),
                    "item_id": item.get("id", ""),
                    "item_name": item.get("name", ""),
                    "item_path": item.get("path", ""),
                    "item_kind": item.get("itemKind", ""),
                    "item_mime_type": item.get("mimeType", ""),
                    "item_is_folder": csv_bool(item.get("itemIsFolder")),
                    "item_is_shortcut": csv_bool(item.get("itemIsShortcut")),
                    "item_parent_ids_json": json_compact(item.get("parents") or []),
                    "item_web_view_link": item.get("webViewLink", ""),
                    "item_created_time": item.get("createdTime", ""),
                    "item_modified_time": item.get("modifiedTime", ""),
                    "item_size_bytes": item.get("size", ""),
                    "item_has_augmented_permissions": csv_bool(
                        item.get("hasAugmentedPermissions")
                    ),
                    "item_inherited_permissions_disabled": csv_bool(
                        item.get("inheritedPermissionsDisabled")
                    ),
                    "shortcut_target_id": item.get("shortcutTargetId", ""),
                    "shortcut_target_mime_type": item.get(
                        "shortcutTargetMimeType", ""
                    ),
                }
            )

    with open(args.shared_items_jsonl, "w", encoding="utf-8") as handle:
        for item in shared_items:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(
        json.dumps(
            {
                "inventory_count": len(normalised_items),
                "shared_item_count": len(shared_items),
                "has_augmented_key": has_augmented_key,
            }
        )
    )
    return 0


def build_audit_csv(args: argparse.Namespace) -> int:
    captured_at = os.environ.get("AUDIT_CAPTURED_AT", "")
    permissions_dir = pathlib.Path(args.permissions_dir)
    include_inherited = args.include_inherited.lower() == "true"

    shared_items = load_jsonl(args.shared_items_jsonl)
    shared_items_by_id = {item.get("id"): item for item in shared_items}

    columns = [
        "audit_captured_at",
        "shared_drive_id",
        "shared_drive_name",
        "item_id",
        "item_name",
        "item_path",
        "item_kind",
        "item_mime_type",
        "item_is_folder",
        "item_is_shortcut",
        "item_parent_ids_json",
        "item_web_view_link",
        "item_created_time",
        "item_modified_time",
        "item_size_bytes",
        "item_has_augmented_permissions",
        "item_inherited_permissions_disabled",
        "shortcut_target_id",
        "shortcut_target_mime_type",
        "permission_id",
        "permission_type",
        "permission_role",
        "permission_email_address",
        "permission_domain",
        "permission_display_name",
        "permission_allow_file_discovery",
        "permission_deleted",
        "permission_expiration_time",
        "permission_view",
        "permission_pending_owner",
        "permission_inherited_permissions_disabled",
        "permission_is_direct",
        "permission_is_inherited_only",
        "permission_detail_inherited",
        "permission_detail_inherited_from",
        "permission_detail_permission_type",
        "permission_detail_role",
        "permission_details_json",
        "permission_raw_json",
    ]

    rows_written = 0
    permission_files_seen = 0

    with open(args.audit_csv, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()

        for item in shared_items:
            item_id = item.get("id")
            if not item_id:
                continue

            permission_path = permissions_dir / f"{item_id}.ndjson"
            if not permission_path.exists():
                continue

            permission_files_seen += 1
            permissions: list[dict[str, Any]] = []
            with open(permission_path, "r", encoding="utf-8") as permission_handle:
                for line in permission_handle:
                    line = line.strip()
                    if not line:
                        continue
                    page = json.loads(line)
                    permissions.extend(page.get("permissions") or [])

            for permission in permissions:
                details = permission.get("permissionDetails") or []
                direct_details = [
                    detail for detail in details if detail.get("inherited") is False
                ]
                inherited_only = None
                is_direct = None
                selected_detail: dict[str, Any] = {}

                if details:
                    is_direct = bool(direct_details)
                    inherited_only = not is_direct
                    selected_detail = (
                        direct_details[0] if direct_details else details[0]
                    )

                if inherited_only is True and not include_inherited:
                    continue

                writer.writerow(
                    {
                        "audit_captured_at": captured_at,
                        "shared_drive_id": item.get("auditDriveId", ""),
                        "shared_drive_name": item.get("auditDriveName", ""),
                        "item_id": item.get("id", ""),
                        "item_name": item.get("name", ""),
                        "item_path": item.get("path", ""),
                        "item_kind": item.get("itemKind", ""),
                        "item_mime_type": item.get("mimeType", ""),
                        "item_is_folder": csv_bool(item.get("itemIsFolder")),
                        "item_is_shortcut": csv_bool(item.get("itemIsShortcut")),
                        "item_parent_ids_json": json_compact(item.get("parents") or []),
                        "item_web_view_link": item.get("webViewLink", ""),
                        "item_created_time": item.get("createdTime", ""),
                        "item_modified_time": item.get("modifiedTime", ""),
                        "item_size_bytes": item.get("size", ""),
                        "item_has_augmented_permissions": csv_bool(
                            item.get("hasAugmentedPermissions")
                        ),
                        "item_inherited_permissions_disabled": csv_bool(
                            item.get("inheritedPermissionsDisabled")
                        ),
                        "shortcut_target_id": item.get("shortcutTargetId", ""),
                        "shortcut_target_mime_type": item.get(
                            "shortcutTargetMimeType", ""
                        ),
                        "permission_id": permission.get("id", ""),
                        "permission_type": permission.get("type", ""),
                        "permission_role": permission.get("role", ""),
                        "permission_email_address": permission.get(
                            "emailAddress", ""
                        ),
                        "permission_domain": permission.get("domain", ""),
                        "permission_display_name": permission.get("displayName", ""),
                        "permission_allow_file_discovery": csv_bool(
                            permission.get("allowFileDiscovery")
                        ),
                        "permission_deleted": csv_bool(permission.get("deleted")),
                        "permission_expiration_time": permission.get(
                            "expirationTime", ""
                        ),
                        "permission_view": permission.get("view", ""),
                        "permission_pending_owner": csv_bool(
                            permission.get("pendingOwner")
                        ),
                        "permission_inherited_permissions_disabled": csv_bool(
                            permission.get("inheritedPermissionsDisabled")
                        ),
                        "permission_is_direct": csv_bool(is_direct),
                        "permission_is_inherited_only": csv_bool(inherited_only),
                        "permission_detail_inherited": csv_bool(
                            selected_detail.get("inherited")
                        ),
                        "permission_detail_inherited_from": selected_detail.get(
                            "inheritedFrom", ""
                        ),
                        "permission_detail_permission_type": selected_detail.get(
                            "permissionType", ""
                        ),
                        "permission_detail_role": selected_detail.get("role", ""),
                        "permission_details_json": json_compact(details),
                        "permission_raw_json": json_compact(permission),
                    }
                )
                rows_written += 1

    print(
        json.dumps(
            {
                "permission_files_seen": permission_files_seen,
                "audit_row_count": rows_written,
                "shared_item_count": len(shared_items_by_id),
            }
        )
    )
    return 0


def normalise_row(row: dict[str, str]) -> dict[str, str]:
    return {
        (key or "").strip().lower(): (value or "").strip()
        for key, value in row.items()
    }


def first_present(row: dict[str, str], names: list[str]) -> str:
    for name in names:
        value = row.get(name, "").strip()
        if value:
            return value
    return ""


def is_truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "y"}


def load_permissions_file(path: pathlib.Path) -> list[dict[str, Any]]:
    permissions: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            page = json.loads(line)
            permissions.extend(page.get("permissions") or [])
    return permissions


def planning_skip(
    *,
    target: dict[str, Any],
    reason: str,
    permission: dict[str, Any] | None = None,
    permission_id: str = "",
) -> dict[str, Any]:
    permission = permission or {}
    return {
        "stage": "planning",
        "reason": reason,
        "file_id": target.get("file_id", ""),
        "permission_id": permission_id or permission.get("id", ""),
        "shared_drive_name": target.get("shared_drive_name", ""),
        "item_path": target.get("item_path", ""),
        "permission_type": permission.get("type", ""),
        "permission_role": permission.get("role", ""),
        "permission_email_address": permission.get("emailAddress", ""),
        "permission_domain": permission.get("domain", ""),
    }


def build_validated_action(
    target: dict[str, Any],
    permission: dict[str, Any],
    include_management_roles: bool,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    permission_id = permission.get("id", "")
    role = permission.get("role", "")
    details = permission.get("permissionDetails") or []
    direct_details = [
        detail for detail in details if detail.get("inherited") is False
    ]

    if not permission_id:
        return None, planning_skip(
            target=target,
            reason="permission is missing an id",
            permission=permission,
        )

    if not details:
        return None, planning_skip(
            target=target,
            reason="permissionDetails missing; refusing to infer directness",
            permission=permission,
        )

    if not direct_details:
        return None, planning_skip(
            target=target,
            reason="skipping inherited-only permission",
            permission=permission,
        )

    if role in MANAGEMENT_ROLES and not include_management_roles:
        return None, planning_skip(
            target=target,
            reason="skipping management role by default",
            permission=permission,
        )

    return (
        {
            "mode": target.get("mode", ""),
            "row_number": target.get("row_number"),
            "file_id": target.get("file_id", ""),
            "permission_id": permission_id,
            "shared_drive_name": target.get("shared_drive_name", ""),
            "item_name": target.get("item_name", ""),
            "item_path": target.get("item_path", ""),
            "permission_type": permission.get("type", ""),
            "permission_role": role,
            "permission_email_address": permission.get("emailAddress", ""),
            "permission_domain": permission.get("domain", ""),
        },
        None,
    )


def build_remediation_targets(args: argparse.Namespace) -> int:
    input_rows = 0
    targets: list[dict[str, Any]] = []
    skips: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] | set[tuple[str, str]] = set()

    with open(args.input_csv, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise SystemExit("Input CSV must contain a header row.")

        for row_number, row in enumerate(reader, start=2):
            input_rows += 1
            data = normalise_row(row)

            file_id = first_present(data, ["file_id", "item_id"])
            shared_drive_name = first_present(data, ["shared_drive_name", "drive_name"])
            item_path = first_present(data, ["item_path", "path"])
            item_name = first_present(data, ["item_name", "name"])

            if args.mode == "revoke-permission":
                permission_id = first_present(data, ["permission_id"])
                if not file_id or not permission_id:
                    skips.append(
                        {
                            "stage": "input",
                            "reason": (
                                "revoke-permission mode requires file_id/item_id "
                                "and permission_id"
                            ),
                            "row_number": row_number,
                            "file_id": file_id,
                            "permission_id": permission_id,
                            "shared_drive_name": shared_drive_name,
                            "item_path": item_path,
                        }
                    )
                    continue

                if is_truthy(first_present(data, ["permission_is_inherited_only"])):
                    skips.append(
                        {
                            "stage": "input",
                            "reason": "refusing to delete inherited-only permission row",
                            "row_number": row_number,
                            "file_id": file_id,
                            "permission_id": permission_id,
                            "shared_drive_name": shared_drive_name,
                            "item_path": item_path,
                        }
                    )
                    continue

                permission_is_direct = first_present(data, ["permission_is_direct"])
                if permission_is_direct.lower() == "false":
                    skips.append(
                        {
                            "stage": "input",
                            "reason": "refusing to delete non-direct permission row",
                            "row_number": row_number,
                            "file_id": file_id,
                            "permission_id": permission_id,
                            "shared_drive_name": shared_drive_name,
                            "item_path": item_path,
                        }
                    )
                    continue

                dedupe_key = (args.mode, file_id, permission_id)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)

                targets.append(
                    {
                        "mode": args.mode,
                        "row_number": row_number,
                        "file_id": file_id,
                        "permission_id": permission_id,
                        "shared_drive_name": shared_drive_name,
                        "item_name": item_name,
                        "item_path": item_path,
                        "permission_type": first_present(data, ["permission_type"]),
                        "permission_role": first_present(data, ["permission_role"]),
                        "permission_email_address": first_present(
                            data, ["permission_email_address"]
                        ),
                        "permission_domain": first_present(
                            data, ["permission_domain"]
                        ),
                    }
                )
            else:
                if not file_id:
                    skips.append(
                        {
                            "stage": "input",
                            "reason": "unshare-all-direct mode requires file_id/item_id",
                            "row_number": row_number,
                            "file_id": file_id,
                            "shared_drive_name": shared_drive_name,
                            "item_path": item_path,
                        }
                    )
                    continue

                dedupe_key = (args.mode, file_id)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)

                targets.append(
                    {
                        "mode": args.mode,
                        "row_number": row_number,
                        "file_id": file_id,
                        "shared_drive_name": shared_drive_name,
                        "item_name": item_name,
                        "item_path": item_path,
                    }
                )

    with open(args.targets_jsonl, "w", encoding="utf-8") as handle:
        for target in targets:
            handle.write(json.dumps(target, ensure_ascii=False) + "\n")

    with open(args.skips_jsonl, "a", encoding="utf-8") as handle:
        for skip in skips:
            handle.write(json.dumps(skip, ensure_ascii=False) + "\n")

    print(
        json.dumps(
            {
                "input_row_count": input_rows,
                "target_count": len(targets),
                "skip_count": len(skips),
            }
        )
    )
    return 0


def build_delete_actions(args: argparse.Namespace) -> int:
    permissions_dir = pathlib.Path(args.permissions_dir)
    include_management_roles = args.include_management_roles.lower() == "true"
    targets = load_jsonl(args.targets_jsonl)
    actions: list[dict[str, Any]] = []
    skips: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    for target in targets:
        file_id = target.get("file_id", "")
        permission_path = permissions_dir / f"{file_id}.ndjson"
        if not permission_path.exists():
            skips.append(
                planning_skip(
                    target=target,
                    reason=(
                        "permission snapshot missing; unable to validate "
                        "delete action"
                    ),
                    permission_id=target.get("permission_id", ""),
                )
            )
            continue

        permissions = load_permissions_file(permission_path)

        if target.get("mode") == "revoke-permission":
            wanted_permission_id = target.get("permission_id", "")
            matched_permission = next(
                (
                    permission
                    for permission in permissions
                    if permission.get("id", "") == wanted_permission_id
                ),
                None,
            )

            if matched_permission is None:
                skips.append(
                    planning_skip(
                        target=target,
                        reason="permission_id not found in live permission snapshot",
                        permission_id=wanted_permission_id,
                    )
                )
                continue

            action, skip = build_validated_action(
                target,
                matched_permission,
                include_management_roles,
            )
            if skip is not None:
                skips.append(skip)
                continue

            dedupe_key = (file_id, wanted_permission_id)
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)

            if action is not None:
                actions.append(action)
            continue

        for permission in permissions:
            permission_id = permission.get("id", "")
            action, skip = build_validated_action(
                target,
                permission,
                include_management_roles,
            )
            if skip is not None:
                skips.append(skip)
                continue

            dedupe_key = (file_id, permission_id)
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)

            if action is not None:
                actions.append(action)

    with open(args.planned_actions_jsonl, "w", encoding="utf-8") as handle:
        for action in actions:
            handle.write(json.dumps(action, ensure_ascii=False) + "\n")

    with open(args.skips_jsonl, "a", encoding="utf-8") as handle:
        for skip in skips:
            handle.write(json.dumps(skip, ensure_ascii=False) + "\n")

    print(
        json.dumps(
            {
                "planned_action_count": len(actions),
                "planning_skip_count": len(skips),
            }
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Helper commands for google-drive-auditing shell workflows."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("build-inventory-reports")
    inventory_parser.add_argument("inventory_jsonl")
    inventory_parser.add_argument("resolved_jsonl")
    inventory_parser.add_argument("inventory_csv")
    inventory_parser.add_argument("shared_items_jsonl")
    inventory_parser.add_argument("permissions_scope")
    inventory_parser.set_defaults(func=build_inventory_reports)

    audit_parser = subparsers.add_parser("build-audit-csv")
    audit_parser.add_argument("shared_items_jsonl")
    audit_parser.add_argument("permissions_dir")
    audit_parser.add_argument("audit_csv")
    audit_parser.add_argument("include_inherited")
    audit_parser.set_defaults(func=build_audit_csv)

    remediation_targets_parser = subparsers.add_parser("build-remediation-targets")
    remediation_targets_parser.add_argument("input_csv")
    remediation_targets_parser.add_argument("mode")
    remediation_targets_parser.add_argument("targets_jsonl")
    remediation_targets_parser.add_argument("skips_jsonl")
    remediation_targets_parser.set_defaults(func=build_remediation_targets)

    delete_actions_parser = subparsers.add_parser("build-delete-actions")
    delete_actions_parser.add_argument("targets_jsonl")
    delete_actions_parser.add_argument("permissions_dir")
    delete_actions_parser.add_argument("planned_actions_jsonl")
    delete_actions_parser.add_argument("skips_jsonl")
    delete_actions_parser.add_argument("include_management_roles")
    delete_actions_parser.set_defaults(func=build_delete_actions)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
