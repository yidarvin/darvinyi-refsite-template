#!/usr/bin/env python3
"""Decide the next step in the build-critique loop, or report its state.

Usage:

    python3 scripts/decide.py status   # dashboard: counts, per-chapter table, next step
    python3 scripts/decide.py next     # one line: NEXT <action> <slug> :: <reason>
    python3 scripts/decide.py counts   # one line of machine-parseable totals

Reuses validate.py's parsers (the registry and queue are parsed in exactly one
place) rather than re-deriving state. `next` is the decision `run.sh` acts on;
`status` and `counts` exist for a human and for the driver's per-stage progress
assertions, respectively.

Priority order for `next` (a chapter can only be in one bucket at a time):

    1. any critique with verdict 'revise'                -> resolve
    2. any draft chapter with critique missing/'resolved' -> critique
    3. any draft chapter with verdict 'approve'           -> critique (repair: record done)
    4. the first queue PENDING row at registry 'pending'  -> build
    5. otherwise                                          -> done

A validation failure short-circuits everything: `next` reports 'error' rather
than acting on state it cannot trust.
"""
from __future__ import annotations

import os
import sys

import validate as V


def _collect(repo: str) -> list[dict]:
    """One row per registry chapter: registry/queue status and critique verdict.

    validate() enforces that registry order and queue order agree for shared
    slugs, so registry order is used throughout below.
    """
    reg = V.load_registry(repo)
    chapters = reg.get("chapters", [])

    q_status: dict[str, str] = {}
    try:
        q = V.parse_queue(repo)
    except V.QueueError:
        q = None
    if q is not None:
        slug_i = V._col_index(q["header"], "slug")
        status_i = V._col_index(q["header"], "status")
        if slug_i != -1 and status_i != -1:
            for r in q["rows"]:
                if len(r) > max(slug_i, status_i):
                    q_status[r[slug_i]] = r[status_i]

    rows = []
    for c in chapters:
        slug = c.get("slug")
        if not slug:
            continue
        rows.append(
            {
                "num": c.get("num"),
                "slug": slug,
                "title": c.get("title"),
                "reg": c.get("status"),
                "queue": q_status.get(slug),
                "verdict": V.read_verdict(repo, slug),
            }
        )
    return rows


def _counts(rows: list[dict]) -> dict[str, int]:
    return {
        "pending": sum(1 for r in rows if r["reg"] == "pending"),
        "draft": sum(1 for r in rows if r["reg"] == "draft"),
        "done": sum(1 for r in rows if r["reg"] == "done"),
        "revise": sum(1 for r in rows if r["verdict"] == "revise"),
        "unreviewed": sum(1 for r in rows if r["reg"] == "draft" and r["verdict"] in (None, "resolved")),
        "approved_draft": sum(1 for r in rows if r["reg"] == "draft" and r["verdict"] == "approve"),
    }


def decide_next(repo: str) -> tuple[str, str, str]:
    """Return (action, slug, reason). action is one of resolve/critique/build/done/error."""
    errors, _ = V.validate(repo)
    if errors:
        return ("error", "-", "validation failed; run npm run validate")

    rows = _collect(repo)

    revises = [r for r in rows if r["verdict"] == "revise"]
    if revises:
        names = ", ".join(r["slug"] for r in revises[:5])
        more = f" (+{len(revises) - 5} more)" if len(revises) > 5 else ""
        return ("resolve", revises[0]["slug"], f"open revise verdicts: {names}{more}")

    unreviewed = [r for r in rows if r["reg"] == "draft" and r["verdict"] in (None, "resolved")]
    if unreviewed:
        r = unreviewed[0]
        why = "awaiting first review" if r["verdict"] is None else "resolved fixes await re-review"
        return ("critique", r["slug"], f"built and {why}")

    approved_draft = [r for r in rows if r["reg"] == "draft" and r["verdict"] == "approve"]
    if approved_draft:
        r = approved_draft[0]
        return ("critique", r["slug"], "approved but still draft (interrupted run; will record done)")

    pending_build = [r for r in rows if r["reg"] == "pending" and r["queue"] == "PENDING"]
    if pending_build:
        r = pending_build[0]
        return ("build", r["slug"], "next unbuilt item in queue order")

    return ("done", "-", "queue drained and every chapter critique-approved")


# ---- CLI ---------------------------------------------------------------

def cmd_next(repo: str) -> int:
    action, slug, reason = decide_next(repo)
    print(f"NEXT {action} {slug} :: {reason}")
    return 0


def cmd_counts(repo: str) -> int:
    c = _counts(_collect(repo))
    print(
        f"pending={c['pending']} draft={c['draft']} done={c['done']} "
        f"revise={c['revise']} unreviewed={c['unreviewed']} approved_draft={c['approved_draft']}"
    )
    return 0


def cmd_status(repo: str) -> int:
    errors, warnings = V.validate(repo)
    for line in V._summary_lines(repo):
        print(line)
    for w in warnings:
        print(f"  warn: {w}")
    for e in errors:
        print(f"  error: {e}")

    rows = _collect(repo)
    print()
    print(f"{'num':>3}  {'slug':<30} {'registry':<9} {'queue':<9} verdict")
    for r in rows:
        print(
            f"{str(r['num']):>3}  {r['slug']:<30} {str(r['reg']):<9} "
            f"{str(r['queue']):<9} {r['verdict'] or '-'}"
        )

    revises = [r["slug"] for r in rows if r["verdict"] == "revise"]
    if revises:
        print()
        print(f"open revises: {', '.join(revises)}")

    action, slug, reason = decide_next(repo)
    print()
    print(f"NEXT {action} {slug} :: {reason}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ("status", "next", "counts"):
        print("usage: python3 scripts/decide.py status|next|counts")
        return 2
    repo = os.getcwd()
    cmd = argv[1]
    if cmd == "status":
        return cmd_status(repo)
    if cmd == "next":
        return cmd_next(repo)
    return cmd_counts(repo)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
