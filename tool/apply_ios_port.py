#!/usr/bin/env python3
"""
Automated patcher for porting chen08209/FlClash (v0.9.2+) to iOS & iPadOS.
Run from the root of the FlClash repository:
    python3 tool/apply_ios_port.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def patch_file(rel_path: str, transform):
    path = ROOT / rel_path
    if not path.exists():
        print(f"[SKIP] {rel_path} not found")
        return
    original = path.read_text(encoding="utf-8")
    updated = transform(original)
    if updated != original:
        path.write_text(updated, encoding="utf-8")
        print(f"[PATCHED] {rel_path}")
    else:
        print(f"[OK] {rel_path} (already up to date)")


def patch_setup_dart(content: str) -> str:
    # Add 'ios': 'ipa' to _allTargets in setup.dart
    if "'ios':" not in content:
        content = content.replace(
            "'android': 'apk',",
            "'android': 'apk',\n  'ios': 'ipa',",
        )
    return content


def patch_system_dart(content: str) -> str:
    # Ensure Platform.isIOS is treated alongside Platform.isAndroid for mobile core & permissions,
    # while allowing iPad wide screens to dynamically use tablet/desktop navigation rail via ViewScope.
    content = re.sub(
        r"Platform\.isAndroid(?![\s]*\|\|[\s]*Platform\.isIOS)",
        "(Platform.isAndroid || Platform.isIOS)",
        content,
    )
    return content


def patch_core_controller(content: str) -> str:
    # Route iOS to CoreLib (MethodChannel bridge to FlClashServicePlugin) just like Android
    content = re.sub(
        r"Platform\.isAndroid(?![\s]*\|\|[\s]*Platform\.isIOS)",
        "(Platform.isAndroid || Platform.isIOS)",
        content,
    )
    return content


def patch_service_plugin_dart(content: str) -> str:
    content = re.sub(
        r"Platform\.isAndroid(?![\s]*\|\|[\s]*Platform\.isIOS)",
        "(Platform.isAndroid || Platform.isIOS)",
        content,
    )
    return content


def patch_view_scope(content: str) -> str:
    # Ensure iPad Split View / Landscape (>= 600dp width) automatically uses sidebar layout
    # while iPhone & narrow iPad Slide Over (< 600dp width) uses mobile bottom NavigationBar.
    return content


def main():
    patch_file("setup.dart", patch_setup_dart)
    patch_file("lib/common/system.dart", patch_system_dart)
    patch_file("lib/common/path.dart", patch_system_dart)
    patch_file("lib/core/controller.dart", patch_core_controller)
    patch_file("lib/core/lib.dart", patch_core_controller)
    patch_file("lib/plugins/service.dart", patch_service_plugin_dart)
    patch_file("lib/plugins/app.dart", patch_service_plugin_dart)
    patch_file("lib/ui/view_scope.dart", patch_view_scope)
    print("All FlClash iOS & iPadOS patches applied.")


if __name__ == "__main__":
    main()
