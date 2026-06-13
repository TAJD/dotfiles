#!/usr/bin/env python3
"""
Record agent frustrations to a per-CWD SQLite database.

Usage:
  python record_frustration.py --message "TEXT" [--category CAT] [--severity 1-5]
                                [--cwd PATH] [--context JSON] [--session ID]
  python record_frustration.py --review [--cwd PATH] [--limit N]
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

CATEGORIES = [
    "tool_failure",      # Tool call errored or returned unexpected results
    "blocked",           # Cannot proceed; permission denied, missing dep, etc.
    "api_confusion",     # Unclear/inconsistent API or interface behaviour
    "repeated_failure",  # Same approach failed multiple times
    "missing_info",      # Needed information not available in context
    "workaround",        # Had to do something hacky to make progress
    "other",
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS frustrations (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp     TEXT    NOT NULL,
    cwd           TEXT    NOT NULL,
    session_id    TEXT,
    category      TEXT,
    severity      INTEGER DEFAULT 3,
    message       TEXT    NOT NULL,
    context_json  TEXT
);
CREATE INDEX IF NOT EXISTS idx_timestamp ON frustrations (timestamp);
CREATE INDEX IF NOT EXISTS idx_category  ON frustrations (category);
"""


def db_path(cwd: Path) -> Path:
    return cwd / ".agent_frustrations.db"


def get_connection(cwd: Path) -> sqlite3.Connection:
    path = db_path(cwd)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def record(args: argparse.Namespace) -> None:
    cwd = Path(args.cwd).resolve()
    conn = get_connection(cwd)
    ts = datetime.now(timezone.utc).isoformat()
    context_json = None
    if args.context:
        try:
            parsed = json.loads(args.context)
            context_json = json.dumps(parsed)
        except json.JSONDecodeError:
            context_json = json.dumps({"raw": args.context})

    conn.execute(
        """
        INSERT INTO frustrations (timestamp, cwd, session_id, category, severity, message, context_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (ts, str(cwd), args.session, args.category, args.severity, args.message, context_json),
    )
    row_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
    conn.commit()
    conn.close()

    print(f"Recorded frustration #{row_id} in {db_path(cwd)}")
    print(f"  category={args.category}  severity={args.severity}")
    print(f"  message: {args.message[:120]}")


def review(args: argparse.Namespace) -> None:
    cwd = Path(args.cwd).resolve()
    path = db_path(cwd)
    if not path.exists():
        print(f"No frustrations database at {path}")
        return

    conn = get_connection(cwd)
    limit = args.limit or 50
    rows = conn.execute(
        """
        SELECT id, timestamp, category, severity, session_id, message, context_json
        FROM frustrations
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    conn.close()

    if not rows:
        print("No frustrations recorded yet.")
        return

    print(f"\n{'='*72}")
    print(f"Agent Frustrations - {path}")
    print(f"{'='*72}\n")
    for r in rows:
        ts = r["timestamp"][:19].replace("T", " ")
        cat = r["category"] or "other"
        sev = r["severity"] or 3
        sid = f"  session={r['session_id']}" if r["session_id"] else ""
        print(f"[{r['id']:>4}] {ts}  cat={cat:<18} sev={sev}{sid}")
        print(f"       {r['message']}")
        if r["context_json"]:
            ctx = json.loads(r["context_json"])
            print(f"       context: {json.dumps(ctx, separators=(',', ':'))}")
        print()

    # Summary by category
    conn2 = get_connection(cwd)
    cats = conn2.execute(
        """
        SELECT category, COUNT(*) as n, AVG(severity) as avg_sev
        FROM frustrations
        GROUP BY category
        ORDER BY n DESC
        """
    ).fetchall()
    conn2.close()

    print("-" * 40)
    print("Summary by category:")
    for c in cats:
        print(f"  {(c['category'] or 'other'):<20} {c['n']:>3} entries  avg severity {c['avg_sev']:.1f}")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Record or review agent frustrations",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Without --review, a --message is required to record a frustration.",
    )
    parser.add_argument("--message", "-m", help="Describe the frustration")
    parser.add_argument("--category", "-c", default="other", choices=CATEGORIES)
    parser.add_argument("--severity", "-s", type=int, default=3, choices=range(1, 6),
                        metavar="{1-5}", help="1=minor annoyance … 5=completely blocked")
    parser.add_argument("--cwd", default=os.getcwd(), help="Project directory (default: cwd)")
    parser.add_argument("--context", help="Optional JSON blob with extra context")
    parser.add_argument("--session", help="Optional session identifier")
    parser.add_argument("--review", action="store_true", help="Print recent frustrations")
    parser.add_argument("--limit", type=int, default=50, help="Max rows to show (--review only)")

    args = parser.parse_args()

    if args.review:
        review(args)
    elif args.message:
        record(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
