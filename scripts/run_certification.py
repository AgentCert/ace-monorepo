#!/usr/bin/env python3
"""End-to-end certification runner — drives the certifier pipeline against a
single Langfuse trace using the production code paths.

Mirrors the on-disk layout that the certifier's API workers create:

    {workspace}/{agent_id}/{experiment_id}/
        fault-bucketing/{run_id}/
            traces/raw_trace.json        — Phase 0 input (from Langfuse)
            fault_buckets/*.json         — Phase 0 output (per-fault buckets)
            metrics/*_metrics.json       — Phase 1 output (extracted metrics)
            ground_truth/*.json          — Phase 0 ground-truth dump
            pipeline_summary.json
        aggregation/aggregation.json     — Phase 2 output
        cert-builder/certification.json  — Phase 3 output (final certificate)
        pipeline_summary.json

By default the workspace is ``<repo>/.tmp`` (gitignored).

Usage:
    # Look up experiment_id / run_id automatically from a Langfuse trace ID
    ./scripts/run_certification.py --trace-id <UUID>

    # Or pass the IDs directly (skips the metadata lookup)
    ./scripts/run_certification.py \\
        --agent-id <UUID> --experiment-id <UUID> --run-id <UUID>

    # Optional knobs
    ./scripts/run_certification.py --trace-id <UUID> \\
        --workspace ./.tmp --batch-size 10 --runs-per-fault 1 --skip-cert
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import sys
from pathlib import Path
from urllib import parse, request


_SCRIPT_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _SCRIPT_DIR.parent
_CERTIFIER_ROOT = _REPO_ROOT / "certifier"
_DOTENV_PATH = _REPO_ROOT / ".env"
_DEFAULT_WORKSPACE = _REPO_ROOT / ".tmp"


# ── Bootstrap ────────────────────────────────────────────────────────

def _bootstrap() -> None:
    """Make the certifier package importable and load root .env."""
    if not _CERTIFIER_ROOT.exists():
        sys.exit(f"ERROR: certifier package not found at {_CERTIFIER_ROOT}")
    sys.path.insert(0, str(_CERTIFIER_ROOT))
    os.chdir(_CERTIFIER_ROOT)  # ConfigLoader resolves configs.json relative to CWD

    try:
        import dotenv
    except ImportError:
        sys.exit("ERROR: python-dotenv required (pip install python-dotenv)")
    if _DOTENV_PATH.exists():
        dotenv.load_dotenv(_DOTENV_PATH)

    # configs.json reads ENV_MONGODB_CONNECTION_STRING — derive from DB_SERVER
    # (the convention the rest of the monorepo uses) when not already set.
    if not os.environ.get("MONGODB_CONNECTION_STRING"):
        os.environ["MONGODB_CONNECTION_STRING"] = os.environ.get(
            "DB_SERVER", "mongodb://localhost:27017"
        )


# ── Trace metadata lookup (when --trace-id is given) ─────────────────

def _resolve_ids_from_trace_id(trace_id: str) -> dict:
    """Fetch a Langfuse trace by ID and return {agent_id, experiment_id, run_id, agent_name}.

    Uses the public REST API directly (synchronous urllib) rather than the
    Langfuse SDK so the resolver has no extra dependency beyond the SDK that
    TraceService already pulls in.
    """
    host = os.environ.get("LANGFUSE_HOST", "").rstrip("/")
    pk = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    sk = os.environ.get("LANGFUSE_SECRET_KEY", "")
    if not (host and pk and sk):
        sys.exit("ERROR: LANGFUSE_HOST / LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY "
                 "must be set (in .env or env-vars) to look up by --trace-id")

    auth = base64.b64encode(f"{pk}:{sk}".encode()).decode()
    url = f"{host}/api/public/traces/{parse.quote(trace_id)}"
    req = request.Request(url, headers={"Authorization": f"Basic {auth}"})
    try:
        with request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
    except Exception as exc:
        sys.exit(f"ERROR: Langfuse trace lookup failed for {trace_id}: {exc}")

    md = data.get("metadata") or {}
    ids = {
        "agent_id":       md.get("agent_id"),
        "agent_name":     md.get("agent_name") or "unknown",
        "experiment_id":  md.get("experiment_id"),
        "run_id":         md.get("experiment_run_id") or md.get("run_id"),
    }
    missing = [k for k, v in ids.items() if k != "agent_name" and not v]
    if missing:
        sys.exit(f"ERROR: trace {trace_id} metadata is missing required keys: {missing}")
    return ids


# ── Pipeline driver ──────────────────────────────────────────────────

async def _run_pipeline(args: argparse.Namespace) -> int:
    # Imports are deferred until after _bootstrap() has wired sys.path
    from main.models.bucket_requests import LangfuseTraceSource
    from main.services.pipeline_service import (
        BucketPipelineService,
        CertPipelineService,
    )
    from main.services.trace_service import TraceIngestionError, TraceService
    from utils.load_config import ConfigLoader

    config = ConfigLoader.load_config()

    workspace = Path(args.workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)

    # Match the certifier's on-disk layout exactly
    bucketing_root = workspace / args.agent_id / args.experiment_id / "fault-bucketing"
    run_dir = bucketing_root / args.run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    cert_root = workspace / args.agent_id / args.experiment_id

    print("─" * 72)
    print(f"  agent_id      = {args.agent_id} ({args.agent_name})")
    print(f"  experiment_id = {args.experiment_id}")
    print(f"  run_id        = {args.run_id}")
    print(f"  workspace     = {workspace}")
    print(f"  run_dir       = {run_dir}")
    print(f"  cert_root     = {cert_root}")
    print("─" * 72)

    # ─── Phase 0+1: trace acquisition + bucketing + extraction ──────
    print("\n[Phase 0+1] Acquiring trace from Langfuse")
    src = LangfuseTraceSource(type="langfuse", page_size=50, max_pages=10,
                              include_observations=True)
    try:
        trace_path, n = await TraceService().acquire_trace(
            src, run_dir / "traces",
            experiment_id=args.experiment_id, run_id=args.run_id,
        )
    except TraceIngestionError as exc:
        sys.exit(f"ERROR [{exc.error_code}]: {exc}")
    print(f"          fetched {n} observations -> {trace_path}")

    print("\n[Phase 0+1] Running bucketing + metric extraction")
    bucket_results = await BucketPipelineService().execute_pipeline(
        trace_file=str(trace_path),
        output_dir=str(run_dir),
        batch_size=args.batch_size,
        store_to_mongodb=False,
        agent_id=args.agent_id,
        config=config,
    )
    print(f"          extracted metrics for {len(bucket_results)} fault(s)")

    if not bucket_results:
        sys.exit("ERROR: no fault metrics produced — Phase 2+3 has nothing to consume")

    if args.skip_cert:
        print("\n[skip-cert] stopping after Phase 0+1 as requested")
        return _summarize_outputs(workspace, run_dir, cert_root, cert=False)

    # ─── Phase 2+3: aggregation + certification ──────────────────────
    print("\n[Phase 2+3] Aggregating + building certification report")
    # metrics_dir = parent fault-bucketing dir (matches production routing) so
    # all runs for the experiment are picked up by DirectoryQueryService.
    cert_report = await CertPipelineService().execute_pipeline(
        metrics_dir=str(bucketing_root),
        output_dir=str(cert_root),
        agent_id=args.agent_id,
        agent_name=args.agent_name,
        certification_run_id=args.run_id,
        runs_per_fault=args.runs_per_fault,
        debug=args.debug,
        config=config,
    )
    if not cert_report:
        sys.exit("ERROR: certification report was empty — see logs above")

    pdf_path: Path | None = None
    if not args.no_pdf:
        cert_json = cert_root / "cert-builder" / "certification.json"
        try:
            from importlib import util as _ilu
            spec = _ilu.spec_from_file_location(
                "render_certification_pdf",
                _SCRIPT_DIR / "render_certification_pdf.py",
            )
            mod = _ilu.module_from_spec(spec); spec.loader.exec_module(mod)
            pdf_path = cert_json.with_suffix(".pdf")
            print("\n[Phase 4]   Rendering PDF certificate")
            mod.render(cert_json, pdf_path)
            print(f"          {pdf_path}")
        except Exception as exc:
            # PDF rendering is a nice-to-have; don't fail the whole run.
            print(f"WARNING: PDF render skipped — {exc}")
            pdf_path = None

    return _summarize_outputs(workspace, run_dir, cert_root, cert=True, pdf=pdf_path)


def _summarize_outputs(workspace: Path, run_dir: Path, cert_root: Path,
                       cert: bool, pdf: Path | None = None) -> int:
    print("\n" + "=" * 72)
    print("Pipeline complete")
    print("=" * 72)
    print(f"  trace      : {run_dir}/traces/raw_trace.json")
    print(f"  buckets    : {run_dir}/fault_buckets/")
    print(f"  metrics    : {run_dir}/metrics/")
    print(f"  ground_truth: {run_dir}/ground_truth/")
    if cert:
        print(f"  scorecard  : {cert_root}/aggregation/aggregation.json")
        print(f"  CERTIFICATE: {cert_root}/cert-builder/certification.json")
        if pdf:
            print(f"  PDF        : {pdf}")
    print()
    return 0


# ── CLI ──────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    g = p.add_argument_group("trace selection (one of these is required)")
    g.add_argument("--trace-id", default=None,
                   help="Langfuse trace ID; agent/experiment/run IDs are read "
                        "from the trace's metadata.")
    g.add_argument("--agent-id", default=None,
                   help="agent ID (required when --trace-id is not given).")
    g.add_argument("--experiment-id", default=None,
                   help="experiment ID (required when --trace-id is not given).")
    g.add_argument("--run-id", default=None,
                   help="run ID (required when --trace-id is not given).")
    g.add_argument("--agent-name", default=None,
                   help="human-readable agent name (auto-detected when "
                        "--trace-id is given; defaults to 'unknown' otherwise).")

    p.add_argument("--workspace", default=str(_DEFAULT_WORKSPACE),
                   help=f"root workspace dir (default: {_DEFAULT_WORKSPACE}).")
    p.add_argument("--batch-size", type=int, default=10,
                   help="LLM classification batch size for Phase 0 (default: 10).")
    p.add_argument("--runs-per-fault", type=int, default=1,
                   help="N runs expected per fault, for Phase 2 stats "
                        "significance checks (default: 1).")
    p.add_argument("--skip-cert", action="store_true",
                   help="stop after Phase 0+1 (skip aggregation + cert builder).")
    p.add_argument("--no-pdf", action="store_true",
                   help="skip the post-run PDF render of the certification report.")
    p.add_argument("--debug", action="store_true",
                   help="retain intermediate Phase 3 outputs for inspection.")

    args = p.parse_args()

    if args.trace_id:
        ids = _resolve_ids_from_trace_id(args.trace_id)
        # Fill in any unprovided value from the trace metadata; explicit CLI flags win.
        args.agent_id      = args.agent_id      or ids["agent_id"]
        args.agent_name    = args.agent_name    or ids["agent_name"]
        args.experiment_id = args.experiment_id or ids["experiment_id"]
        args.run_id        = args.run_id        or ids["run_id"]
    elif not (args.agent_id and args.experiment_id and args.run_id):
        p.error("supply either --trace-id, or all three of "
                "--agent-id / --experiment-id / --run-id.")

    args.agent_name = args.agent_name or "unknown"
    return args


def main() -> int:
    _bootstrap()
    return asyncio.run(_run_pipeline(_parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
