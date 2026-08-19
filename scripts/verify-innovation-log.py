#!/usr/bin/env python3
"""
Consistency checker for innovation.md.

innovation.md tracks items in two places that must stay in sync by hand:
each "### N.M Title" heading (with its own "**Status: ...**" line), and
one row per item in the "## 10. Summary Table". Cross-references between
items use "§N.M" syntax. None of this is enforced by Markdown itself, so
a routine edit (inserting an item, reordering, deleting one) can silently
desync the table from the headings, or leave a dangling §-reference,
with no visible error.

This script re-derives both views from the file and diffs them. Run it
after editing innovation.md; exit code is non-zero if anything is out
of sync.
"""

import re
import sys
from pathlib import Path

SECTION_RE = re.compile(r"^## (\d+)\. ")
HEADING_RE = re.compile(r"^### (\d+)\.(\d+) (.+)$")
STATUS_RE = re.compile(r"\*\*Status:\s*([^*]+)\*\*")
TABLE_ROW_ITEM_RE = re.compile(r"^\d+\.\d+$")
XREF_RE = re.compile(r"§(\d+\.\d+)")


def normalize_status(raw: str) -> str:
    """Collapse cosmetic wording differences (e.g. 'Not Yet Raised' vs
    'Not raised', or a trailing '(deferred...)' / '— See §3.3' annotation)
    down to the core status phrase, so only real drift is flagged."""
    core = re.split(r"\s*(?:—|\()", raw.strip())[0]
    core = core.strip().lower().replace("yet ", "")
    return re.sub(r"\s+", " ", core).strip()


def parse(text: str):
    lines = text.splitlines()
    headings = {}  # "N.M" -> {"title": str, "status": str, "line": int, "section": str}
    current_section = None

    for i, line in enumerate(lines, start=1):
        m = SECTION_RE.match(line)
        if m:
            current_section = m.group(1)
            continue
        m = HEADING_RE.match(line)
        if m:
            num = f"{m.group(1)}.{m.group(2)}"
            if num in headings:
                headings.setdefault("__dupes__", []).append((num, i))
            status_line = next(
                (l for l in lines[i : i + 3] if STATUS_RE.search(l)), ""
            )
            sm = STATUS_RE.search(status_line)
            headings[num] = {
                "title": m.group(3).strip(),
                "status": sm.group(1).strip() if sm else None,
                "line": i,
                "section": current_section,
                "heading_section": m.group(1),
            }
            continue

    table_rows = {}  # "N.M" -> {"status": str, "line": int}
    for i, line in enumerate(lines, start=1):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 4 or not TABLE_ROW_ITEM_RE.match(cells[0]):
            continue
        num = cells[0]
        if num in table_rows:
            table_rows.setdefault("__dupes__", []).append((num, i))
        table_rows[num] = {"status": cells[3], "line": i}

    xrefs = [(m.group(1), i + 1) for i, l in enumerate(lines) for m in XREF_RE.finditer(l)]

    return headings, table_rows, xrefs


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("innovation.md")
    text = path.read_text()
    headings, table_rows, xrefs = parse(text)

    head_dupes = headings.pop("__dupes__", [])
    table_dupes = table_rows.pop("__dupes__", [])

    errors = []

    for num, line in head_dupes:
        errors.append(f"line {line}: heading §{num} declared more than once")
    for num, line in table_dupes:
        errors.append(f"line {line}: summary-table row {num} declared more than once")

    for num, h in headings.items():
        if num not in table_rows:
            errors.append(
                f"line {h['line']}: §{num} ({h['title']!r}) has a heading but no summary-table row"
            )
        elif h["heading_section"] != h["section"]:
            errors.append(
                f"line {h['line']}: §{num} sits under section {h['section']!r} "
                f"but is numbered {h['heading_section']!r}"
            )

    for num, row in table_rows.items():
        if num not in headings:
            errors.append(f"line {row['line']}: summary-table row {num} has no matching heading")

    for num in headings.keys() & table_rows.keys():
        h_status, t_status = headings[num]["status"], table_rows[num]["status"]
        if h_status is None:
            errors.append(f"line {headings[num]['line']}: §{num} has no **Status:** line")
            continue
        if normalize_status(h_status) != normalize_status(t_status):
            errors.append(
                f"§{num}: heading status {h_status!r} (line {headings[num]['line']}) "
                f"vs table status {t_status!r} (line {table_rows[num]['line']}) don't match"
            )

    known = set(headings.keys())
    for num, line in xrefs:
        if num not in known:
            errors.append(f"line {line}: §{num} is referenced but no such item exists")

    if errors:
        print(f"{path}: {len(errors)} consistency problem(s) found:\n")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"{path}: OK — {len(headings)} items, all headings/table rows/cross-references consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
