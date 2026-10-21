"""AME playbook plan + log summariser for tools/vmtest.ps1.

    python amelog.py summarize --config <src/Configuration> --options-file <options.txt>
                                   --logs <collected logs dir> --out <summary.json>
                                   [--arch X64] [--upgrade]

The plan walks main.yml's !task tree with the engine's own applicability rules
(trusted-uninstaller-cli, TrustedUninstaller.Shared/AmeliorationUtil.cs: ParseActions,
IsApplicable, IsApplicableOption, IsApplicableArch). Actions gated out by those rules are
"skipped": AME never logs them, so they can only be derived from the YAML.

The engine writes one Output.txt block per executed action (DoActions opens one OutputWriter per
action), so executed actions are paired with blocks in order. Failures come from three places:
  * Log.yml entries of Type Error/Critical (what AME itself counts as "completed with errors"),
  * blocks whose process exited non-zero, which AME logs as Info and carries on (see
    docs/references-learnings.md: "AME does not stop on a failing !run/!powerShell"),
    unless the action is errorAction: Ignore / ignoreErrors: true, or the exit code is listed
    matched by the action's own handleExitCodes: map with Log/Retry (a plain errorAction: Log
    stays a failure: it is still an unhandled non-zero exit),
  * the wdtool support gate (exit code 55).
"""
import argparse
import json
import os
import re
import sys

import yaml


# --------------------------------------------------------------------------- YAML plan

class _Loader(yaml.SafeLoader):
    pass


def _tagged(loader, suffix, node):
    # `- !registryValue: {path: ...}` parses as tag "!registryValue:" on the flow mapping.
    tag = node.tag.lstrip("!").rstrip(":")
    if isinstance(node, yaml.MappingNode):
        value = dict(loader.construct_mapping(node, deep=True))
    elif isinstance(node, yaml.SequenceNode):
        value = {"_items": loader.construct_sequence(node, deep=True)}
    else:
        value = {"_value": loader.construct_scalar(node)}
    value["_tag"] = tag
    return value


_Loader.add_multi_constructor("!", _tagged)


def _norm_list(value):
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value]
    return [str(value)]


def option_ok(option, selected):
    """IsApplicableOption."""
    if option is None or str(option).strip() == "":
        return True
    option = str(option).strip()
    if "&" in option:
        return all(option_ok(part, selected) for part in option.split("&"))
    negative = option.startswith("!")
    name = option.lstrip("!").lower()
    present = name in selected
    return (not present) if negative else present


def arch_ok(arch, system_arch):
    if not arch:
        return True
    arch = str(arch)
    negative = arch.startswith("!")
    result = arch.lstrip("!").lower() == system_arch.lower()
    return (not result) if negative else result


def _truthy(value):
    return str(value).strip().lower() == "true"


def gate_reason(node, selected, system_arch, upgrade):
    """Return None when applicable, else why the engine skips it (live, non-ISO apply)."""
    on_upgrade = node.get("onUpgrade")
    if on_upgrade is not None and not upgrade and _truthy(on_upgrade):
        return "onUpgrade: true (fresh apply)"
    if not option_ok(node.get("option"), selected):
        return "option: %s" % node.get("option")
    if not arch_ok(node.get("cpuArch") or node.get("arch"), system_arch):
        return "cpuArch: %s" % (node.get("cpuArch") or node.get("arch"))
    opts = _norm_list(node.get("options"))
    if opts is not None:
        positives = [o for o in opts if not o.startswith("!")]
        negatives = [o for o in opts if o.startswith("!")]
        if not any(option_ok(o, selected) for o in positives) or any(not option_ok(o, selected) for o in negatives):
            return "options: %s" % ",".join(opts)
    oobe = str(node.get("oobe", "")).strip().lower()
    iso = str(node.get("iso", "")).strip().lower()
    if oobe == "only" and iso != "only":
        return "oobe: only"
    if iso == "only":
        return "iso: only"
    return None


def describe(action):
    tag = action.get("_tag", "?")
    fields = {k: v for k, v in action.items() if not k.startswith("_")}
    if "value" in fields and "path" in fields:
        text = "%s\\%s" % (fields["path"], fields["value"])
    else:
        for key in ("status", "path", "exeName", "exe", "command", "name", "packageName", "url"):
            if key in fields:
                text = str(fields[key])
                if key == "exe" and fields.get("args"):
                    text += " " + str(fields["args"])
                break
        else:
            text = json.dumps(fields, default=str)[:160]
    text = " ".join(text.split())
    return "%s: %s" % (tag, text[:200])


def build_plan(config_dir, selected, system_arch="X64", upgrade=False):
    plan = []

    def walk(rel_path, inherited_skip):
        full = os.path.join(config_dir, rel_path.replace("\\", os.sep))
        with open(full, "r", encoding="utf-8-sig") as handle:
            doc = yaml.load(handle, Loader=_Loader) or {}
        file_skip = inherited_skip or gate_reason(doc, selected, system_arch, upgrade)
        for index, action in enumerate(doc.get("actions") or []):
            if not isinstance(action, dict):
                continue
            reason = file_skip or gate_reason(action, selected, system_arch, upgrade)
            if action.get("_tag") == "task":
                walk(action["path"], reason and ("parent " + reason if not reason.startswith("parent") else reason))
                continue
            plan.append({
                "id": "%s#%d" % (rel_path.replace("\\", "/"), index + 1),
                "file": rel_path.replace("\\", "/"),
                "type": action.get("_tag"),
                "description": describe(action),
                "errorAction": str(action.get("errorAction", "")) or None,
                "ignoreErrors": _truthy(action.get("ignoreErrors", False)),
                "handleExitCodes": action.get("handleExitCodes"),
                "skipReason": reason,
            })

    walk("main.yml", None)
    return plan


# --------------------------------------------------------------------------- logs

# "[Info | 01:04:17] x", "[Warning | Log.yml:2 | 01:07:46] x", "[Process | Out | 01:04:18] x"
_LINE = re.compile(r"^\[(?P<type>[A-Za-z]+)(?: \| (?P<sub>[^\]|]+?))? \| (?P<time>\d\d:\d\d:\d\d)\] ?(?P<text>.*)$")
_STATUS = re.compile(r"^\[Status\] (?P<text>.*)$")
_NONZERO = re.compile(r"(?:non-zero exit code|exited with error code|exited with non-zero exit code):\s*(-?\d+)", re.I)


def read_text(path):
    with open(path, "rb") as handle:
        data = handle.read()
    # AME's Output.txt contains NUL padding (docs/references-learnings.md).
    return data.replace(b"\x00", b"").decode("utf-8", errors="replace")


def parse_output_blocks(text):
    blocks, current = [], None
    for raw in text.splitlines():
        if raw.strip() == "---":
            current = {"lines": []}
            blocks.append(current)
            continue
        if current is None:
            current = {"lines": []}
            blocks.append(current)
        current["lines"].append(raw)
    result = []
    for block in blocks:
        lines = [l for l in block["lines"] if l.strip()]
        if not lines:
            continue
        exit_code = None
        for line in lines:
            found = _NONZERO.search(line)
            if found:
                exit_code = int(found.group(1))
        entries = []
        for line in lines:
            if set(line.strip()) == {"-"}:
                continue  # writeStatus banner rule
            parsed = _LINE.match(line)
            status = _STATUS.match(line)
            if status:
                entries.append({"type": "Status", "text": status.group("text")})
            elif parsed:
                entries.append({"type": parsed.group("type"), "text": parsed.group("text")})
            elif entries:
                entries[-1]["text"] += "\n" + line
            else:
                entries.append({"type": "Raw", "text": line})
        result.append({"exitCode": exit_code, "entries": entries})
    return result


def parse_log_yml(path):
    if not os.path.exists(path):
        return []
    text = read_text(path)
    docs = []
    for chunk in re.split(r"(?m)^---\s*$", text):
        if not chunk.strip():
            continue
        try:
            value = yaml.safe_load(chunk)
        except yaml.YAMLError:
            value = {"Type": "Unparsed", "Message": chunk.strip()[:2000]}
        if isinstance(value, dict):
            docs.append(value)
    return docs


def find_first(logs_dir, name):
    for root, _dirs, files in os.walk(logs_dir):
        if name in files:
            return os.path.join(root, name)
    return None


def block_command(block):
    for entry in block["entries"]:
        if entry["text"].startswith("Running"):
            return entry["text"]
    return block["entries"][0]["text"] if block["entries"] else ""


def number_matches(spec, value):
    """TaskAction.IsApplicableNumber: '1605', '!0', '>=8', '<=7', '>3', '<3'."""
    spec = str(spec).strip()
    negative = spec.startswith("!")
    spec = spec.lstrip("!")
    for op, test in ((">=", lambda a, b: a >= b), ("<=", lambda a, b: a <= b),
                     (">", lambda a, b: a > b), ("<", lambda a, b: a < b)):
        if spec.startswith(op):
            result = test(value, int(spec[len(op):]))
            break
    else:
        result = value == int(spec)
    return (not result) if negative else result


def exit_code_handled(action, code):
    if action.get("ignoreErrors") or (action.get("errorAction") or "").lower() == "ignore":
        return True
    codes = action.get("handleExitCodes")
    if isinstance(codes, dict):
        for key, verdict in codes.items():
            # Only "Log" downgrades to info; Error/Halt/RetryError still fail the action.
            if number_matches(key, code) and str(verdict).lower() in ("log", "retry"):
                return True
    return False


def summarize(plan, logs_dir, cli_stdout=None):
    output_path = find_first(logs_dir, "Output.txt")
    log_path = find_first(logs_dir, "Log.yml")
    blocks = parse_output_blocks(read_text(output_path)) if output_path else []
    log_docs = parse_log_yml(log_path) if log_path else []

    executed = [a for a in plan if a["skipReason"] is None]
    skipped = [a for a in plan if a["skipReason"] is not None]

    applied, failed, unconfirmed = [], [], []
    # Every executed action, writeStatus included ("[Status] ..." banner), gets exactly one block.
    pairable = executed
    misaligned = []
    for i, action in enumerate(pairable):
        block = blocks[i] if i < len(blocks) else None
        record = {"id": action["id"], "description": action["description"]}
        if block is None:
            # No evidence it ran (engine stopped early, never started, or logged nothing).
            unconfirmed.append(record)
            continue
        is_status_block = any(e["type"] == "Status" for e in block["entries"])
        if is_status_block != (action["type"] in ("writeStatus", "status")):
            misaligned.append({"index": i, "id": action["id"], "logged": block_command(block)[:200]})
        if action["type"] in ("writeStatus", "status"):
            continue
        record["logged"] = block_command(block)[:300]
        errors = [e["text"].strip() for e in block["entries"] if e["type"] in ("Error", "Critical")]
        warnings = [e["text"].strip() for e in block["entries"] if e["type"] == "Warning"]
        if warnings:
            record["warnings"] = warnings[:5]
        code = block["exitCode"]
        reasons = []
        if code is not None and exit_code_handled(action, code):
            record["ignoredExitCode"] = code  # playbook opted out (errorAction: Ignore etc.)
        if code is not None and not exit_code_handled(action, code):
            reasons.append("exit code %d" % code + (" (wdtool support gate, see docs/references-learnings.md)" if code == 55 else ""))
        reasons += errors
        if reasons:
            output = [e["text"].strip() for e in block["entries"] if e["type"] == "Process" and e["text"].strip()]
            record["error"] = "; ".join(reasons)[:600]
            if output:
                record["output"] = output[-5:]
            failed.append(record)
        else:
            applied.append(record)

    engine_errors = []
    for doc in log_docs:
        level = str(doc.get("Type", "")).lower()
        if level in ("error", "critical"):
            message = str(doc.get("Message") or "").strip()
            exception = doc.get("Exception")
            if isinstance(exception, dict):
                message = (message + " " + str(exception.get("Message") or "")).strip()
            engine_errors.append({
                "type": doc.get("Type"),
                "source": doc.get("Source"),
                "message": message[:1000] or json.dumps(doc, default=str)[:1000],
                "data": doc.get("Data"),
            })
    # Errors raised inside an action also appear inline in its block ("[Error | Log.yml:N | ..]")
    # and are already counted; only report the excess (engine-level errors outside any action).
    inline_errors = sum(1 for b in blocks for e in b["entries"] if e["type"] in ("Error", "Critical"))
    excess = max(0, len(engine_errors) - inline_errors)
    for err in (engine_errors[-excess:] if excess else []):
        failed.append({"id": "engine:%s" % (err["source"] or "?"), "description": "AME engine %s" % err["type"],
                       "error": err["message"]})

    completed = None
    if cli_stdout and os.path.exists(cli_stdout):
        tail = read_text(cli_stdout)
        if "Playbook completed successfully" in tail:
            completed = "success"
        elif "Playbook completed with errors" in tail:
            completed = "errors"
        elif "Fatal Playbook Error" in tail or "YAML Error" in tail:
            completed = "fatal"
            failed.append({"id": "engine:fatal", "description": "AME CLI aborted",
                           "error": tail.strip().splitlines()[-1][:1000] if tail.strip() else "fatal"})
        else:
            completed = "incomplete"

    return {
        "counts": {"planned": len(plan), "executed": len(executed), "applied": len(applied),
                   "failed": len(failed), "skipped": len(skipped), "unconfirmed": len(unconfirmed),
                   "outputBlocks": len(blocks), "pairedActions": len(pairable),
                   "misaligned": len(misaligned), "withWarnings": sum(1 for a in applied if a.get("warnings"))},
        "misaligned": misaligned[:20],
        "engineResult": completed,
        "failed": failed,
        "applied": applied,
        "unconfirmed": unconfirmed,
        "skipped": [{"id": a["id"], "description": a["description"], "reason": a["skipReason"]} for a in skipped],
        "sources": {"output": output_path, "log": log_path, "cliStdout": cli_stdout},
    }


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "summarize"):
        p = sub.add_parser(name)
        p.add_argument("--config", required=True)
        p.add_argument("--options-file", required=True)
        p.add_argument("--arch", default="X64")
        p.add_argument("--upgrade", action="store_true")
        p.add_argument("--out", required=True)
        if name == "summarize":
            p.add_argument("--logs", required=True)
            p.add_argument("--cli-stdout")
    args = parser.parse_args(argv)

    with open(args.options_file, "r", encoding="utf-8-sig") as handle:
        selected = {line.strip().lower() for line in handle if line.strip()}
    plan = build_plan(args.config, selected, args.arch, args.upgrade)
    result = plan if args.cmd == "plan" else summarize(plan, args.logs, args.cli_stdout)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
