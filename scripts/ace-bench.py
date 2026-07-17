#!/usr/bin/env python3
"""ace-bench — full ACE monorepo benchmarking pipeline for any agent.

Usage:
    python scripts/ace-bench.py <agent-name> [options]

Examples:
    python scripts/ace-bench.py ciso-agent
    python scripts/ace-bench.py sre-agent --resume
    python scripts/ace-bench.py flash-agent --skip-setup --runs 3

Reads agents/harness/<agent>/bench.yaml for all pipeline and certifier config.
All intermediate artefacts land in .tmp/bench/<agent>/ by default.
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
         "--metrics-dir", str(metrics_dir),
         "--output-dir", str(output_dir),
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
# CISO pipeline
# ---------------------------------------------------------------------------

def _run_docker_make(scenario_image: str, target: str,
                     scenario_ws: Path, agent_ws: Path,
                     scenarios_repo: Path, kubeconfig: Path,
                     timeout: int = 600, extra_args: list[str] | None = None) -> subprocess.CompletedProcess:
    name = f"ace-bench-task-{uuid.uuid4().hex[:8]}"
    cmd = [
        "sudo", "docker", "run", "--rm", "-i", "--name", name,
        "-v", f"{scenario_ws}:/tmp/scenario",
        "-v", f"{agent_ws}:/tmp/agent",
        "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
        scenario_image,
    ] + (extra_args or ["make", "-C", f"{target}"])
    return subprocess.run(cmd, cwd=str(scenarios_repo), capture_output=True, text=True, timeout=timeout)


def _ciso_get_goal(scenario_dir: str, scenario_ws: Path, agent_ws: Path,
                   scenario_image: str, scenarios_repo: Path, kubeconfig: Path) -> dict:
    name = f"ace-bench-task-{uuid.uuid4().hex[:8]}"
    cmd = [
        "sudo", "docker", "run", "--rm", "-i", "--name", name,
        "-v", f"{scenario_ws}:/tmp/scenario",
        "-v", f"{agent_ws}:/tmp/agent",
        "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
        scenario_image,
        "sh", "-c", f"make -s -C {scenario_dir} get 2>/dev/null",
    ]
    proc = subprocess.run(cmd, cwd=str(scenarios_repo), capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(f"make get failed: {proc.stderr[-400:]}")
    return json.loads(proc.stdout)


def run_ciso_pipeline(cfg: dict, harness_dir: Path, output_dir: Path,
                      env_vars: dict, resume: bool) -> Path:
    """Run all CISO scenario types and return the metrics directory."""
    ciso_cfg = cfg.get("ciso", {})
    scenarios_repo = _resolve_path(ciso_cfg["scenarios_repo"])
    scenario_image = ciso_cfg["scenario_image"]
    kubeconfig = _resolve_path(ciso_cfg["kubeconfig"])
    plan: list[dict] = ciso_cfg["plan"]

    workdir = output_dir / "scenarios"
    metrics_dir = output_dir / "certifier-metrics"
    results_file = output_dir / "results.jsonl"

    workdir.mkdir(parents=True, exist_ok=True)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    if not resume:
        results_file.write_text("")

    done_results = load_results(results_file)

    sys.path.insert(0, str(CERTIFIER_DIR))
    from metrics_extractor.scripts.ciso_metrics_adapter import build_ciso_metrics_doc  # noqa: PLC0415

    for entry in plan:
        scenario_dir = entry["dir"]
        scenario_type = entry["type"]
        num_runs = entry.get("runs", 1)

        done_for_type = [r for r in done_results
                         if r["scenario_dir"] == scenario_dir and r["status"] == "success"]
        if len(done_for_type) >= num_runs:
            log(f"SKIP {scenario_type}: {len(done_for_type)}/{num_runs} already done.")
            continue

        ws = workdir / "scenario-ws" / scenario_dir
        aw = workdir / "agent-ws" / scenario_dir
        ws.mkdir(parents=True, exist_ok=True)
        aw.mkdir(parents=True, exist_ok=True)

        log(f"=== {scenario_type}: deploy_bundle ===")
        deploy = subprocess.run(
            ["sudo", "docker", "run", "--rm", "-i",
             "--name", f"ace-bench-task-{uuid.uuid4().hex[:8]}",
             "-v", f"{ws}:/tmp/scenario",
             "-v", f"{aw}:/tmp/agent",
             "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
             scenario_image, "make", "-C", scenario_dir, "deploy_bundle"],
            cwd=str(scenarios_repo), capture_output=True, text=True, timeout=900,
        )
        if deploy.returncode != 0:
            log(f"deploy_bundle FAILED for {scenario_type}: {deploy.stderr[-400:]}")
            append_result(results_file, {
                "scenario_dir": scenario_dir, "scenario_type": scenario_type,
                "run_idx": 0, "status": "deploy_bundle_failed",
                "stderr_tail": deploy.stderr[-800:],
            })
            continue

        for run_idx in range(1, num_runs + 1):
            if any(r["run_idx"] == run_idx and r["status"] == "success"
                   for r in done_for_type):
                log(f"SKIP {scenario_type} run {run_idx} (already succeeded).")
                continue

            run_id = f"{scenario_dir.split('.')[0]}-run{run_idx}-{uuid.uuid4().hex[:8]}"
            archive = workdir / "archives" / run_id
            archive.mkdir(parents=True, exist_ok=True)
            t0 = time.time()

            # inject_fault
            log(f"  inject_fault ({scenario_type} run {run_idx})")
            inj = subprocess.run(
                ["sudo", "docker", "run", "--rm", "-i",
                 "--name", f"ace-bench-task-{uuid.uuid4().hex[:8]}",
                 "-v", f"{ws}:/tmp/scenario", "-v", f"{aw}:/tmp/agent",
                 "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
                 scenario_image, "make", "-C", scenario_dir, "inject_fault"],
                cwd=str(scenarios_repo), capture_output=True, text=True, timeout=300,
            )
            if inj.returncode != 0:
                append_result(results_file, {
                    "scenario_dir": scenario_dir, "scenario_type": scenario_type,
                    "run_idx": run_idx, "run_id": run_id, "status": "inject_fault_failed",
                    "duration_s": round(time.time() - t0, 1), "stderr_tail": inj.stderr[-600:],
                })
                continue

            # get goal
            log(f"  get goal ({scenario_type} run {run_idx})")
            try:
                goal_data = _ciso_get_goal(scenario_dir, ws, aw,
                                           scenario_image, scenarios_repo, kubeconfig)
            except Exception as exc:
                append_result(results_file, {
                    "scenario_dir": scenario_dir, "scenario_type": scenario_type,
                    "run_idx": run_idx, "run_id": run_id, "status": "get_goal_failed",
                    "duration_s": round(time.time() - t0, 1), "stderr_tail": str(exc),
                })
                continue

            kubeconfig_content = (goal_data.get("vars") or {}).get("kubeconfig", "")
            (aw / "kubeconfig.yaml").write_text(kubeconfig_content)

            # run agent via harness (pass raw template — harness does {{ kubeconfig }} substitution)
            log(f"  run agent ({scenario_type} run {run_idx})")
            scenario_data = {
                "goal_template": goal_data["goal_template"],
                "vars": {
                    "kubeconfig": kubeconfig_content,
                    "ansible_ini": "",
                    "ansible_user_key": "",
                },
            }
            harness_extras = dict(env_vars)
            harness_extras["_HARNESS_TIMEOUT_S"] = "900"
            agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                                  harness_extras, archive)
            (archive / "agent.log").write_text(agent_log)
            agent_status = "ok" if agent_rc == 0 else ("agent_timeout" if agent_rc == -1 else "agent_nonzero_exit")

            # Populate aw with the agent's tar output so evaluate.yml can find
            # agent_output.data (for generate_policy / evidence_available checks).
            extract_tar_output(aw)

            # evaluate
            log(f"  evaluate ({scenario_type} run {run_idx})")
            ev = subprocess.run(
                ["sudo", "docker", "run", "--rm", "-i",
                 "--name", f"ace-bench-task-{uuid.uuid4().hex[:8]}",
                 "-v", f"{ws}:/tmp/scenario", "-v", f"{aw}:/tmp/agent",
                 "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
                 scenario_image, "make", "-C", scenario_dir, "evaluate"],
                cwd=str(scenarios_repo), capture_output=True, text=True, timeout=300,
            )
            evaluation_result = None
            eval_json = ws / "evaluation.json"
            if ev.returncode == 0 and eval_json.exists():
                try:
                    evaluation_result = json.loads(eval_json.read_text())
                    (archive / "evaluation.json").write_text(eval_json.read_text())
                except json.JSONDecodeError:
                    pass

            # revert
            log(f"  revert ({scenario_type} run {run_idx})")
            subprocess.run(
                ["sudo", "docker", "run", "--rm", "-i",
                 "--name", f"ace-bench-task-{uuid.uuid4().hex[:8]}",
                 "-v", f"{ws}:/tmp/scenario", "-v", f"{aw}:/tmp/agent",
                 "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
                 scenario_image, "make", "-C", scenario_dir, "revert"],
                cwd=str(scenarios_repo), capture_output=True, text=True, timeout=300,
            )

            dt = round(time.time() - t0, 1)
            status = "success" if evaluation_result is not None else "no_evaluation"
            passed = (evaluation_result or {}).get("pass")
            record = {
                "scenario_dir": scenario_dir, "scenario_type": scenario_type,
                "run_idx": run_idx, "run_id": run_id, "status": status,
                "agent_status": agent_status, "duration_s": dt,
                "evaluation_result": evaluation_result,
                "evaluate_returncode": ev.returncode,
            }
            append_result(results_file, record)
            log(f"  {status.upper()} {scenario_type} run {run_idx} "
                f"in {dt}s | pass={passed}")

            # write metrics doc
            if evaluation_result is not None:
                doc = build_ciso_metrics_doc(
                    evaluation_result,
                    scenario_type=scenario_type,
                    run_id=run_id,
                    duration_seconds=dt,
                    agent_id=cfg["agent_id"],
                    agent_name=cfg["agent_name"],
                    experiment_id=scenario_type,
                )
                (metrics_dir / f"{run_id}_metrics.json").write_text(json.dumps(doc, indent=2))

        log(f"=== {scenario_type}: destroy_bundle ===")
        subprocess.run(
            ["sudo", "docker", "run", "--rm", "-i",
             "--name", f"ace-bench-task-{uuid.uuid4().hex[:8]}",
             "-v", f"{ws}:/tmp/scenario", "-v", f"{aw}:/tmp/agent",
             "-v", f"{kubeconfig}:/etc/ciso-task-scenarios/kubeconfig.yaml",
             scenario_image, "make", "-C", scenario_dir, "destroy_bundle"],
            cwd=str(scenarios_repo), capture_output=True, text=True, timeout=600,
        )

    return metrics_dir


# ---------------------------------------------------------------------------
# SRE pipeline
# ---------------------------------------------------------------------------

def run_sre_pipeline(cfg: dict, harness_dir: Path, output_dir: Path,
                     env_vars: dict, resume: bool, runs_override: int | None) -> Path:
    """Run the SRE agent over ITBench-Lite snapshots and return the metrics dir."""
    sre_cfg = cfg.get("sre", {})
    snapshots_dir = _resolve_path(sre_cfg["snapshots_dir"])
    if not snapshots_dir.exists():
        die(
            f"Snapshots directory not found: {snapshots_dir}\n"
            "Download ITBench-Lite first:\n"
            "  cd agents/sre-agent && huggingface-cli download --repo-type dataset "
            "  itbench-org/ITBench-Lite --local-dir ITBench-Lite"
        )

    model = sre_cfg.get("model", "openai/qwen2.5-7b-instruct")
    prompt_file = sre_cfg.get("prompt_file", "sre_react_shell_investigation.md")
    goal_template = sre_cfg.get("goal_template", "Start the investigation")
    timeout_s = sre_cfg.get("per_scenario_timeout_s", 1200)

    workdir = output_dir / "scenarios"
    metrics_dir = output_dir / "certifier-metrics"
    results_file = output_dir / "results.jsonl"
    workdir.mkdir(parents=True, exist_ok=True)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    if not resume:
        results_file.write_text("")

    done = {r["scenario"]: r for r in load_results(results_file)
            if r.get("status") == "success"}

    scenarios = sorted(p.name for p in snapshots_dir.iterdir()
                       if p.is_dir() and p.name.startswith("Scenario-"))
    if runs_override:
        scenarios = scenarios[:runs_override]

    log(f"SRE: {len(scenarios)} scenarios found under {snapshots_dir.name}")

    sys.path.insert(0, str(CERTIFIER_DIR))
    from metrics_extractor.scripts.sre_agent_metrics_adapter import build_sre_agent_metrics_doc  # noqa: PLC0415

    for scenario_name in scenarios:
        if scenario_name in done:
            log(f"SKIP {scenario_name} (already succeeded).")
            continue

        scenario_path = snapshots_dir / scenario_name
        run_id = f"{scenario_name}-{uuid.uuid4().hex[:8]}"
        t0 = time.time()

        scenario_data = {
            "snapshot_dirs": str(scenario_path),
            "model": model,
            "prompt_file": prompt_file,
            "goal_template": goal_template,
        }

        log(f"  run {scenario_name}")
        harness_extras = dict(env_vars)
        harness_extras["_HARNESS_TIMEOUT_S"] = str(timeout_s)
        agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                              harness_extras,
                                              workdir / "agent-out" / scenario_name)

        agent_log_file = workdir / "logs" / f"{scenario_name}.log"
        agent_log_file.parent.mkdir(parents=True, exist_ok=True)
        agent_log_file.write_text(agent_log)

        # Extract agent_output.json from the tar the harness produced
        out_dir = workdir / "outputs" / scenario_name / "1"
        extract_tar_output(out_dir)

        agent_output_path = out_dir / "agent_output.json"
        agent_output: dict | None = None
        if agent_output_path.exists():
            try:
                agent_output = json.loads(agent_output_path.read_text())
            except json.JSONDecodeError:
                pass

        dt = round(time.time() - t0, 1)
        status = "success" if agent_output else "no_output"
        record = {
            "scenario": scenario_name, "run_id": run_id, "status": status,
            "agent_status": "ok" if agent_rc == 0 else "agent_nonzero_exit",
            "duration_s": dt,
        }
        append_result(results_file, record)
        log(f"  {status.upper()} {scenario_name} in {dt}s")

        if agent_output:
            # Evaluation via itbench_evaluations (if installed); build metrics doc
            scores = _evaluate_sre_output(agent_output, scenario_path)
            doc = build_sre_agent_metrics_doc(
                scores,
                scenario_name=scenario_name,
                run_id=run_id,
                duration_seconds=dt,
                agent_id=cfg["agent_id"],
                agent_name=cfg["agent_name"],
            )
            (metrics_dir / f"{run_id}_metrics.json").write_text(json.dumps(doc, indent=2))

    return metrics_dir


def _evaluate_sre_output(agent_output: dict, scenario_path: Path) -> dict:
    """Run ITBench-Evaluations on one agent_output.json if available.

    itbench_evaluations is installed in the certifier venv (.venv-certifier).
    We prepend its site-packages to sys.path so the import resolves even when
    ace-bench.py is run under the system Python3 (which cannot install packages).
    """
    import glob as _glob
    for _sp in _glob.glob(str(REPO / ".venv-certifier/lib/python*/site-packages")):
        if _sp not in sys.path:
            sys.path.insert(0, _sp)

    try:
        from itbench_evaluations import evaluate_single, load_ground_truth  # type: ignore[import]
        gt_path = scenario_path / "ground_truth.yaml"
        if not gt_path.exists():
            return {}
        gt_data = load_ground_truth(str(gt_path))
        incident_id, gt = next(iter(gt_data.items()))
        # evaluate_single is async; set judge env defaults pointing at the
        # local LiteLLM proxy if not already configured.
        os.environ.setdefault("JUDGE_BASE_URL", "http://127.0.0.1:14000/v1")
        os.environ.setdefault("JUDGE_API_KEY", "ollama")
        os.environ.setdefault("JUDGE_MODEL", "qwen2.5-7b-instruct")
        result = asyncio.run(evaluate_single(gt, agent_output, incident_id))
        return result.get("scores", {})
    except Exception:
        pass
    # Return an empty scores dict — the metrics adapter handles missing fields gracefully.
    return {}


def _patch_chaos_result(engine_yaml_path: Path, verdict: str) -> None:
    """Patch the ChaosResult CR verdict after the agent run (best-effort).

    Shell-script litmus experiments never call the litmus-go SDK, so the
    auto-created ChaosResult stays at status.verdict=Awaited forever.  Patching
    it here lets the Litmus portal show Pass/Fail badges and keeps the CR
    consistent with the ACE verdict for the same run.
    """
    try:
        eng = load_yaml(engine_yaml_path)
        engine_name = eng.get("metadata", {}).get("name", "")
        namespace = eng.get("metadata", {}).get("namespace", "default") or "default"
        experiments = eng.get("spec", {}).get("experiments", [])
        if not engine_name or not experiments:
            log(f"    [chaos-result] could not extract names from {engine_yaml_path.name}")
            return
        experiment_name = experiments[0].get("name", "")
        if not experiment_name:
            log(f"    [chaos-result] spec.experiments[0].name missing in {engine_yaml_path.name}")
            return
        cr_name = f"{engine_name}-{experiment_name}"[:63]
        patch_json = json.dumps({"status": {"phase": "Completed", "verdict": verdict}})
        result = subprocess.run(
            ["kubectl", "patch", "chaosresult", cr_name,
             "-n", namespace, "--type=merge", "-p", patch_json],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            log(f"    [chaos-result] patched {cr_name} → {verdict}")
        else:
            log(f"    [chaos-result] patch failed for {cr_name}: {result.stderr.strip()}")
    except Exception as exc:
        log(f"    [chaos-result] patch skipped ({exc})")


# ---------------------------------------------------------------------------
# ITBench-SRE pipeline (SRE agent + chaos-charts/faults/itbench/ scenarios)
# ---------------------------------------------------------------------------

def run_itbench_sre_pipeline(cfg: dict, harness_dir: Path, output_dir: Path,
                              env_vars: dict, resume: bool,
                              runs_override: int | None) -> Path:
    """Run the SRE agent against chaos-charts itbench faults (online/live mode).

    Pipeline per fault:
      apply RBAC + ChaosEngine → pause for fault to take effect →
      run SRE agent harness (online mode) → capture output → revert engine

    Evaluates agent_output.json presence; skips Langfuse (SRE uses structured
    output evaluation, not trace-based certification).

    Supports:
      itbench_sre.faults_dirs  — list of fault directories (preferred)
      itbench_sre.faults_dir   — single fault directory (legacy)
      itbench_sre.runs_per_fault — how many successful runs to collect per fault
    """
    itsre_cfg = cfg.get("itbench_sre", {})
    engines_dir = _resolve_path(itsre_cfg.get("engines_dir", ".tmp/mass-execution"))
    runs_per_fault = itsre_cfg.get("runs_per_fault", 1)
    capability_probes: list[dict] = cfg.get("capability_probes", [])

    if not engines_dir.exists():
        die(f"engines_dir not found: {engines_dir}")

    # Support both faults_dirs (list) and legacy faults_dir (single path).
    faults_dirs_cfg = itsre_cfg.get("faults_dirs", None)
    if faults_dirs_cfg:
        all_faults_roots = [_resolve_path(fd) for fd in faults_dirs_cfg]
    else:
        faults_dir = _resolve_path(itsre_cfg.get("faults_dir", "chaos-charts/faults/itbench"))
        all_faults_roots = [faults_dir]

    for fd in all_faults_roots:
        if not fd.exists():
            die(f"faults_dir not found: {fd}")

    model = itsre_cfg.get("model", "qwen2.5:7b-instruct")
    prompt_file = itsre_cfg.get("prompt_file", "sre_react_online_base.md")
    fault_settle_s = itsre_cfg.get("fault_settle_s", 15)
    timeout_s = itsre_cfg.get("per_scenario_timeout_s", 1200)

    workdir = output_dir / "scenarios"
    metrics_dir = output_dir / "certifier-metrics"
    results_file = output_dir / "results.jsonl"
    workdir.mkdir(parents=True, exist_ok=True)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    if not resume:
        results_file.write_text("")

    # Count successful runs per fault (supports multiple runs per fault).
    done_counts: dict[str, int] = {}
    for r in load_results(results_file):
        if r.get("status") == "success":
            fn = r.get("fault", "")
            done_counts[fn] = done_counts.get(fn, 0) + 1

    # Collect all fault directories that have a ground_truth.yaml.
    fault_dirs: list[Path] = []
    for faults_root in all_faults_roots:
        fault_dirs.extend(sorted(
            p for p in faults_root.iterdir()
            if p.is_dir() and (p / "ground_truth.yaml").exists()
        ))
    if runs_override:
        fault_dirs = fault_dirs[:runs_override]

    log(f"itbench_sre: {len(fault_dirs)} faults across "
        f"{len(all_faults_roots)} director{'y' if len(all_faults_roots) == 1 else 'ies'}, "
        f"{runs_per_fault} run(s) each")

    # Eagerly import metrics adapter (certifier path must be on sys.path first).
    sys.path.insert(0, str(CERTIFIER_DIR))
    from metrics_extractor.scripts.sre_agent_metrics_adapter import (  # noqa: PLC0415
        build_sre_agent_metrics_doc,
    )

    for fault_dir in fault_dirs:
        fault_name = fault_dir.name
        n_done = done_counts.get(fault_name, 0)
        if n_done >= runs_per_fault:
            log(f"SKIP {fault_name} ({n_done}/{runs_per_fault} runs done)")
            continue

        engine_yaml = engines_dir / f"engine-{fault_name}.yaml"
        rbac_yaml = engines_dir / f"rbac-{fault_name}.yaml"
        ground_truth_path = fault_dir / "ground_truth.yaml"

        if not engine_yaml.exists():
            log(f"SKIP {fault_name}: no engine YAML at {engine_yaml}")
            continue

        # Load ground truth once per fault (same across runs).
        gt_raw = ground_truth_path.read_text()
        if yaml is not None:
            gt = yaml.safe_load(gt_raw) or {}
        else:
            gt = {}
        gt_inner = (gt.get("ground_truth") or {}).get(
            "fault_description_goal_remediation", {})
        goal_template = str(
            gt_inner.get("goal")
            or "Diagnose the current incident in the Kubernetes cluster. "
               "Report the root cause, affected components, and recommended remediation."
        ).strip()

        for run_idx in range(n_done, runs_per_fault):
            run_id = uuid.uuid4().hex[:12]
            run_dir = workdir / f"{fault_name}-{run_id}"
            run_dir.mkdir(parents=True, exist_ok=True)
            t0 = time.time()
            log(f"  fault: {fault_name} (run {run_idx + 1}/{runs_per_fault})")

            # Apply RBAC + ChaosEngine
            if rbac_yaml.exists():
                subprocess.run(["kubectl", "apply", "-f", str(rbac_yaml)],
                               capture_output=True)
            subprocess.run(["kubectl", "apply", "-f", str(engine_yaml)],
                           capture_output=True)

            # Wait for fault to settle in the cluster
            log(f"    waiting {fault_settle_s}s for fault to take effect...")
            time.sleep(fault_settle_s)

            # Invoke harness in online mode (snapshot_dirs="" → agent uses live K8s)
            scenario_data: dict[str, Any] = {
                "model": model,
                "prompt_file": prompt_file,
                "goal_template": goal_template,
                "snapshot_dirs": "",
            }
            harness_extras = dict(env_vars)
            harness_extras.update({
                "FAULT_NAME": fault_name,
                "RUN_ID": run_id,
                "_HARNESS_TIMEOUT_S": str(timeout_s),
            })

            # ── Two-layer probe evaluation ────────────────────────────────────
            # Layer 1: run with original (unpatched) prompts to measure raw
            # model capability.  Layer 2: retry with patched prompts only if
            # a specific failure signal is detected in the Layer 1 log.
            probe_triggered: str | None = None
            probe_layer: int | None = None

            if capability_probes:
                # Build PROBE_OVERRIDES: "src_abs:target_rel" for each file override
                override_pairs: list[str] = []
                for probe in capability_probes:
                    for ov in probe.get("layer1_overrides", []):
                        src_abs = (harness_dir / ov["source"]).resolve()
                        override_pairs.append(f"{src_abs}:{ov['target_rel']}")

                l1_extras = dict(harness_extras)
                l1_extras["PROBE_LAYER"] = "1"
                l1_extras["PROBE_OVERRIDES"] = ";".join(override_pairs)

                log(f"    probe layer 1 (unpatched prompts): {fault_name}")
                agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                                     l1_extras, run_dir)
                (run_dir / "agent-layer1.log").write_text(agent_log)

                # Check each probe's failure signal regex against the log
                for probe in capability_probes:
                    pattern = probe.get("failure_signal_regex", "")
                    if pattern and re.search(pattern, agent_log, re.IGNORECASE):
                        probe_triggered = probe["id"]
                        break

                if probe_triggered:
                    log(f"    probe '{probe_triggered}' triggered — layer 2 (patched prompts)")
                    l2_extras = dict(harness_extras)
                    l2_extras["PROBE_LAYER"] = "2"
                    agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                                         l2_extras, run_dir)
                    probe_layer = 2
                else:
                    probe_layer = 1
            else:
                agent_rc, agent_log = invoke_harness(harness_dir, scenario_data,
                                                     harness_extras, run_dir)

            (run_dir / "agent.log").write_text(agent_log)

            # Extract output tar
            out_dir = run_dir / "outputs"
            extract_tar_output(out_dir)

            # Check for agent_output.json
            agent_output_path = out_dir / "agent_output.json"
            agent_output: dict | None = None
            if agent_output_path.exists():
                try:
                    agent_output = json.loads(agent_output_path.read_text())
                except json.JSONDecodeError:
                    pass

            # Patch ChaosResult verdict before deleting the engine (best-effort).
            _patch_chaos_result(engine_yaml, "Pass" if agent_output else "Fail")

            # Revert fault
            subprocess.run(["kubectl", "delete", "-f", str(engine_yaml)],
                           capture_output=True)
            if rbac_yaml.exists():
                subprocess.run(["kubectl", "delete", "-f", str(rbac_yaml)],
                               capture_output=True)

            dt = round(time.time() - t0, 1)
            status = "success" if agent_output else "no_output"
            agent_status = "ok" if agent_rc == 0 else "agent_nonzero_exit"
            record: dict[str, Any] = {
                "fault": fault_name, "run_id": run_id, "status": status,
                "agent_status": agent_status, "duration_s": dt,
                "probe_triggered": probe_triggered,
                "probe_layer": probe_layer,
            }
            append_result(results_file, record)
            log(f"  {status.upper()} {fault_name} in {dt}s")

            # Build and write the certifier metrics document.
            if agent_output:
                scores = _evaluate_sre_output(agent_output, fault_dir)
                doc = build_sre_agent_metrics_doc(
                    scores,
                    scenario_name=fault_name,
                    run_id=run_id,
                    duration_seconds=dt,
                    agent_id=cfg["agent_id"],
                    agent_name=cfg["agent_name"],
                )
            else:
                doc = {
                    "fault_name": fault_name,
                    "run_id": run_id,
                    "agent_id": cfg["agent_id"],
                    "agent_name": cfg["agent_name"],
                    "duration_s": dt,
                    "has_output": False,
                }
            (metrics_dir / f"{run_id}_metrics.json").write_text(json.dumps(doc, indent=2))

            if status == "success":
                done_counts[fault_name] = done_counts.get(fault_name, 0) + 1

    return metrics_dir


# ---------------------------------------------------------------------------
# Trace-based pipeline (flash-agent / LitmusChaos)
# ---------------------------------------------------------------------------

def run_trace_based_pipeline(cfg: dict, harness_dir: Path, output_dir: Path,
                              env_vars: dict, resume: bool,
                              runs_override: int | None) -> Path:
    """Run the trace-based pipeline (LitmusChaos fault injection + Langfuse traces).

    Requires:
      - Running k3s cluster with LitmusChaos installed
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

    done = {r["fault"]: r for r in load_results(results_file)
            if r.get("status") == "success"}

    engine_yamls = sorted(engines_dir.glob("engine-*.yaml"))
    if runs_override:
        engine_yamls = engine_yamls[:runs_override]

    log(f"trace_based: {len(engine_yamls)} fault engines found under {engines_dir.name}")

    # Import certifier Phase 0+1 runner
    sys.path.insert(0, str(CERTIFIER_DIR))

    for engine_yaml in engine_yamls:
        fault_name = engine_yaml.stem.removeprefix("engine-")
        if fault_name in done:
            log(f"SKIP {fault_name}")
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

        run_id = uuid.uuid4().hex[:12]
        run_dir = workdir / f"{fault_name}-{run_id}"
        run_dir.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        log(f"  fault: {fault_name}")

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
        mcp_urls = tb_cfg.get("mcp_urls", "http://localhost:8186/mcp,http://localhost:31085/mcp")
        scan_query = tb_cfg.get("scan_query",
                                "Analyse Kubernetes cluster health and report all issues")
        harness_extras = dict(env_vars)
        harness_extras.update({
            "EXPERIMENT_ID": fault_name,
            "RUN_ID": run_id,
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
            phase01_result = subprocess.run(
                [str(certifier_python(cfg)),
                 str(REPO / "scripts" / "run_certification.py"),
                 "--trace-id", trace_id,
                 "--workspace", str(phase01_dir),
                 "--skip-cert"],
                capture_output=True, text=True,
            )
            if phase01_result.returncode == 0:
                # move *_metrics.json files up to metrics_dir
                for mf in phase01_dir.rglob("*_metrics.json"):
                    shutil.copy2(mf, metrics_dir / mf.name)
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
        help="Override runs_per_fault from bench.yaml (itbench_sre pipeline only). "
             "Use --runs-per-fault 1 for quick single-pass tests.",
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
        if pipeline == "ciso":
            metrics_dir = run_ciso_pipeline(cfg, harness_dir, output_dir,
                                             env_vars, args.resume)
        elif pipeline == "sre":
            metrics_dir = run_sre_pipeline(cfg, harness_dir, output_dir,
                                            env_vars, args.resume, args.runs)
        elif pipeline == "trace_based":
            metrics_dir = run_trace_based_pipeline(cfg, harness_dir, output_dir,
                                                    env_vars, args.resume, args.runs)
        elif pipeline == "itbench_sre":
            if args.runs_per_fault is not None:
                cfg.setdefault("itbench_sre", {})["runs_per_fault"] = args.runs_per_fault
            metrics_dir = run_itbench_sre_pipeline(cfg, harness_dir, output_dir,
                                                    env_vars, args.resume, args.runs)
        else:
            die(f"Unknown pipeline type: {pipeline!r}. "
                "Valid values: ciso, sre, trace_based, itbench_sre")
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
