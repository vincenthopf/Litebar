import hashlib
import json
from pathlib import Path
import subprocess
import sys

BASE = "11edd39115f3f43a83ae114b5348df6a0e1741cf"
SOURCES = {
    "Ice/Utilities/Predicates.swift": "64c4c9f9a680ac7854eba9f5cca3ed9b239ea2cb",
    "Ice/MenuBar/MenuBarItems/MenuBarItemInfo.swift": "405a35cae3e66d34b716755c7e7e7003cbbf5430",
    "Ice/MenuBar/MenuBarSection.swift": "b1157d37781c463c2c9932c82b8966e768fe65b7",
    "Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift": "68694d0dcda9f30099728ba14ade04a0f71e211a",
}


def verified_source(root: Path, name: str) -> str:
    content = (root / name).read_bytes()
    blob = b"blob " + str(len(content)).encode() + b"\0" + content
    if hashlib.sha1(blob).hexdigest() != SOURCES[name]:
        raise RuntimeError("Pinned original source changed: " + name)
    return content.decode()


def declaration(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError("Unbalanced declaration: " + signature)
    return source[start:end] + "\n"


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    predicates = verified_source(root, "Ice/Utilities/Predicates.swift")
    identity = verified_source(root, "Ice/MenuBar/MenuBarItems/MenuBarItemInfo.swift")
    sections = verified_source(root, "Ice/MenuBar/MenuBarSection.swift")
    events = verified_source(root, "Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift")
    generic = declaration(predicates, "enum Predicates<Input>")
    section = declaration(predicates, "extension Predicates where Input == MenuBarItem")
    helpers = events[events.index("private enum MenuBarItemEventButtonState"):events.rindex("// MARK: - Logger")]
    source = Path(__file__).with_name("support.swift").read_text()
    for signature in ["var isHidden: Bool", "func show()", "func hide()", "func toggle()"]:
        source = source.replace("__" + signature + "__", declaration(sections, signature))
    source += generic + section + identity
    source += "\n#if canImport(CoreGraphics)\n" + helpers + "\n#endif\n"
    source += Path(__file__).with_name("runner.swift").read_text()
    generated = output / "legacy-main.swift"
    generated.write_text(source)
    executable = output / "legacy-contract"
    subprocess.run(["swiftc", "-Onone", str(generated), "-o", str(executable)], check=True)
    with (output / "legacy-contract.tsv").open("w") as stream:
        subprocess.run([str(executable), str(Path(__file__).resolve().parents[1] / "fixtures")], stdout=stream, check=True)
    paths = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and ".git" not in path.relative_to(root).parts)
    swift = [path for path in paths if path.endswith(".swift")]
    inventory = {
        "base_commit": BASE,
        "snapshot_files": len(paths),
        "swift_files": len(swift),
        "swift_lines": sum(len((root / path).read_text().splitlines()) for path in swift),
        "test_named_paths": [path for path in paths if "test" in Path(path).name.lower()],
        "source_blob_shas": SOURCES,
        "contract_scope": "Original section predicates, classic section transitions with platform doubles, item coding/restrictions, and CGEvent fields. Not end-to-end GUI or event-delivery coverage.",
        "files": paths,
    }
    (output / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print(json.dumps({key: value for key, value in inventory.items() if key != "files"}, indent=2))


if __name__ == "__main__":
    main()
