#!/usr/bin/env python3
"""Dump a Langfuse trace into the certifier's pipeline-compatible JSON format.

This is a *development* helper for collecting sample traces that the certifier
can consume offline (FileTraceSource).  It deliberately uses the **same**
`TraceService` code path the running certifier uses, so the dump is guaranteed
to match what the live pipeline would have produced — there is no second,
divergent serialiser to keep in sync.

Inputs (CLI flags or env-vars from the monorepo `.env`):
    --experiment-id     The chaos experiment ID to filter Langfuse traces by.
    --run-id            The experiment run ID (Langfuse will match either
                        ``experiment.run_id`` or ``experiment_run_id``).
    --output-dir        Directory where ``raw_trace.json`` (and a small
                        ``trace_meta.json`` summary) will be written.
                        Default: ``./trace_dumps/<experiment_id>__<run_id>``.
    --langfuse-host /
    --public-key  /
    --secret-key        Override LANGFUSE_HOST / LANGFUSE_PUBLIC_KEY /
                        LANGFUSE_SECRET_KEY env-vars from the root .env.
    --page-size, --max-pages, --no-observations
                        Pass-through to LangfuseTraceSource.

Examples:
    # Default — read all knobs from /srv/projects/ace-monorepo/.env
    ./scripts/dump_langfuse_trace.py \\
        --experiment-id 1a3226c7-b186-4c74-8b09-9dd1bb45177d \\
        --run-id        795b0c04-d24e-464a-9b1e-a70c53891a0f

    # Custom output dir
    ./scripts/dump_langfuse_trace.py \\
        --experiment-id <EXP> --run-id <RUN> \\
        --output-dir ./trace_dumps/sample-001
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path


# ── Repo wiring ──────────────────────────────────────────────────────
# Resolve repo paths relative to this script's location so the helper
# remains portable across checkouts.

_SCRIPT_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _SCRIPT_DIR.parent
_CERTIFIER_ROOT = _REPO_ROOT / "certifier"
_DOTENV_PATH = _REPO_ROOT / ".env"


def _bootstrap() -> None:
    """Ensure the certifier package is importable and root .env is loaded."""
    if not _CERTIFIER_ROOT.exists():
        sys.exit(
            f"ERROR: certifier package not found at {_CERTIFIER_ROOT}. "
            "Re-run from inside the ace-monorepo checkout."
        )
    sys.path.insert(0, str(_CERTIFIER_ROOT))

    try:
        import dotenv  # noqa: WPS433 — lazy import is intentional
    except ImportError:
        sys.exit(
            "ERROR: python-dotenv is required (pip install python-dotenv).  "
            "It loads LANGFUSE_* credentials from the root .env."
        )
    if _DOTENV_PATH.exists():
        dotenv.load_dotenv(_DOTENV_PATH)


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--experiment-id", required=True,
                   help="experiment ID matched against Langfuse trace metadata.")
    p.add_argument("--run-id", required=True,
                   help="run ID matched against Langfuse trace metadata.")
    p.add_argument("--output-dir", default=None,
                   help="dump directory; defaults to "
                        "./trace_dumps/<experiment_id>__<run_id>.")
    p.add_argument("--langfuse-host", default=None,
                   help="overrides LANGFUSE_HOST env var.")
    p.add_argument("--public-key", default=None,
                   help="overrides LANGFUSE_PUBLIC_KEY env var.")
    p.add_argument("--secret-key", default=None,
                   help="overrides LANGFUSE_SECRET_KEY env var.")
    p.add_argument("--page-size", type=int, default=50,
                   help="Langfuse list_traces page size (1..500).")
    p.add_argument("--max-pages", type=int, default=10,
                   help="Maximum number of pages to scan (1..100).")
    p.add_argument("--no-observations", action="store_true",
                   help="skip per-trace observation fetch (metadata-only).")
    return p.parse_args()


async def _run(args: argparse.Namespace) -> int:
    # Apply CLI overrides into env-vars BEFORE TraceService reads them.
    if args.langfuse_host:
        os.environ["LANGFUSE_HOST"] = args.langfuse_host
    if args.public_key:
        os.environ["LANGFUSE_PUBLIC_KEY"] = args.public_key
    if args.secret_key:
        os.environ["LANGFUSE_SECRET_KEY"] = args.secret_key

    missing = [n for n in ("LANGFUSE_HOST", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY")
               if not os.environ.get(n, "").strip()]
    if missing:
        sys.exit(f"ERROR: missing env-var(s): {', '.join(missing)}.  "
                 f"Set them in {_DOTENV_PATH} or pass --{missing[0].lower().replace('_','-')}.")

    # Use the production TraceService verbatim — no shadow serialiser.
    from main.models.bucket_requests import LangfuseTraceSource
    from main.services.trace_service import TraceIngestionError, TraceService

    out_dir = Path(args.output_dir) if args.output_dir else (
        _SCRIPT_DIR.parent / "trace_dumps" / f"{args.experiment_id}__{args.run_id}"
    )

    src = LangfuseTraceSource(
        type="langfuse",
        page_size=args.page_size,
        max_pages=args.max_pages,
        include_observations=not args.no_observations,
    )

    print(f"  LANGFUSE_HOST     = {os.environ['LANGFUSE_HOST']}")
    print(f"  experiment_id     = {args.experiment_id}")
    print(f"  run_id            = {args.run_id}")
    print(f"  output dir        = {out_dir}")
    print(f"  include_obs       = {src.include_observations}\n")

    try:
        path, count = await TraceService().acquire_trace(
            src, out_dir, experiment_id=args.experiment_id, run_id=args.run_id,
        )
    except TraceIngestionError as exc:
        sys.exit(f"ERROR [{exc.error_code}]: {exc}")

    # Quick post-write summary so dev can sanity-check at a glance
    events = json.loads(path.read_text())
    fault_spans = sorted({e["name"] for e in events if isinstance(e.get("name"), str)
                          and e["name"].startswith("fault:")})
    sts = [e["startTime"] for e in events]
    chronological = sts == sorted(sts)
    summary = {
        "trace_path": str(path),
        "observation_count": count,
        "fault_spans": fault_spans,
        "chronological": chronological,
        "field_set": sorted(events[0].keys()) if events else [],
    }
    summary_path = out_dir / "trace_meta.json"
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"✓ wrote {count} observations -> {path}")
    print(f"  fault: spans      = {len(fault_spans)}: {fault_spans}")
    print(f"  chronological     = {chronological}")
    print(f"  fields per event  = {len(summary['field_set'])}")
    print(f"  meta summary      -> {summary_path}")
    return 0


def main() -> int:
    _bootstrap()
    args = _parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(main())
