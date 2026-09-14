import hashlib
import json
from pathlib import Path
import subprocess
import sys

BASE = "11edd39115f3f43a83ae114b5348df6a0e1741cf"
SOURCES = {
    "Ice/Utilities/Predicates.swift": "64c4c9f9a680ac7854eba9f5cca3ed9b239ea2cb",
    "Ice/MenuBar/MenuBarItems/MenuBarItemInfo.swift": "405a35cae3e66d34b716755c7e7e7003cbbf5430",
}


def verified_source(root, name):
    content = (root / name).read_bytes()
    blob = b"blob " + str(len(content)).encode() + b"\0" + content
    if hashlib.sha1(blob).hexdigest() != SOURCES[name]:
        raise RuntimeError("Pinned original source changed: " + name)
    return content.decode()


def main():
    root = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    predicates = verified_source(root, "Ice/Utilities/Predicates.swift")
    identity = verified_source(root, "Ice/MenuBar/MenuBarItems/MenuBarItemInfo.swift")
    generic = predicates[predicates.index("enum Predicates<Input>"):predicates.index("// MARK: - Window Predicates")]
    section = predicates[predicates.index("extension Predicates where Input == MenuBarItem"):predicates.index("// MARK: - Control Item Predicates")]
    support = '''import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
struct MenuBarItem { let frame: CGRect }
enum Constants { static let bundleIdentifier = "com.jordanbaird.Ice" }
enum ControlItem {
    enum Identifier: String {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }
}
'''
    runner = Path(__file__).with_name("runner.swift").read_text()
    source = output / "legacy-main.swift"
    source.write_text(support + generic + section + identity + runner)
    executable = output / "legacy-contract"
    subprocess.run(["swiftc", "-Onone", str(source), "-o", str(executable)], check=True)
    with (output / "legacy-contract.tsv").open("w") as stream:
        subprocess.run([str(executable), str(Path(__file__).resolve().parents[1] / "fixtures")], stdout=stream, check=True)
    paths = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and ".git" not in path.relative_to(root).parts)
    swift = [path for path in paths if path.endswith(".swift")]
    tests = [path for path in paths if "test" in Path(path).name.lower()]
    inventory = {
        "base_commit": BASE,
        "tracked_snapshot_files": len(paths),
        "swift_files": len(swift),
        "swift_lines": sum(len((root / path).read_text().splitlines()) for path in swift),
        "test_named_paths": tests,
        "source_blob_shas": SOURCES,
        "contract_scope": "Original section predicates and item identity coding and restrictions. Not a GUI or private-API test.",
        "files": paths,
    }
    (output / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print(json.dumps({key: value for key, value in inventory.items() if key != "files"}, indent=2))


if __name__ == "__main__":
    main()
