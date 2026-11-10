#!/usr/bin/env python3
"""Static checks for the playbook source tree and the built package. No VM, no network.

  python tools/verify_playbook.py                         source checks (CI job "verify")
  python tools/verify_playbook.py --ps51                  also parse every script with Windows PowerShell 5.1
  python tools/verify_playbook.py --package X.apbx --version 26.11
                                                          verify the built archive (CI, after "Archive content")

Source checks: every YAML under src/Configuration parses; only known `!tags`; registry `data:` is a quoted string;
every `option:` exists in playbook.conf; every `!task` path and every Executable a step names exists; the playbook has
its own identity (not ReviOS's); line endings are not mixed; scripts that run on Windows PowerShell 5.1 are ASCII.
Exit code 1 when any error is found. Warnings never fail the run.

Needs PyYAML (pip install pyyaml; or: uv run --with pyyaml tools/verify_playbook.py).
"""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
CONFIG = SRC / "Configuration"
EXE_DIR = SRC / "Executables"

# AME action tags this repo uses. A new valid AME action goes here on purpose, so a typo cannot slip through.
KNOWN_TAGS = {
    "registryValue", "registryKey", "task", "powerShell", "writeStatus", "run", "service",
    "taskKill", "file", "cmd", "appx", "download",
}
REG_TYPES = {"REG_DWORD", "REG_QWORD", "REG_SZ", "REG_EXPAND_SZ", "REG_MULTI_SZ", "REG_BINARY", "REG_NONE"}
# Scripts whose own header says "ASCII-only (Windows PowerShell 5.1)": BOM-less UTF-8 is read as ANSI there.
# Files the CI build adds to Executables (git-ignored, so not in src/); `--package` checks that they ship.
CI_SUPPLIED = {"WinDebloatTool-Setup.exe"}
# Option names a task uses that playbook.conf does not define, reported as a warning (known, decision pending), not an error.
# (Empty: `configure-explorer-taskbar-animations` was the only one and is defined now.)
KNOWN_UNDEFINED_OPTIONS = {}
ASCII_GLOBS = [("src/Executables", "*.ps1"), ("src/Executables", "*.cmd"), ("tools/vmtest", "*.ps1"), ("tools", "*.ps1")]

errors, warnings = [], []


def err(where, msg):
    errors.append(f"{where}: {msg}")


def warn(where, msg):
    warnings.append(f"{where}: {msg}")


def rel(p):
    try:
        return str(Path(p).relative_to(ROOT)).replace("\\", "/")
    except ValueError:
        return str(p)


class Tagged:
    def __init__(self, tag, value, line):
        self.tag, self.value, self.line = tag, value, line


class AmeLoader(yaml.SafeLoader):
    """SafeLoader that accepts AME's `!action:` tags and keeps them as Tagged(tag, mapping, line)."""


def _construct_tag(loader, suffix, node):
    if isinstance(node, yaml.MappingNode):
        value = loader.construct_mapping(node, deep=True)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_scalar(node)
    return Tagged(suffix.rstrip(":"), value, node.start_mark.line + 1)


AmeLoader.add_multi_constructor("!", _construct_tag)


def load_conf():
    conf = SRC / "playbook.conf"
    try:
        tree = ET.parse(conf)
    except ET.ParseError as e:
        err(rel(conf), f"does not parse as XML: {e}")
        return None, set()
    pages = tree.getroot().find("FeaturePages")
    names = {n.text.strip() for n in (pages.iter("Name") if pages is not None else []) if n.text and n.text.strip()}
    return tree.getroot(), names


def check_identity(root):
    if root is None:
        return
    for field in ("Name", "Username", "Title"):
        text = (root.findtext(field) or "").strip()
        if re.search(r"revi\s*os|revision", text, re.I):
            err("src/playbook.conf", f"<{field}> is '{text}': the playbook must have its own identity, not ReviOS (AME flags it as malicious)")
    git = (root.findtext("Git") or "")
    if "meetrevision" in git.lower():
        err("src/playbook.conf", f"<Git> points at {git}")


def walk(value):
    """Yield every Tagged inside a loaded YAML value."""
    if isinstance(value, Tagged):
        yield value
        yield from walk(value.value)
    elif isinstance(value, dict):
        for v in value.values():
            yield from walk(v)
    elif isinstance(value, list):
        for v in value:
            yield from walk(v)


def option_names(spec):
    if isinstance(spec, str):
        return [spec]
    if isinstance(spec, list):
        return [s for s in spec if isinstance(s, str)]
    return []


def exe_target(item):
    """Name of the Executables file a step runs from the package folder, or None."""
    v = item.value if isinstance(item.value, dict) else {}
    if not v.get("exeDir"):
        return None
    if item.tag in ("powerShell", "cmd"):
        m = re.match(r"\s*['\"]?(?:\.\\|\./)?([\w.\-]+\.(?:ps1|cmd|bat|exe))", str(v.get("command", "")))
        return m.group(1) if m else None
    if item.tag == "run":
        return str(v["exe"]) if v.get("exe") else None
    return None


def downloaded_names(doc):
    out = set()
    for item in walk(doc.get("actions")):
        if item.tag == "download" and isinstance(item.value, dict) and item.value.get("destination"):
            out.add(Path(str(item.value["destination"])).name.lower())
    return out


def check_yaml(options_defined, used_options):
    files = sorted(CONFIG.rglob("*.yml"))
    for f in files:
        where = rel(f)
        try:
            doc = yaml.load(f.read_text(encoding="utf-8"), Loader=AmeLoader)
        except Exception as e:
            err(where, f"does not parse: {str(e).splitlines()[0] if str(e) else e}")
            continue
        if not isinstance(doc, dict) or "actions" not in doc:
            err(where, "no `actions:` list at the top level")
            continue
        downloads = downloaded_names(doc)
        for item in walk(doc.get("actions")):
            at = f"{where}:{item.line}"
            if item.tag not in KNOWN_TAGS:
                err(at, f"unknown action tag !{item.tag} (a valid new AME action must be added to KNOWN_TAGS)")
                continue
            v = item.value if isinstance(item.value, dict) else {}
            for key in ("option", "options"):
                for name in option_names(v.get(key)):
                    base = name.lstrip("!")
                    used_options.add(base)
                    if base in KNOWN_UNDEFINED_OPTIONS:
                        warn(at, f"{key} '{name}' is not defined in playbook.conf ({KNOWN_UNDEFINED_OPTIONS[base]})")
                    elif base not in options_defined:
                        err(at, f"{key} '{name}' is not defined in playbook.conf")
            if item.tag == "registryValue":
                if not v.get("path") or "value" not in v:   # value '' is the key's (Default) value
                    err(at, "registryValue needs path and value")
                if v.get("operation", "add") == "add":
                    if not isinstance(v.get("data"), str):
                        err(at, f"data must be a quoted string, got {type(v.get('data')).__name__} ({v.get('data')!r})")
                    if v.get("type") not in REG_TYPES:
                        err(at, f"unknown registry type {v.get('type')!r}")
                if not re.match(r"^(HKLM|HKCU|HKU|HKCR|HKCC)\\", str(v.get("path", ""))):
                    err(at, f"path must start with a hive: {v.get('path')!r}")
            elif item.tag == "task":
                target = CONFIG / str(v.get("path", "")).replace("\\", "/")
                if not target.is_file():
                    err(at, f"!task path not found: {v.get('path')}")
            exe = exe_target(item)
            # A bare name ("PowerShell") is a system command; a file this task downloads first is not in src/ either.
            if exe and Path(exe).suffix and exe.lower() not in downloads and exe not in CI_SUPPLIED and not (EXE_DIR / exe).is_file():
                err(at, f"{exe} is run from the package folder (exeDir) but is not in src/Executables")


def check_encoding():
    texts = [p for p in SRC.rglob("*") if p.is_file() and p.suffix.lower() in {".yml", ".ps1", ".cmd", ".conf", ".py"}]
    texts += [p for p in (ROOT / "tools").rglob("*.ps1")]
    for p in texts:
        b = p.read_bytes()
        crlf, lf = b.count(b"\r\n"), b.count(b"\n")
        if 0 < crlf < lf:
            err(rel(p), f"mixed line endings ({crlf} CRLF of {lf} lines)")
    for folder, pattern in ASCII_GLOBS:
        for p in sorted((ROOT / folder).glob(pattern)):
            bad = [i + 1 for i, line in enumerate(p.read_bytes().split(b"\n")) if any(c > 127 for c in line)]
            if bad:
                err(rel(p), f"non-ASCII on line(s) {bad[:5]}: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI")


PS_PARSE = r"""
$bad = 0
foreach ($f in $args) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    foreach ($e in $errs) { $bad++; "PARSE|$f|$($e.Extent.StartLineNumber)|$($e.Message)" }
}
exit $(if ($bad) { 1 } else { 0 })
"""


def check_ps51():
    exe = shutil.which("powershell.exe") or shutil.which("powershell")
    if not exe or sys.platform != "win32":
        warn("ps51", "Windows PowerShell 5.1 not available here; scripts were not parsed")
        return
    scripts = sorted(set((EXE_DIR).glob("*.ps1")) | set((ROOT / "tools" / "vmtest").glob("*.ps1")) | set((ROOT / "tools").glob("*.ps1")))
    with tempfile.TemporaryDirectory() as td:
        helper = Path(td) / "parse.ps1"
        helper.write_text(PS_PARSE, encoding="ascii")
        r = subprocess.run([exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(helper)] + [str(s) for s in scripts],
                           capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("PARSE|"):
            _, f, n, msg = line.split("|", 3)
            err(f"{rel(f)}:{n}", f"PowerShell 5.1 parse error: {msg}")
    if r.returncode not in (0, 1):
        err("ps51", f"parser run failed (exit {r.returncode}): {r.stderr.strip()[:200]}")
    print(f"parsed {len(scripts)} script(s) with Windows PowerShell 5.1")


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def extract(archive, dest):
    """Extract a .zip natively, or a password-protected .apbx (7z, AES, encrypted headers) with 7z or py7zr.
    Returns an error text, or None on success."""
    archive = Path(archive)
    if archive.suffix.lower() == ".zip":
        with zipfile.ZipFile(archive) as z:
            z.extractall(dest)
        return None
    seven = shutil.which("7z") or shutil.which("7za") or next((str(p) for p in (Path(r"C:\Program Files\7-Zip\7z.exe"),) if p.exists()), None)
    if seven:
        r = subprocess.run([seven, "x", "-pmalte", f"-o{dest}", "-y", str(archive)], capture_output=True, text=True)
        return None if r.returncode == 0 else f"7z failed: {r.stdout.strip()[-200:]}"
    try:
        import py7zr
    except ImportError:
        return "neither 7z nor py7zr is available to open the .apbx"
    with py7zr.SevenZipFile(archive, password="malte") as z:
        z.extractall(path=dest)
    return None


def check_package(archive, version):
    with tempfile.TemporaryDirectory() as td:
        problem = extract(archive, td)
        if problem:
            err("package", f"cannot extract {archive}: {problem}")
            return
        out = Path(td)
        got = {p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file()}
        want = {p.relative_to(SRC).as_posix() for p in SRC.rglob("*") if p.is_file()}
        # The CI installer is added to Executables and the source tree may not hold it.
        extra_ok = {"Executables/WinDebloatTool-Setup.exe"}
        for missing in sorted(want - got):
            err("package", f"{missing} is in src/ but not in the archive")
        for extra in sorted(got - want - extra_ok):
            err("package", f"{extra} is in the archive but not in src/")
        setup = out / "Executables" / "WinDebloatTool-Setup.exe"
        if not setup.is_file() or setup.stat().st_size < 1_000_000:
            err("package", "Executables/WinDebloatTool-Setup.exe is missing or smaller than 1 MB")
        # playbook.conf and FINALIZE.cmd get the version stamped by the workflow, so their bytes differ by design.
        for name in sorted((want & got) - {"playbook.conf", "Executables/FINALIZE.cmd"}):
            if sha(SRC / name) != sha(out / name):
                err("package", f"{name} differs between src/ and the archive")
        conf = out / "playbook.conf"
        if conf.is_file():
            try:
                v = (ET.parse(conf).getroot().findtext("Version") or "").strip()
                if version and v != version:
                    err("package", f"playbook.conf <Version> is '{v}', expected '{version}'")
            except ET.ParseError as e:
                err("package", f"playbook.conf in the archive does not parse: {e}")
        fin = out / "Executables" / "FINALIZE.cmd"
        if version and fin.is_file() and f"set version={version}" not in fin.read_text(encoding="utf-8", errors="replace"):
            err("package", f"FINALIZE.cmd does not set version={version}")
        print(f"package: {len(got)} file(s) extracted and compared")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ps51", action="store_true", help="parse scripts with Windows PowerShell 5.1 (Windows only)")
    ap.add_argument("--package", help="built .apbx/.zip to verify against src/")
    ap.add_argument("--version", help="expected version stamped into the package")
    a = ap.parse_args()

    if a.package:
        check_package(a.package, a.version)
    else:
        root, options = load_conf()
        check_identity(root)
        used = set()
        check_yaml(options, used)
        check_encoding()
        if a.ps51:
            check_ps51()
        for unused in sorted(options - used):
            warn("src/playbook.conf", f"option '{unused}' is not referenced by any task")
    for w in warnings:
        print("warning:", w)
    for e in errors:
        print("ERROR:", e)
    print(f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
