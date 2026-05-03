#!/usr/bin/env python3
"""Render a certification.json file into a styled PDF.

The certification report is a tagged block structure
(``heading | text | findings | card | table | chart | assessment``);
this renderer walks it and emits a multi-page PDF using ReportLab Platypus.

Charts are rendered as compact summary tables for now (the JSON keeps
the raw chart data, so a richer renderer can be swapped in later
without regenerating the report).

Usage:
    ./scripts/render_certification_pdf.py \\
        --input  .tmp/<agent_id>/<exp_id>/cert-builder/certification.json
    # output written next to the input as certification.pdf

    # Or override the output path
    ./scripts/render_certification_pdf.py \\
        --input  certification.json \\
        --output certificate.pdf
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import mm
    from reportlab.platypus import (
        BaseDocTemplate, Frame, PageBreak, PageTemplate, Paragraph,
        Spacer, Table, TableStyle, KeepTogether, NextPageTemplate,
    )
except ImportError:
    sys.exit("ERROR: reportlab is required.  pip install --user reportlab")


# ── Theme ────────────────────────────────────────────────────────────

ACCENT = colors.HexColor("#1f3b73")      # deep navy
ACCENT_SOFT = colors.HexColor("#e8edf6")
GOOD = colors.HexColor("#2e7d32")
CONCERN = colors.HexColor("#c62828")
WARN = colors.HexColor("#ef6c00")
NOTE = colors.HexColor("#5d6d7e")
GREY = colors.HexColor("#6b7480")
BG_GREY = colors.HexColor("#f4f6f8")
BORDER = colors.HexColor("#d0d6dc")

SEVERITY_COLOR = {
    "good": GOOD, "concern": CONCERN, "warning": WARN, "note": NOTE,
    "info": NOTE, "high": CONCERN, "medium": WARN, "low": NOTE,
}

RATING_COLOR = {
    "Strong": GOOD, "Clean": GOOD,
    "Adequate": WARN, "Moderate": WARN, "Minor": WARN,
    "Weak": CONCERN, "Significant": CONCERN,
}


def _styles():
    base = getSampleStyleSheet()
    return {
        "title":   ParagraphStyle("title",   parent=base["Title"],
                                  fontSize=24, leading=28, textColor=ACCENT,
                                  spaceAfter=4*mm, alignment=1),
        "subtitle":ParagraphStyle("subtitle",parent=base["Normal"],
                                  fontSize=12, leading=16, textColor=GREY,
                                  alignment=1),
        "section": ParagraphStyle("section", parent=base["Heading1"],
                                  fontSize=16, leading=20, textColor=ACCENT,
                                  spaceBefore=6*mm, spaceAfter=2*mm),
        "h2":      ParagraphStyle("h2",      parent=base["Heading2"],
                                  fontSize=12, leading=16, textColor=ACCENT,
                                  spaceBefore=3*mm, spaceAfter=1*mm),
        "h2_detail": ParagraphStyle("h2_detail", parent=base["Italic"],
                                    fontSize=9, leading=12, textColor=GREY,
                                    spaceAfter=2*mm),
        "body":    ParagraphStyle("body",    parent=base["BodyText"],
                                  fontSize=9.5, leading=13, alignment=4,
                                  spaceAfter=2*mm),
        "muted":   ParagraphStyle("muted",   parent=base["BodyText"],
                                  fontSize=8.5, leading=12, textColor=GREY),
        "kv_key":  ParagraphStyle("kv_key",  parent=base["BodyText"],
                                  fontSize=9, leading=12, textColor=GREY),
        "kv_val":  ParagraphStyle("kv_val",  parent=base["BodyText"],
                                  fontSize=9, leading=12, textColor=ACCENT,
                                  fontName="Helvetica-Bold"),
        "finding": ParagraphStyle("finding", parent=base["BodyText"],
                                  fontSize=9, leading=12, leftIndent=4*mm),
        "rating":  ParagraphStyle("rating",  parent=base["BodyText"],
                                  fontSize=8.5, leading=11,
                                  fontName="Helvetica-Bold"),
    }


# ── Block renderers ──────────────────────────────────────────────────

def _esc(s) -> str:
    """Escape paragraph text — ReportLab paragraphs are XML-ish."""
    if s is None:
        return ""
    return (str(s).replace("&", "&amp;")
                  .replace("<", "&lt;")
                  .replace(">", "&gt;"))


def _render_heading(blk, st):
    out = [Paragraph(_esc(blk.get("title", "")), st["h2"])]
    detail = blk.get("detail")
    if detail:
        out.append(Paragraph(_esc(detail), st["h2_detail"]))
    return out


def _render_text(blk, st):
    body = blk.get("body", "")
    return [Paragraph(_esc(body), st["body"])]


def _severity_chip(sev):
    color = SEVERITY_COLOR.get((sev or "").lower(), NOTE)
    label = (sev or "info").upper()
    return Paragraph(
        f'<font color="{color.hexval()}"><b>{label}</b></font>',
        ParagraphStyle("sev", fontSize=8, leading=11),
    )


def _render_findings(blk, st):
    items = blk.get("items", [])
    if not items:
        return [Paragraph("<i>(no findings)</i>", st["muted"])]
    rows = [[_severity_chip(f.get("severity")),
             Paragraph(_esc(f.get("text", "") or
                            f"{f.get('headline','')}: {f.get('detail','')}"),
                       st["finding"])]
            for f in items]
    t = Table(rows, colWidths=[18*mm, None])
    t.setStyle(TableStyle([
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LEFTPADDING", (0,0), (-1,-1), 2),
        ("RIGHTPADDING", (0,0), (-1,-1), 2),
        ("TOPPADDING", (0,0), (-1,-1), 2),
        ("BOTTOMPADDING", (0,0), (-1,-1), 2),
        ("LINEBELOW", (0,0), (-1,-2), 0.25, BORDER),
    ]))
    return [t, Spacer(1, 2*mm)]


def _render_card(blk, st):
    title = blk.get("title", "")
    items = blk.get("items", [])
    rows = [[Paragraph(f"<b>{_esc(title)}</b>", st["h2"])]]
    if isinstance(items, list):
        for it in items:
            if isinstance(it, dict):
                k = it.get("label") or it.get("key") or ""
                v = it.get("value") or ""
                rows.append([Paragraph(f'<b>{_esc(k)}</b>: {_esc(v)}', st["kv_val"])])
            else:
                rows.append([Paragraph(_esc(it), st["body"])])
    elif isinstance(items, dict):
        for k, v in items.items():
            rows.append([Paragraph(f'<b>{_esc(k)}</b>: {_esc(v)}', st["kv_val"])])
    t = Table(rows, colWidths=[None])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), ACCENT_SOFT),
        ("BOX", (0,0), (-1,-1), 0.5, BORDER),
        ("LEFTPADDING", (0,0), (-1,-1), 4),
        ("RIGHTPADDING", (0,0), (-1,-1), 4),
        ("TOPPADDING", (0,0), (-1,-1), 3),
        ("BOTTOMPADDING", (0,0), (-1,-1), 3),
    ]))
    return [t, Spacer(1, 2*mm)]


def _render_table(blk, st):
    title = blk.get("title")
    headers = blk.get("headers", [])
    rows = blk.get("rows", [])
    out = []
    if title:
        out.append(Paragraph(_esc(title), st["h2"]))

    cells = [[Paragraph(f"<b>{_esc(h)}</b>", st["body"]) for h in headers]]
    for r in rows:
        cells.append([Paragraph(_esc(v), st["body"]) for v in r])
    t = Table(cells, repeatRows=1, hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), ACCENT),
        ("TEXTCOLOR", (0,0), (-1,0), colors.white),
        ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, BG_GREY]),
        ("BOX", (0,0), (-1,-1), 0.5, BORDER),
        ("INNERGRID", (0,0), (-1,-1), 0.25, BORDER),
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LEFTPADDING", (0,0), (-1,-1), 3),
        ("RIGHTPADDING", (0,0), (-1,-1), 3),
        ("TOPPADDING", (0,0), (-1,-1), 3),
        ("BOTTOMPADDING", (0,0), (-1,-1), 3),
    ]))
    out.append(t)
    out.append(Spacer(1, 2*mm))
    return out


def _render_chart(blk, st):
    """Represent a chart as a small data summary — full rendering is TBD."""
    out = [Paragraph(f"<b>Chart:</b> {_esc(blk.get('title',''))} "
                     f"<font color='{GREY.hexval()}'>"
                     f"({_esc(blk.get('chart_type',''))})</font>",
                     st["h2"])]
    # Heuristic: pull whichever data shape is present and turn it into a table
    headers, rows = None, None
    if "dimensions" in blk:
        headers = ["Dimension", "Value", "Band"]
        rows = [[d.get("dimension") or d.get("name", ""),
                 d.get("value", ""),
                 d.get("band") or "—"]
                for d in blk["dimensions"]]
    elif "categories" in blk and "series" in blk:
        cats = blk["categories"]
        series = blk["series"]
        headers = ["Category"] + [s.get("name", "") for s in series]
        rows = [[c] + [str(s.get("values", [None])[i] if i < len(s.get("values", []))
                           else "")
                       for s in series]
                for i, c in enumerate(cats)]
    elif "x_labels" in blk and "y_labels" in blk and "values" in blk:
        headers = [""] + list(blk["x_labels"])
        rows = [[blk["y_labels"][i]] + [str(v) for v in row]
                for i, row in enumerate(blk["values"])]

    if headers:
        out.extend(_render_table({"headers": headers, "rows": rows}, st))
    else:
        out.append(Paragraph("<i>(chart data not summarised)</i>", st["muted"]))
    return out


def _render_assessment(blk, st):
    title = blk.get("title", "")
    rating = blk.get("rating") or "—"
    conf   = blk.get("confidence") or "—"
    agree  = blk.get("agreement")
    body   = blk.get("body", "")

    rcolor = RATING_COLOR.get(rating, GREY)
    head = (
        f'<b>{_esc(title)}</b> &nbsp;'
        f'<font color="{rcolor.hexval()}"><b>{_esc(rating)}</b></font> '
        f'<font color="{GREY.hexval()}"><i>'
        f'(conf={_esc(conf)}, agreement={_esc(agree)})</i></font>'
    )
    out = [Paragraph(head, st["h2"])]
    if body:
        out.append(Paragraph(_esc(body), st["body"]))
    return out


_DISPATCH = {
    "heading":   _render_heading,
    "text":      _render_text,
    "findings":  _render_findings,
    "card":      _render_card,
    "table":     _render_table,
    "chart":     _render_chart,
    "assessment":_render_assessment,
}


def _render_block(blk, st):
    fn = _DISPATCH.get(blk.get("type"))
    if not fn:
        return [Paragraph(f"<i>(unrendered block: {_esc(blk.get('type'))})</i>", st["muted"])]
    return fn(blk, st)


# ── Page-level rendering ─────────────────────────────────────────────

def _cover(meta, st):
    """First page: title, agent, totals."""
    out = [
        Spacer(1, 30*mm),
        Paragraph("Agent Certification Report", st["title"]),
        Spacer(1, 4*mm),
        Paragraph(_esc(meta.get("subtitle", "")), st["subtitle"]),
        Spacer(1, 16*mm),
    ]
    items = [
        ("Agent name",          meta.get("agent_name", "—")),
        ("Agent ID",            meta.get("agent_id", "—")),
        ("Certification run",   meta.get("certification_run_id", "—")),
        ("Certification date",  meta.get("certification_date", "—")),
        ("Total runs",          meta.get("total_runs", "—")),
        ("Faults tested",       meta.get("total_faults", "—")),
        ("Fault categories",    meta.get("total_categories", "—")),
        ("Runs / fault",        meta.get("runs_per_fault_configured", "—")),
    ]
    rows = [[Paragraph(k, st["kv_key"]), Paragraph(_esc(v), st["kv_val"])]
            for k, v in items]
    t = Table(rows, colWidths=[55*mm, None])
    t.setStyle(TableStyle([
        ("BOX", (0,0), (-1,-1), 0.5, BORDER),
        ("INNERGRID", (0,0), (-1,-1), 0.25, BORDER),
        ("BACKGROUND", (0,0), (0,-1), ACCENT_SOFT),
        ("LEFTPADDING", (0,0), (-1,-1), 6),
        ("RIGHTPADDING", (0,0), (-1,-1), 6),
        ("TOPPADDING", (0,0), (-1,-1), 4),
        ("BOTTOMPADDING", (0,0), (-1,-1), 4),
    ]))
    out.append(t)

    cats = meta.get("categories") or []
    if cats:
        out.extend([Spacer(1, 8*mm),
                    Paragraph("Fault categories evaluated", st["h2"])])
        cat_rows = [["Category", "Fault", "Runs"]]
        cat_rows += [[c.get("name", "—"), c.get("fault", "—"), str(c.get("runs", "—"))]
                     for c in cats]
        ct = Table(cat_rows, repeatRows=1)
        ct.setStyle(TableStyle([
            ("BACKGROUND", (0,0), (-1,0), ACCENT),
            ("TEXTCOLOR", (0,0), (-1,0), colors.white),
            ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"),
            ("BOX", (0,0), (-1,-1), 0.5, BORDER),
            ("INNERGRID", (0,0), (-1,-1), 0.25, BORDER),
            ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, BG_GREY]),
            ("LEFTPADDING", (0,0), (-1,-1), 4),
            ("RIGHTPADDING", (0,0), (-1,-1), 4),
        ]))
        out.append(ct)
    return out


def _scorecard(header, st):
    """Render the 7-dimension scorecard from header.scorecard."""
    sc = header.get("scorecard", [])
    if not sc:
        return []
    rows = [["Dimension", "Value", "Band"]]
    for d in sc:
        rows.append([d.get("dimension", "—"),
                     f'{d.get("value", "—")}',
                     d.get("band") or "—"])
    t = Table(rows, repeatRows=1, hAlign="LEFT")

    # Color the value cell by score band: 0..0.5 = concern, 0.5..0.85 = warn,
    # 0.85+ = good. Anything non-numeric stays default.
    style = [
        ("BACKGROUND", (0,0), (-1,0), ACCENT),
        ("TEXTCOLOR", (0,0), (-1,0), colors.white),
        ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"),
        ("BOX", (0,0), (-1,-1), 0.5, BORDER),
        ("INNERGRID", (0,0), (-1,-1), 0.25, BORDER),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, BG_GREY]),
        ("LEFTPADDING", (0,0), (-1,-1), 4),
        ("RIGHTPADDING", (0,0), (-1,-1), 4),
        ("TOPPADDING", (0,0), (-1,-1), 4),
        ("BOTTOMPADDING", (0,0), (-1,-1), 4),
    ]
    for i, d in enumerate(sc, start=1):
        try:
            v = float(d.get("value"))
            c = GOOD if v >= 0.85 else WARN if v >= 0.5 else CONCERN
            style.append(("TEXTCOLOR", (1, i), (1, i), c))
            style.append(("FONTNAME", (1, i), (1, i), "Helvetica-Bold"))
        except (TypeError, ValueError):
            pass
    t.setStyle(TableStyle(style))
    return [Paragraph("Scorecard Snapshot", st["section"]),
            t, Spacer(1, 4*mm)]


def _key_findings(header, st):
    items = (header.get("findings") or [])
    if not items:
        return []
    out = [Paragraph("Key Findings", st["section"])]
    out.extend(_render_findings({"items": items}, st))
    return out


def _section(sec, st):
    title = sec.get("title", "")
    out = [Paragraph(_esc(title), st["section"])]
    for blk in sec.get("content", []):
        out.extend(_render_block(blk, st))
    return out


# ── PageTemplate (header/footer on every page after cover) ──────────

def _on_page(canvas, doc, footer_text):
    canvas.saveState()
    w, h = A4
    canvas.setStrokeColor(BORDER); canvas.setLineWidth(0.5)
    canvas.line(15*mm, 15*mm, w - 15*mm, 15*mm)
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(GREY)
    canvas.drawString(15*mm, 10*mm, footer_text or "Agent Certification Report")
    canvas.drawRightString(w - 15*mm, 10*mm, f"Page {doc.page}")
    canvas.restoreState()


# ── Main ─────────────────────────────────────────────────────────────

def render(input_path: Path, output_path: Path) -> None:
    cert = json.loads(input_path.read_text(encoding="utf-8"))
    meta = cert.get("meta", {})
    header = cert.get("header", {})
    sections = cert.get("sections", [])
    footer_text = cert.get("footer", "Agent Certification Report")

    st = _styles()

    # Two templates: a clean cover, then a body template with running footer.
    doc = BaseDocTemplate(
        str(output_path), pagesize=A4,
        leftMargin=18*mm, rightMargin=18*mm,
        topMargin=18*mm, bottomMargin=22*mm,
        title=f"{meta.get('agent_name', 'Agent')} Certification",
        author="AgentCert",
    )
    frame = Frame(doc.leftMargin, doc.bottomMargin,
                  doc.width, doc.height, id="body")
    cover_tpl = PageTemplate(id="cover", frames=[frame],
                             onPage=lambda c, d: None)
    body_tpl = PageTemplate(id="body", frames=[frame],
                            onPage=lambda c, d: _on_page(c, d, footer_text))
    doc.addPageTemplates([cover_tpl, body_tpl])

    story = []
    story.extend(_cover(meta, st))
    story.append(NextPageTemplate("body"))
    story.append(PageBreak())

    story.extend(_scorecard(header, st))
    story.extend(_key_findings(header, st))

    for sec in sections:
        story.append(PageBreak())
        story.extend(_section(sec, st))

    doc.build(story)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--input", "-i", required=True,
                   help="path to certification.json")
    p.add_argument("--output", "-o", default=None,
                   help="output PDF path (default: certification.pdf next to the input)")
    args = p.parse_args()

    inp = Path(args.input).resolve()
    if not inp.exists():
        sys.exit(f"ERROR: not found: {inp}")
    out = Path(args.output).resolve() if args.output else inp.with_suffix(".pdf")
    render(inp, out)
    print(f"✓ wrote {out}  ({out.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
