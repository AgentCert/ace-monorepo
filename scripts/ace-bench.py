#!/usr/bin/env python3
"""ace-bench — local dev-tool for the trace_based pipeline only.

This script is a development convenience for running flash-agent experiments
locally WITHOUT the LitmusChaos control plane.  For all production benchmarking
use the LitmusChaos Argo Workflow (registered in AgentCert) — it is the
canonical orchestrator for both flash-agent and all ITBench scenarios.

Usage:
    python scripts/ace-bench.py flash-agent [options]

Reads agents/harness/<agent>/bench.yaml for all pipeline and certifier config.
All intermediate artefacts land in .tmp/bench/<agent>/ by default.

Supported pipeline: trace_based only.
Removed pipelines (now handled by LitmusChaos): ciso, sre, itbench_sre.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    # yaml is available inside the certifier venv; fall back to a minimal
    # YAML subset parser for plain key: value / list-of-dict structures.
    yaml = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent   # ace-monorepo root
CERTIFIER_DIR = REPO / "certifier"
DEFAULT_CERTIFIER_VENV = REPO / ".venv-certifier"
RENDER_PDF_SCRIPT = REPO / "scripts" / "render_certification_pdf.py"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_yaml(path: Path) -> dict:
    if yaml is not None:
        return yaml.safe_load(path.read_text()) or {}
    # Minimal fallback: only used when PyYAML isn't on sys.path.
    # Delegates to the certifier venv's python once we know which venv to use.
    # This is only called early (to read bench.yaml) before the venv is set up,
    # so we shell out to any available python3 that has PyYAML.
    result = subprocess.run(
        ["python3", "-c",
         f"import yaml,sys; print(__import__('json').dumps(yaml.safe_load(open({str(path)!r}))))"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        die(f"Could not parse {path}: install PyYAML (pip install pyyaml)")
    return json.loads(result.stdout)


def load_env_file(env_file: Path) -> dict[str, str]:
    """Parse a simple KEY=VALUE env file (comments and blank lines ignored)."""
    env: dict[str, str] = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()
    return env


def certifier_python(cfg: dict) -> Path:
    venv_rel = cfg.get("certifier", {}).get("venv", ".venv-certifier")
    venv = REPO / venv_rel if not Path(venv_rel).is_absolute() else Path(venv_rel)
    python = venv / "bin" / "python"
    if not python.exists():
        die(
            f"Certifier venv not found at {venv}.\n"
            "Create it with:  python3 -m venv .venv-certifier && "
            ".venv-certifier/bin/pip install -r certifier/requirements.txt"
        )
    return python


def run_setup(harness_dir: Path, skip: bool) -> None:
    setup = harness_dir / "setup.sh"
    if not setup.exists():
        log("No setup.sh found — skipping.")
        return
    if skip:
        log("--skip-setup: skipping setup.sh.")
        return
    log(f"Running setup.sh …")
    result = subprocess.run(["bash", str(setup)], cwd=str(REPO))
    if result.returncode != 0:
        die("setup.sh failed.")
    log("setup.sh done.")


def invoke_harness(harness_dir: Path, scenario_data: dict,
                   env_extras: dict[str, str],
                   agent_tmpdir: Path) -> tuple[int, str]:
    """Run the agent via the harness bash script defined in agent-harness.yaml.

    Writes scenario_data to /tmp/agent/scenario_data.json (the harness contract),
    executes the run command, and captures output.

    Returns (returncode, combined_stdout+stderr).
    """
    harness_yaml_path = harness_dir / "agent-harness.yaml"
    harness_cfg = load_yaml(harness_yaml_path)
    run_stanza = harness_cfg.get("run", {})
    cmd_parts: list[str] = run_stanza.get("command", ["/bin/bash"])
    args_list: list[str] = run_stanza.get("args", [])
    # The YAML args are typically ["-c", "script..."].  Joining naively with
    # "\n" produces "-c\nscript..." which bash 5.2+ reinterprets as a shell
    # option ("-c") rather than the start of a script, causing an "invalid
    # option" abort.  When args starts with "-c", skip it and pass only the
    # script body as the argument to our own "-c" flag.
    if args_list and args_list[0] == "-c":
        bash_body = "\n".join(args_list[1:])
    else:
        bash_body = "\n".join(args_list)

    # The harness contract: /tmp/agent/scenario_data.json
    os.makedirs("/tmp/agent", exist_ok=True)
    (Path("/tmp/agent") / "scenario_data.json").write_text(json.dumps(scenario_data))

    env = os.environ.copy()
    env.update(env_extras)

    try:
        proc = subprocess.run(
            cmd_parts + ["-c", bash_body],
            capture_output=True, text=True,
            env=env, cwd=str(harness_dir),
            timeout=int(env_extras.get("_HARNESS_TIMEOUT_S", 900)),
        )
        return proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired:
        return -1, "harness timeout"


def extract_tar_output(dest: Path) -> None:
    """Copy files the harness wrote to /tmp/agent/agent_data.tar into dest."""
    tar_path = Path("/tmp/agent/agent_data.tar")
    if not tar_path.exists():
        return
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest)


def run_certifier(cfg: dict, metrics_dir: Path, output_dir: Path,
                  python: Path) -> None:
    cert_cfg = cfg.get("certifier", {})
    agent_id = cfg["agent_id"]
    agent_name = cfg["agent_name"]
    runs_per_fault = cert_cfg.get("runs_per_fault", 5)
    extra: list[str] = []
    if cert_cfg.get("include_ciso_finops"):
        extra.append("--include-ciso-finops")
    if cert_cfg.get("advanced_analysis"):
        extra.append("--advanced-analysis")

    output_dir.mkdir(parents=True, exist_ok=True)
    log("Running certifier pipeline (Phase 2→3→4) …")
    result = subprocess.run(
        [str(python), "-m", "main.cli.run_aggregation_and_certification_pipeline",
         "--metrics-dir", str(metrics_dir.resolve()),
         "--output-dir", str(output_dir.resolve()),
         "--agent-id", agent_id,
         "--agent-name", agent_name,
         "--runs-per-fault", str(runs_per_fault),
         ] + extra,
        cwd=str(CERTIFIER_DIR),
    )
    if result.returncode != 0:
        die("Certifier pipeline failed.")


def render_pdf(python: Path, cert_json: Path, pdf_path: Path) -> None:
    if not RENDER_PDF_SCRIPT.exists():
        log("render_certification_pdf.py not found — skipping PDF.")
        return
    result = subprocess.run(
        [str(python), str(RENDER_PDF_SCRIPT),
         "--input", str(cert_json), "--output", str(pdf_path)],
    )
    if result.returncode == 0:
        log(f"PDF written → {pdf_path}")
    else:
        log("PDF rendering failed (non-fatal).")


def load_results(results_file: Path) -> list[dict]:
    if not results_file.exists():
        return []
    return [json.loads(l) for l in results_file.read_text().splitlines() if l.strip()]


def append_result(results_file: Path, record: dict) -> None:
    with open(results_file, "a") as f:
        f.write(json.dumps(record) + "\n")


# ---------------------------------------------------------------------------
# Trace-based pipeline (flash-agent / LitmusChaos dev-tool)
# ---------------------------------------------------------------------------
# NOTE: ciso, sre, and itbench_sre pipelines have been removed.
# Those agents are now orchestrated via the LitmusChaos Argo Workflow.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Trace-based pipeline (flash-agent / LitmusChaos)
# ---------------------------------------------------------------------------

def run_trace_based_pipeline(cfg: dict, harness_dir: Path, output_dir: Path,
                              env_vars: dict, resume: bool,
                              runs_override: int | None) -> Path:
    """Run the trace-based pipeline (LitmusChaos fault injection + Langfuse traces).

    Requires:
      - Running Kubernetes cluster (KinD or k3s) with LitmusChaos installed
      - Langfuse service reachable at trace_based.langfuse_base_url
      - ChaosExperiment + ChaosEngine YAML files in trace_based.engines_dir

    Pipeline per fault per run:
      submit ChaosEngine → run agent via harness → capture trace_id → Phase 0+1
    Then Phase 2+3+4 over all accumulated metrics.
    """
    tb_cfg = cfg.get("trace_based", {})
    engines_dir = _resolve_path(tb_cfg.get("engines_dir", ".tmp/mass-execution"))
    langfuse_url = tb_cfg.get("langfuse_base_url", "http://127.0.0.1:4001")

    # Prereq check: kubectl
    if shutil.which("kubectl") is None:
        die("kubectl not found — trace_based pipeline requires a live k8s cluster.")

    # Prereq check: Langfuse reachable
    import urllib.request
    try:
        urllib.request.urlopen(f"{langfuse_url}/api/public/health", timeout=5)
    except Exception:
        die(
            f"Langfuse unreachable at {langfuse_url}.\n"
            "Start it with: bash scripts/start-local-services.sh"
        )

    workdir = output_dir / "scenarios"
    metrics_dir = output_dir / "certifier-metrics"
    results_file = output_dir / "results.jsonl"
    workdir.mkdir(parents=True, exist_ok=True)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    if not resume:
        results_file.write_text("")

    # One stable session ID for this entire benchmarking run so all per-fault
    # per-run Langfuse traces appear together under a single Langfuse session.
    import uuid as _uuid_mod
    session_id_file = output_dir / "benchmark_session_id.txt"
    if resume and session_id_file.exists():
        benchmark_session_id = session_id_file.read_text().strip()
    else:
        benchmark_session_id = str(_uuid_mod.uuid4())
        session_id_file.write_text(benchmark_session_id)
    log(f"benchmark session_id={benchmark_session_id}")

    repeat_per_fault = tb_cfg.get("repeat_per_fault", 1)

    done_counts: dict[str, int] = {}
    for r in load_results(results_file):
        if r.get("status") == "success":
            fn = r.get("fault", "")
            done_counts[fn] = done_counts.get(fn, 0) + 1

    engine_yamls = sorted(engines_dir.glob("engine-*.yaml"))
    if runs_override:
        engine_yamls = engine_yamls[:runs_override]

    log(f"trace_based: {len(engine_yamls)} fault engines found under {engines_dir.name}, "
        f"{repeat_per_fault} run(s) each")

    # Import certifier Phase 0+1 runner
    sys.path.insert(0, str(CERTIFIER_DIR))

    for engine_yaml in engine_yamls:
        fault_name = engine_yaml.stem.removeprefix("engine-")
        n_done = done_counts.get(fault_name, 0)
        if n_done >= repeat_per_fault:
            log(f"SKIP {fault_name} ({n_done}/{repeat_per_fault} runs done)")
            continue

        rbac_yaml = engines_dir / f"rbac-{fault_name}.yaml"

        # Resolve the ChaosExperiment CRD for this fault.  itbench faults ship
        # their own litmuschaos/k8s:latest-based CRD that is not part of the
        # standard LitmusChaos hub and must therefore be installed per-run.
        # kubernetes/ faults already have their CRDs installed via the hub, so
        # the apply is a no-op (idempotent) for them.
        fault_crd: "Path | None" = None
        for _cat in ("itbench", "kubernetes"):
            _cand = REPO / "chaos-charts" / "faults" / _cat / fault_name / "fault.yaml"
            if _cand.exists():
                fault_crd = _cand
                break

        # Read the engine YAML's own metadata so we wait on and clean up the
        # correct object name and namespace (engines in .tmp/mass-execution use
        # otel-demo, not the litmus default, and some have a -r<n> name suffix).
        try:
            _eng_doc = load_yaml(engine_yaml)
            engine_obj_name = _eng_doc.get("metadata", {}).get("name", fault_name)
            engine_ns = _eng_doc.get("metadata", {}).get("namespace", "litmus")
        except Exception:
            engine_obj_name = fault_name
            engine_ns = "litmus"

        for run_idx in range(n_done, repeat_per_fault):
            run_id = uuid.uuid4().hex[:12]
            run_dir = workdir / f"{fault_name}-{run_id}"
            run_dir.mkdir(parents=True, exist_ok=True)
            t0 = time.time()
            log(f"  fault: {fault_name} (run {run_idx + 1}/{repeat_per_fault})")

            # Install ChaosExperiment CRD (itbench faults need this; kubernetes/
            # faults already have theirs in the cluster).
            if fault_crd is not None:
                _r = subprocess.run(
                    ["kubectl", "apply", "-n", engine_ns, "-f", str(fault_crd)],
                    capture_output=True,
                )
                if _r.returncode != 0:
                    log(f"  WARN: fault.yaml apply failed for {fault_name}: "
                        f"{_r.stderr.decode(errors='replace')[-200:]}")

            # Apply RBAC + ChaosEngine
            if rbac_yaml.exists():
                subprocess.run(["kubectl", "apply", "-f", str(rbac_yaml)], capture_output=True)
            subprocess.run(["kubectl", "apply", "-f", str(engine_yaml)], capture_output=True)

            # Settle pause: let the experiment pod start and inject the fault before
            # the agent begins scanning.  Especially important for itbench faults
            # (litmuschaos/k8s:latest image-pull + kubectl exec overhead).
            fault_settle_s = tb_cfg.get("fault_settle_s", 15)
            if fault_settle_s > 0:
                log(f"    waiting {fault_settle_s}s for fault to take effect…")
                time.sleep(fault_settle_s)

            # Run agent via harness
            mcp_urls = tb_cfg.get("mcp_urls", "http://localhost:31086/mcp,http://localhost:31085/mcp")
            scan_query = tb_cfg.get("scan_query",
                                    "Analyse Kubernetes cluster health and report all issues")
            # Pre-generate NOTIFY_ID here so the sidecar uses the same trace_id
            # we record in results (harness falls back to its own UUID if unset).
            notify_id = str(_uuid_mod.uuid4())
            harness_extras = dict(env_vars)
            harness_extras.update({
                "EXPERIMENT_ID": fault_name,
                "RUN_ID": run_id,
                "NOTIFY_ID": notify_id,
                "SESSION_ID": benchmark_session_id,
                "WORKFLOW_NAME": fault_name,
                "_HARNESS_TIMEOUT_S": str(tb_cfg.get("agent_timeout_s", 600)),
            })
            scenario_data: dict[str, Any] = {
                "mcp_urls": mcp_urls,
                "model_alias": env_vars.get("MODEL_ALIAS", "qwen2.5-7b-instruct"),
                "openai_base_url": env_vars.get("OPENAI_BASE_URL", "http://127.0.0.1:14000/v1"),
                "scan_query": scan_query,
            }
            agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                                  harness_extras, run_dir)
            (run_dir / "agent.log").write_text(agent_log)

            # Extract Langfuse trace_id from agent log
            trace_id = _extract_trace_id(agent_log)

            # Wait for ChaosEngine to complete before cleanup.  Use the engine's own
            # metadata.name (may differ from fault_name, e.g. -r1 suffix) and the
            # correct namespace (otel-demo for all .tmp/mass-execution engines).
            _wait_chaos_engine_complete(engine_obj_name, namespace=engine_ns, timeout_s=300)
            subprocess.run(["kubectl", "delete", "-f", str(engine_yaml)],
                           capture_output=True)
            if rbac_yaml.exists():
                subprocess.run(["kubectl", "delete", "-f", str(rbac_yaml)], capture_output=True)
            # Remove the ChaosExperiment CRD we installed for this fault so the
            # cluster is left clean for the next iteration.
            if fault_crd is not None:
                subprocess.run(
                    ["kubectl", "delete", "chaosexperiment", fault_name,
                     "-n", engine_ns, "--ignore-not-found"],
                    capture_output=True,
                )

            dt = round(time.time() - t0, 1)

            if trace_id:
                log(f"    trace_id={trace_id} — running Phase 0+1")
                phase01_dir = metrics_dir / "phase01" / fault_name
                phase01_dir.mkdir(parents=True, exist_ok=True)
                # Pass all known IDs explicitly so the certifier can use direct
                # trace_id lookup.  agent-sidecar traces set experiment_run_id
                # (= trace_id) but never experiment_id; the metadata fallback
                # alone would fail to find the trace.
                phase01_result = subprocess.run(
                    [str(certifier_python(cfg)),
                     str(REPO / "scripts" / "run_certification.py"),
                     "--trace-id",    trace_id,
                     "--agent-id",    cfg.get("agent_id", ""),
                     "--agent-name",  cfg.get("agent_name", ""),
                     "--experiment-id", fault_name,
                     "--run-id",      trace_id,
                     "--workspace",   str(phase01_dir),
                     "--skip-cert"],
                    capture_output=True, text=True,
                )
                if phase01_result.returncode == 0:
                    # move *_metrics.json files up to metrics_dir, prefixed with
                    # fault+run_id to avoid collisions across repeated runs
                    for mf in phase01_dir.rglob("*_metrics.json"):
                        dest_name = f"{fault_name}-{run_id}_{mf.name}"
                        shutil.copy2(mf, metrics_dir / dest_name)
                    status = "success"
                else:
                    status = "phase01_failed"
                    log(f"    Phase 0+1 failed: {phase01_result.stderr[-200:]}")
            else:
                status = "no_trace_id"
                log("    no trace_id found in agent log")

            record = {
                "fault": fault_name, "run_id": run_id, "status": status,
                "agent_status": "ok" if agent_rc == 0 else "agent_nonzero_exit",
                "trace_id": trace_id, "duration_s": dt,
            }
            append_result(results_file, record)
            log(f"  {status.upper()} {fault_name} in {dt}s")

    return metrics_dir


def _extract_trace_id(agent_log: str) -> str | None:
    import re
    m = re.search(r"trace[_\-]?id[\"']?\s*[:=]\s*[\"']?([0-9a-f\-]{32,})", agent_log, re.I)
    return m.group(1) if m else None


def _wait_chaos_engine_complete(
    engine_name: str,
    namespace: str = "litmus",
    timeout_s: int = 300,
) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        proc = subprocess.run(
            ["kubectl", "get", "chaosengine", engine_name,
             "-n", namespace, "-o", "jsonpath={.status.engineStatus}"],
            capture_output=True, text=True,
        )
        if proc.stdout.strip() in ("completed", "stopped"):
            return
        time.sleep(10)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _resolve_path(p: str | Path) -> Path:
    path = Path(p)
    if path.is_absolute():
        return path
    return REPO / path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ace-bench",
        description="Run the full ACE benchmarking pipeline for an agent.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python scripts/ace-bench.py ciso-agent
  python scripts/ace-bench.py sre-agent --resume
  python scripts/ace-bench.py flash-agent --skip-setup --runs 5

The agent name must match a folder under agents/ and agents/harness/.
Pipeline config is read from agents/harness/<agent>/bench.yaml.
        """,
    )
    parser.add_argument("agent", help="Agent folder name (e.g. ciso-agent)")
    parser.add_argument(
        "--output-dir", metavar="DIR",
        help="Where to write all outputs (default: .tmp/bench/<agent>)",
    )
    parser.add_argument(
        "--runs", type=int, metavar="N",
        help="Override the number of runs (SRE/trace_based: scenarios to run; "
             "CISO: runs per scenario-type from bench.yaml is used unless this is set)",
    )
    parser.add_argument(
        "--runs-per-fault", type=int, metavar="N", dest="runs_per_fault",
        help="Override repeat_per_fault from bench.yaml (trace_based pipeline). "
             "Use --runs-per-fault 1 for a quick single-pass test.",
    )
    parser.add_argument(
        "--resume", action="store_true",
        help="Resume a previous run — do not clear results.jsonl",
    )
    parser.add_argument(
        "--skip-setup", action="store_true",
        help="Skip setup.sh (use when venv is already built)",
    )
    parser.add_argument(
        "--skip-scenarios", action="store_true",
        help="Skip scenario execution — use existing results.jsonl and metrics docs",
    )
    parser.add_argument(
        "--skip-certifier", action="store_true",
        help="Skip the certifier pipeline (run scenarios only)",
    )
    args = parser.parse_args()

    # Locate harness
    harness_dir = REPO / "agents" / "harness" / args.agent
    if not harness_dir.is_dir():
        die(
            f"No harness found at {harness_dir}.\n"
            f"Expected: agents/harness/{args.agent}/bench.yaml  +  setup.sh  +  agent-harness.yaml"
        )

    bench_yaml = harness_dir / "bench.yaml"
    if not bench_yaml.exists():
        die(
            f"bench.yaml not found at {bench_yaml}.\n"
            "Create it following the schema in agents/README.md."
        )

    cfg = load_yaml(bench_yaml)

    # Validate required top-level fields
    for field in ("pipeline", "agent_id", "agent_name"):
        if not cfg.get(field):
            die(f"bench.yaml is missing required field: '{field}'")

    pipeline = cfg["pipeline"]

    # Output directory
    output_dir = Path(args.output_dir) if args.output_dir else REPO / ".tmp" / "bench" / args.agent
    output_dir.mkdir(parents=True, exist_ok=True)
    log(f"ace-bench  agent={args.agent}  pipeline={pipeline}")
    log(f"Output dir: {output_dir}")

    # Load env file if specified
    env_vars: dict[str, str] = {}
    env_file_rel = cfg.get("env_file")
    if env_file_rel:
        env_file = _resolve_path(env_file_rel)
        if not env_file.exists():
            die(f"env_file not found: {env_file}")
        env_vars = load_env_file(env_file)
        log(f"Loaded env file: {env_file} ({len(env_vars)} vars)")

    # Setup
    run_setup(harness_dir, args.skip_setup)

    # Run scenarios
    metrics_dir: Path | None = None
    if not args.skip_scenarios:
        if pipeline == "trace_based":
            metrics_dir = run_trace_based_pipeline(cfg, harness_dir, output_dir,
                                                    env_vars, args.resume, args.runs)
        else:
            die(
                f"Unknown pipeline type: {pipeline!r}. "
                "Only 'trace_based' is supported by this dev-tool script.\n"
                "For ciso / sre / itbench_sre agents use the LitmusChaos "
                "Argo Workflow registered in AgentCert."
            )
    else:
        metrics_dir = output_dir / "certifier-metrics"
        log("--skip-scenarios: using existing metrics docs.")

    # Certifier
    if args.skip_certifier:
        log("--skip-certifier: done.")
        return

    if not any(metrics_dir.glob("*_metrics.json")):
        die(f"No *_metrics.json files found in {metrics_dir}. "
            "Check that scenario runs succeeded.")

    python = certifier_python(cfg)
    cert_output = output_dir / "certifier-output"
    run_certifier(cfg, metrics_dir, cert_output, python)

    # PDF
    cert_json = cert_output / "cert-builder" / "certification.json"
    if cert_json.exists():
        pdf_path = cert_json.with_suffix(".pdf")
        render_pdf(python, cert_json, pdf_path)
        log("=" * 60)
        log(f"Benchmark complete for {args.agent}")
        log(f"  JSON report : {cert_json}")
        log(f"  PDF report  : {pdf_path}")
        log("=" * 60)
    else:
        log(f"Benchmark complete (no cert JSON at expected path {cert_json}).")


if __name__ == "__main__":
    main()
