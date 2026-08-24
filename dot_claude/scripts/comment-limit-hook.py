"""Claude Code PreToolUse hook: deny Edit/Write/MultiEdit unless net comment lines decrease.

Policy and test plan: projektor DEV-25. Fails open on any error.
"""
import io
import json
import os
import re
import sys
import time
import tokenize
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

MARKER = "HUMAN-APPROVED"

FAMILY_BY_EXT = {}
for _ext in "py rb ex exs sh bash zsh yaml yml toml tf pl".split():
    FAMILY_BY_EXT[_ext] = "hash"
for _ext in "ts tsx js jsx mjs cjs go rs java kt swift c h cpp cs php css scss".split():
    FAMILY_BY_EXT[_ext] = "slash"
for _ext in "sql lua".split():
    FAMILY_BY_EXT[_ext] = "dash"
for _ext in "html xml".split():
    FAMILY_BY_EXT[_ext] = "xml"
FAMILY_BY_EXT["ps1"] = "ps1"
FAMILY_BY_NAME = {"dockerfile": "hash", "makefile": "hash"}
SKIP_NAMES = {".gitignore", ".gitattributes", ".dockerignore", ".npmrc", ".editorconfig"}

DIRECTIVE_RE = re.compile(
    r"noqa|type:\s*ignore|pyright:|eslint-|@ts-|biome-ignore|prettier-ignore|credo:disable"
    r"|shellcheck disable|checkov:skip|tflint-ignore|hadolint ignore|pragma|fmt:\s*(off|on)"
    r"|^\s*#\s*syntax=|cofferdam-ignore|-\*-\s*coding|" + MARKER,
    re.IGNORECASE,
)
LICENSE_RE = re.compile(r"copyright|licen[sc]e|SPDX", re.IGNORECASE)
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`')
GO_DECL_RE = re.compile(r"^\s*(func|type|var|const|package)\b")
TRIPLE_RE = re.compile(r'"""|\'\'\'')


@dataclass
class Decision:
    action: str
    reason: str = ""
    would_deny: bool = False


def family_for(path):
    name = Path(path).name
    if name in SKIP_NAMES or name.startswith(".env"):
        return None
    if name.lower() in FAMILY_BY_NAME:
        return FAMILY_BY_NAME[name.lower()]
    ext = Path(path).suffix.lstrip(".").lower()
    return FAMILY_BY_EXT.get(ext)


def _strip_strings(line):
    return STRING_RE.sub('""', line)


def _hash_lines(lines):
    out, in_triple = [], False
    for i, line in enumerate(lines):
        if in_triple:
            if TRIPLE_RE.search(line):
                in_triple = False
            continue
        n = len(TRIPLE_RE.findall(line))
        if n % 2 == 1:
            in_triple = True
            continue
        if "#" in _strip_strings(line):
            out.append(i)
    return out


def _python_lines(text):
    found = []
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                found.append(tok.start[0] - 1)
    except (tokenize.TokenError, IndentationError, SyntaxError):
        if not found:
            return _hash_lines(text.splitlines())
    return found


def _block_lines(lines, line_open, block_open, block_close, doc_open=()):
    out, in_block, doc = [], False, False
    for i, line in enumerate(lines):
        if in_block:
            if not doc:
                out.append(i)
            if block_close in line:
                in_block = False
            continue
        s = _strip_strings(line)
        if block_open in s:
            start = s.index(block_open)
            doc = any(s.startswith(d, start) for d in doc_open)
            if block_close not in s[start + len(block_open):]:
                in_block = True
            if not doc:
                out.append(i)
            continue
        if line_open and line_open in s:
            out.append(i)
    return out


def _raw_comment_lines(text, path):
    fam = family_for(path)
    lines = text.splitlines()
    ext = Path(path).suffix.lstrip(".").lower()
    if fam == "hash":
        idx = _python_lines(text) if ext == "py" else _hash_lines(lines)
    elif fam == "slash":
        idx = _block_lines(lines, "//", "/*", "*/", doc_open=("/**",))
        idx = [i for i in idx if not re.match(r"\s*(///|//!)", lines[i])]
        if ext == "go":
            idx = _drop_go_doc_comments(idx, lines)
    elif fam == "dash":
        idx = [i for i, l in enumerate(lines) if "--" in _strip_strings(l)]
    elif fam == "xml":
        idx = _block_lines(lines, None, "<!--", "-->")
    elif fam == "ps1":
        idx = _block_lines(lines, "#", "<#", "#>")
    else:
        return []
    return idx


def _drop_go_doc_comments(idx, lines):
    idxset, keep = set(idx), []
    for i in idx:
        j = i
        while j + 1 < len(lines) and j + 1 in idxset:
            j += 1
        k = j + 1
        if k < len(lines) and GO_DECL_RE.match(lines[k]):
            continue
        keep.append(i)
    return keep


def _drop_license_header(idx, lines):
    run = []
    for i in sorted(set(idx)):
        if i == (run[-1] + 1 if run else 0) or (i == 1 and not run):
            run.append(i)
        else:
            break
    if run and any(LICENSE_RE.search(lines[i]) for i in run):
        return [i for i in idx if i not in run]
    return idx


def analyse(text, path):
    """1-based line numbers of counted comment lines."""
    lines = text.splitlines()
    idx = _raw_comment_lines(text, path)
    idx = [i for i in idx if not (i == 0 and lines[i].startswith("#!"))]
    idx = [i for i in idx if not DIRECTIVE_RE.search(lines[i])]
    idx = _drop_license_header(idx, lines)
    return [i + 1 for i in idx]


def large_blocks(text, path, min_lines=3):
    blocks, run = [], []
    for n in analyse(text, path):
        if run and n == run[-1] + 1:
            run.append(n)
        else:
            if len(run) >= min_lines:
                blocks.append((run[0], run[-1]))
            run = [n]
    if len(run) >= min_lines:
        blocks.append((run[0], run[-1]))
    return blocks


def _ranges(nums):
    parts, start, prev = [], None, None
    for n in nums:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            parts.append(f"{start}–{prev}" if start != prev else str(start))
            start = prev = n
    if start is not None:
        parts.append(f"{start}–{prev}" if start != prev else str(start))
    return ", ".join(parts)


def decide(old_lines, new_lines, mode):
    if not old_lines and not new_lines:
        return Decision("allow")
    if len(new_lines) < len(old_lines):
        return Decision("allow")
    reason = (
        f"Net comment count must decrease (old {len(old_lines)}, new {len(new_lines)}). "
        f"New/changed comments on lines {_ranges(new_lines)} of the new text. "
        "Remove them — comments are written by humans. If one is genuinely essential, "
        "tell the user what you wanted to annotate and let them add it "
        f"(they can mark it {MARKER} to exempt it)."
    )
    if mode == "warn":
        return Decision("allow", reason, would_deny=True)
    return Decision("deny", reason, would_deny=True)


def _advisory(blocks):
    spans = ", ".join(f"{a}–{b}" for a, b in blocks)
    return (f"Existing large comment at lines {spans}; offer the user a more concise version "
            "(net count must still decrease).")


def _old_new(tool, inp):
    path = inp["file_path"]
    if tool == "Write":
        p = Path(path)
        old = p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
        return [(old, inp["content"])]
    if tool == "MultiEdit":
        return [(e["old_string"], e["new_string"]) for e in inp["edits"]]
    return [(inp["old_string"], inp["new_string"])]


def _log(path, file, old_n, new_n, outcome):
    if not path:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"{ts}\t{file}\t{old_n}\t{new_n}\t{outcome}\n")


def main():
    mode = os.environ.get("COMMENT_HOOK_MODE", "deny").lower()
    if mode == "off":
        return
    data = json.loads(sys.stdin.read())
    tool = data.get("tool_name")
    if tool not in ("Edit", "Write", "MultiEdit"):
        return
    inp = data.get("tool_input") or {}
    path = inp.get("file_path")
    if not path or family_for(path) is None:
        return
    pairs = _old_new(tool, inp)
    old_lines = [n for o, _ in pairs for n in analyse(o, path)]
    new_lines = [n for _, n_ in pairs for n in analyse(n_, path)]
    d = decide(old_lines, new_lines, mode)

    file_text = pairs[0][0] if tool == "Write" else None
    if file_text is None and Path(path).is_file():
        file_text = Path(path).read_text(encoding="utf-8", errors="replace")
    blocks = large_blocks(file_text, path) if file_text else []

    outcome = d.action if not (d.would_deny and d.action == "allow") else "warn-deny"
    _log(os.environ.get("COMMENT_HOOK_LOG", str(Path.home() / ".claude" / "logs" / "comment-hook.log")),
         path, len(old_lines), len(new_lines), outcome)

    out = {"hookEventName": "PreToolUse"}
    if d.action == "deny":
        out["permissionDecision"] = "deny"
        out["permissionDecisionReason"] = d.reason + (" " + _advisory(blocks) if blocks else "")
    elif blocks:
        out["permissionDecision"] = "allow"
        out["additionalContext"] = _advisory(blocks)
    else:
        return
    print(json.dumps({"hookSpecificOutput": out}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
