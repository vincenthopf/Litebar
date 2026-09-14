import re
import subprocess
import sys
import tomllib
from pathlib import Path, PurePosixPath

LEGACY_PATHS = (
    "ice",
    "resources",
    ".gitattributes",
    ".swiftlint.yml",
    ".github/workflows/lint.yml",
    ".github/workflows/development-toolchain.yml",
)
SWIFT_ROOTS = ("native/", "tests/native/", "tests/legacy/")
APPLE_MODULES = {
    "AppKit", "ApplicationServices", "Carbon", "CoreFoundation",
    "CoreGraphics", "Darwin", "Foundation", "ScreenCaptureKit",
    "Security", "ServiceManagement",
}
IMPORT = re.compile(r"\bimport\s+(?:(?:class|enum|func|let|protocol|struct|typealias|var)\s+)?([A-Za-z_]\w*)")


def dependency_tables(value: dict, prefix: str = "") -> list[str]:
    found = []
    for key, child in value.items():
        name = f"{prefix}.{key}" if prefix else key
        if key in {"dependencies", "dev-dependencies", "build-dependencies"} and child:
            found.append(name)
        elif isinstance(child, dict):
            found.extend(dependency_tables(child, name))
    return found


def validate(root: Path, paths: list[str]) -> list[str]:
    errors = []
    for path in paths:
        normalized = path.casefold()
        parts = PurePosixPath(normalized).parts
        if any(normalized == old or normalized.startswith(old + "/") for old in LEGACY_PATHS):
            errors.append(f"Legacy path is tracked: {path}")
        if any(part.endswith((".xcodeproj", ".xcworkspace")) for part in parts) or parts[-1] in {"package.swift", "package.resolved"}:
            errors.append(f"Legacy build system is tracked: {path}")
        if normalized.endswith(".swift") and not path.startswith(SWIFT_ROOTS):
            errors.append(f"Swift source is outside the native adapter or tests: {path}")
        if path.startswith("native/") and normalized.endswith(".swift"):
            for module in IMPORT.findall((root / path).read_text(encoding="utf-8")):
                if module not in APPLE_MODULES:
                    errors.append(f"Unapproved runtime framework in {path}: {module}")
    for required in ("LICENSE", "NOTICE", "Cargo.toml"):
        if required not in paths or not (root / required).is_file():
            errors.append(f"Required file is missing: {required}")
    if (root / "Cargo.toml").is_file():
        manifest = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))
        errors.extend(f"Rust dependency table is not empty: {name}" for name in dependency_tables(manifest))
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True)
    paths = [path for path in result.stdout.decode("utf-8").split("\0") if path]
    errors = validate(root, paths)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Source validation passed: {len(paths)} tracked files, no legacy app or third-party runtime dependencies.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Source validation failed: {error}", file=sys.stderr)
        sys.exit(1)
