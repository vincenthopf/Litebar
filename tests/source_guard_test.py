import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_source.py"
SPEC = importlib.util.spec_from_file_location("check_source", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class SourceGuardTests(unittest.TestCase):
    def validate(self, extra: dict[str, str], omit: str = "") -> list[str]:
        files = {"LICENSE": "license", "NOTICE": "attribution", "Cargo.toml": '[package]\nname = "fixture"\n'}
        files.update(extra)
        files.pop(omit, None)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            return GUARD.validate(root, list(files))

    def test_native_platform_and_legacy_test_doubles_are_allowed(self):
        self.assertEqual(self.validate({"native/UI.swift": "import AppKit\nimport Carbon.HIToolbox\n", "tests/legacy/support.swift": "import Foundation\n"}), [])

    def test_original_app_cannot_return(self):
        self.assertTrue(self.validate({"Ice/Controller.swift": "import AppKit\n"}))
        self.assertTrue(self.validate({"ice/Controller.swift": "import AppKit\n"}))

    def test_renamed_legacy_swift_cannot_be_vendored(self):
        self.assertTrue(self.validate({"archive/Controller.swift": "import AppKit\n"}))

    def test_old_assets_and_workflows_cannot_return(self):
        for path in ["Resources/Icon.png", ".swiftlint.yml", ".github/workflows/lint.yml", ".github/workflows/development-toolchain.yml"]:
            with self.subTest(path=path):
                self.assertTrue(self.validate({path: "old content"}))

    def test_xcode_and_swift_packages_cannot_return(self):
        for path in ["Renamed.xcodeproj/project.pbxproj", "Renamed.xcworkspace/contents.xcworkspacedata", "native/Package.resolved", "Package.swift"]:
            with self.subTest(path=path):
                self.assertTrue(self.validate({path: "old build"}))

    def test_removed_runtime_frameworks_cannot_return(self):
        for module in ["SwiftUI", "Combine", "Sparkle", "AXSwift", "CompactSlider", "Ifrit", "LaunchAtLogin"]:
            with self.subTest(module=module):
                self.assertTrue(self.validate({"native/UI.swift": f"@preconcurrency import {module}\n"}))

    def test_cargo_target_specific_dependencies_are_rejected(self):
        for table in ["dependencies", "dev-dependencies", "build-dependencies", "target.'cfg(target_os = \"macos\")'.dependencies"]:
            with self.subTest(table=table):
                self.assertTrue(self.validate({"Cargo.toml": f'[{table}]\nexample = "1"\n'}))

    def test_missing_attribution_is_rejected(self):
        for name in ["LICENSE", "NOTICE"]:
            with self.subTest(name=name):
                self.assertTrue(self.validate({}, omit=name))


if __name__ == "__main__":
    unittest.main()
