import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "comment-limit-hook.py"
spec = importlib.util.spec_from_file_location("hook", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

analyse = hook.analyse
decide = hook.decide
large_blocks = hook.large_blocks


# --- analyse(): returns 1-based line numbers of counted comment lines ---

@pytest.mark.parametrize("text,path,expected", [
    # slash family
    ("// a\n// b\n// c\nconst x = 1;\n", "a.ts", [1, 2, 3]),
    ("const x = 1; // trailing why\n", "a.ts", [1]),
    ("/* one\n two\n three */\nlet y;\n", "a.ts", [1, 2, 3]),
    ("/**\n * jsdoc\n */\nfunction f() {}\n", "a.ts", []),
    ("const u = 'http://x.com';\nconst v = \"a // b\";\n", "a.ts", []),
    ("// eslint-disable-next-line\n// @ts-expect-error\n// biome-ignore lint: x\n// prettier-ignore\n// cofferdam-ignore Foo\n", "a.ts", []),
    ("/// doc\n//! crate doc\n// plain\n", "a.rs", [3]),
    ("// Foo does things.\nfunc Foo() {}\n\n// stray\nx := 1\n", "a.go", [4]),
    ("a { color: red; } /* why */\n", "a.css", [1]),
    # hash family
    ("#!/usr/bin/env python\n# -*- coding: utf-8 -*-\nx = 1  # what\n", "a.py", [3]),
    ("def f():\n    \"\"\"docstring\n    # not a comment\n    \"\"\"\n    return 1\n", "a.py", []),
    ("x = '#nope'\ny = 2  # noqa\nz = 3  # type: ignore\n", "a.py", []),
    ("    # indented fragment\n    if x:\n        pass\n", "a.py", [1]),
    ("@moduledoc \"\"\"\n# heading in doc\n\"\"\"\n# real\n", "a.ex", [4]),
    ("# shellcheck disable=SC2086\n# real\necho hi\n", "a.sh", [2]),
    ("# syntax=docker/dockerfile:1\n# hadolint ignore=DL3008\n# real\nFROM x\n", "Dockerfile", [3]),
    ("key: 1 # why\n# top\n", "a.yml", [1, 2]),
    # other families
    ("SELECT 1; -- why\n-- top\n", "a.sql", [1, 2]),
    ("<!-- one\n two -->\n<p>x</p>\n", "a.html", [1, 2]),
    ("<# block\n more #>\n# line\nWrite-Host 1\n", "a.ps1", [1, 2, 3]),
    # exemptions
    ("# HUMAN-APPROVED keep this\n# other\n", "a.py", [2]),
    ("// Copyright 2026 Foo\n// Licensed under MIT\n\n// real\n", "a.ts", [4]),
    ("# pragma once-ish\n", "a.py", []),
    # skipped files
    ("# comment\n", "a.md", []),
    ("# comment\n", ".gitignore", []),
    ("# comment\n", ".env.local", []),
    ("# comment\n", "noext", []),
    ("", "a.py", []),
])
def test_analyse(text, path, expected):
    assert analyse(text, path) == expected


def test_analyse_python_fragment_with_unclosed_bracket_still_counts():
    assert analyse("foo(\n    # inside\n    1,\n", "a.py") == [2]


def test_analyse_python_hash_in_fstring_not_counted():
    assert analyse('s = f"{x}#tag"\n', "a.py") == []


# --- large_blocks(): runs of >=3 consecutive counted comment lines ---

def test_large_blocks_finds_runs():
    text = "// a\n// b\n// c\nx\n// d\n// e\ny\n"
    assert large_blocks(text, "a.ts") == [(1, 3)]


def test_large_blocks_ignores_docstrings():
    text = 'def f():\n    """\n    a\n    b\n    c\n    """\n'
    assert large_blocks(text, "a.py") == []


# --- decide(old_lines, new_lines, mode) -> Decision ---

@pytest.mark.parametrize("old,new,action", [
    ([1, 2, 3], [1, 2], "allow"),
    ([1, 2, 3], [1, 2, 3], "deny"),
    ([], [1], "deny"),
    ([1, 2], [], "allow"),
    ([], [], "allow"),
    ([1], [1], "deny"),
])
def test_decide_net_rule(old, new, action):
    assert decide(old, new, "deny").action == action


def test_decide_deny_reason_names_new_lines():
    d = decide([], [3, 4, 5, 9], "deny")
    assert d.action == "deny"
    assert "3–5" in d.reason and "9" in d.reason
    assert "written by humans" in d.reason


def test_decide_warn_mode_allows_but_flags():
    d = decide([], [1], "warn")
    assert d.action == "allow"
    assert d.would_deny is True


def test_decide_no_comments_is_silent_allow():
    d = decide([], [], "deny")
    assert d.action == "allow" and d.would_deny is False


# --- main(): stdin JSON -> stdout JSON / exit code ---

def run(payload, env=None, stdin=None):
    e = {**os.environ, "COMMENT_HOOK_LOG": os.devnull}
    e.pop("COMMENT_HOOK_MODE", None)
    e.update(env or {})
    data = stdin if stdin is not None else json.dumps(payload)
    return subprocess.run([sys.executable, str(SCRIPT)], input=data, capture_output=True, text=True, env=e)


def edit(path, old, new, tool="Edit"):
    return {"tool_name": tool, "tool_input": {"file_path": path, "old_string": old, "new_string": new}}


def out_of(r):
    return json.loads(r.stdout)["hookSpecificOutput"]


def test_main_edit_adding_comment_denies(tmp_path):
    r = run(edit(str(tmp_path / "a.ts"), "x = 1;", "x = 1; // what\n"))
    assert r.returncode == 0
    out = out_of(r)
    assert out["hookEventName"] == "PreToolUse"
    assert out["permissionDecision"] == "deny"
    assert "written by humans" in out["permissionDecisionReason"]


def test_main_edit_removing_comment_allows_silently(tmp_path):
    p = tmp_path / "a.ts"
    p.write_text("x = 1;\n")
    r = run(edit(str(p), "// a\n// b\nx", "// a\nx"))
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_edit_same_count_rewrite_denies(tmp_path):
    r = run(edit(str(tmp_path / "a.py"), "# old\nx = 1", "# new\nx = 1"))
    assert out_of(r)["permissionDecision"] == "deny"


def test_main_write_new_file_license_header_only_allows(tmp_path):
    r = run({"tool_name": "Write", "tool_input": {"file_path": str(tmp_path / "n.ts"),
            "content": "// Copyright 2026\n// MIT License\nexport {};\n"}})
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_write_new_file_with_comment_denies(tmp_path):
    r = run({"tool_name": "Write", "tool_input": {"file_path": str(tmp_path / "n.ts"),
            "content": "// what\nexport {};\n"}})
    assert out_of(r)["permissionDecision"] == "deny"


def test_main_write_existing_file_fewer_comments_allows(tmp_path):
    p = tmp_path / "e.py"
    p.write_text("# a\nx = 1\n# b\ny = 2\n# c\nz = 3\n# d\n")
    r = run({"tool_name": "Write", "tool_input": {"file_path": str(p), "content": "# a\nx = 1\n# b\ny = 2\nz = 3\n"}})
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_multiedit_nets_negative_allows(tmp_path):
    p = tmp_path / "m.ts"
    p.write_text("// a\nx\n// b\nw\ny\n")
    r = run({"tool_name": "MultiEdit", "tool_input": {"file_path": str(p), "edits": [
        {"old_string": "// a\nx\n// b\nw", "new_string": "x\nw"},
        {"old_string": "y", "new_string": "y // new"},
    ]}})
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_multiedit_net_positive_denies(tmp_path):
    r = run({"tool_name": "MultiEdit", "tool_input": {"file_path": str(tmp_path / "m.ts"), "edits": [
        {"old_string": "x", "new_string": "x // one"},
        {"old_string": "y", "new_string": "y // two"},
    ]}})
    assert out_of(r)["permissionDecision"] == "deny"


def test_main_human_approved_excluded_both_sides(tmp_path):
    r = run(edit(str(tmp_path / "a.py"), "x = 1", "# HUMAN-APPROVED: load-bearing\nx = 1"))
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_advisory_on_allow_when_file_has_large_block(tmp_path):
    p = tmp_path / "big.ts"
    p.write_text("// one\n// two\n// three\n// four\n// five\nx\n")
    r = run(edit(str(p), "// one\n// two\n// three\n// four\n// five\nx", "// one\n// two\nx"))
    out = out_of(r)
    assert out["permissionDecision"] == "allow"
    assert "1–5" in out["additionalContext"]
    assert "net count must still decrease" in out["additionalContext"]


def test_main_advisory_folded_into_deny_reason(tmp_path):
    p = tmp_path / "big.ts"
    p.write_text("// one\n// two\n// three\nx\n")
    r = run(edit(str(p), "x", "x // what"))
    out = out_of(r)
    assert out["permissionDecision"] == "deny"
    assert "1–3" in out["permissionDecisionReason"]


def test_main_condensation_allows(tmp_path):
    p = tmp_path / "c.py"
    p.write_text("# 1\n# 2\n# 3\n# 4\n# 5\nx = 1\n")
    assert large_blocks(p.read_text(), str(p)) == [(1, 5)]
    r = run(edit(str(p), "# 1\n# 2\n# 3\n# 4\n# 5\n", "# 1-5 condensed\n# second\n"))
    assert out_of(r)["permissionDecision"] == "allow"


@pytest.mark.parametrize("payload", [
    {"tool_name": "Read", "tool_input": {"file_path": "a.ts"}},
    {"tool_name": "Edit", "tool_input": {"file_path": "a.md", "old_string": "", "new_string": "# x"}},
    {"tool_name": "Edit", "tool_input": {"file_path": "a.ts"}},
    {"tool_name": "Edit"},
    {},
])
def test_main_non_applicable_payloads_are_silent(payload):
    r = run(payload)
    assert r.returncode == 0 and r.stdout.strip() == ""


@pytest.mark.parametrize("raw", ["", "not json", "{", "[1,2]"])
def test_main_fails_open_on_bad_stdin(raw):
    r = run(None, stdin=raw)
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_write_unreadable_existing_path_fails_open(tmp_path):
    d = tmp_path / "dir.ts"
    d.mkdir()
    r = run({"tool_name": "Write", "tool_input": {"file_path": str(d), "content": "// x\n"}})
    assert r.returncode == 0 and r.stdout.strip() == ""


def test_main_warn_mode_allows_and_logs(tmp_path):
    log = tmp_path / "hook.log"
    r = run(edit(str(tmp_path / "a.ts"), "x", "x // what"),
            env={"COMMENT_HOOK_MODE": "warn", "COMMENT_HOOK_LOG": str(log)})
    assert r.returncode == 0 and r.stdout.strip() == ""
    line = log.read_text().strip().splitlines()[-1]
    assert line.split("\t")[-1] == "warn-deny" and "a.ts" in line


def test_main_deny_mode_logs(tmp_path):
    log = tmp_path / "hook.log"
    run(edit(str(tmp_path / "a.ts"), "x", "x // what"), env={"COMMENT_HOOK_LOG": str(log)})
    assert log.read_text().strip().splitlines()[-1].split("\t")[-1] == "deny"


def test_main_off_mode_does_nothing(tmp_path):
    log = tmp_path / "hook.log"
    r = run(edit(str(tmp_path / "a.ts"), "x", "x // what"),
            env={"COMMENT_HOOK_MODE": "off", "COMMENT_HOOK_LOG": str(log)})
    assert r.stdout.strip() == "" and not log.exists()


def test_main_latency_on_large_content(tmp_path):
    content = "".join(f"const v{i} = {i};\n" for i in range(2000))
    t = time.perf_counter()
    run({"tool_name": "Write", "tool_input": {"file_path": str(tmp_path / "big.ts"), "content": content}})
    assert time.perf_counter() - t < 1.0
