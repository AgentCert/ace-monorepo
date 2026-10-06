#!/usr/bin/env python3
"""Render check for the settings agent and app charts offer to the builder.

A chart lists the values a user may change in a top-level `configurations`
block of its values.yaml (AgentCert pkg/chartconfig validates the block
itself). Declaring a value is not the same as using it: some agent charts copy
only the env vars their templates name into the container, so a declared
setting can be accepted, saved and then silently dropped at install time.

For every declared setting this script renders the chart twice with
`helm template` -- once as shipped, once with the setting changed through a
values file, exactly as install-agent / install-app apply it -- and fails if
the change does not show up in the rendered manifests.

Needs helm on PATH. A chart with subchart dependencies is copied to a temp dir
and `helm dependency build` runs there (network access), so the checkout is
never modified.

Exit status 0 = every setting reaches the manifests, 1 = at least one does not.

Usage:
    scripts/validate-chart-configurations.py [--repo-root DIR] [CHART_DIR ...]
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

HUBS = ("agent-charts/charts", "app-charts/charts")


def lookup(doc: dict, key: str):
    node = doc
    for segment in key.split("."):
        node = node[segment]
    return node


def nested(key: str, value) -> dict:
    out: dict = {}
    node = out
    segments = key.split(".")
    for segment in segments[:-1]:
        node = node.setdefault(segment, {})
    node[segments[-1]] = value
    return out


def changed_value(field: dict, default, index: int):
    """Change the setting within its declared range/options when possible."""
    if isinstance(default, bool):
        return not default
    if field.get("type") == "boolean":
        return "false" if default == "true" else "true"
    if field.get("type") in ("integer", "number"):
        number = float(default)
        for candidate in (number + 1, number - 1, field.get("min"), field.get("max")):
            if candidate is None or candidate == number:
                continue
            if candidate < field.get("min", float("-inf")) or candidate > field.get("max", float("inf")):
                continue
            if field["type"] == "integer":
                candidate = int(candidate)
            return str(candidate) if isinstance(default, str) else candidate
        return default
    if field.get("type") == "select":
        return next((option for option in field["options"] if option != default), default)
    if field.get("pattern"):
        for candidate in ("768Mi", "1Gi", "750m", "2", f"ace-probe-{index}"):
            if candidate != default and re.search(field["pattern"], candidate):
                return candidate
    return f"ace-probe-{index}"


def configured_environment(manifests: str, key: str) -> list[str]:
    """Read the value containers receive, including ConfigMap env references.

    A changed ConfigMap alone does not prove the agent receives the setting.
    Explicit env entries override envFrom, just as they do in Kubernetes.
    """
    docs = [doc for doc in yaml.safe_load_all(manifests) if isinstance(doc, dict)]
    config_maps = {doc["metadata"]["name"]: doc.get("data", {}) for doc in docs if doc.get("kind") == "ConfigMap"}
    received = []
    for doc in docs:
        spec = doc.get("spec", {})
        if doc.get("kind") == "CronJob":
            spec = spec.get("jobTemplate", {}).get("spec", {})
        pod = spec if doc.get("kind") == "Pod" else spec.get("template", {}).get("spec", {})
        for container in pod.get("containers", []):
            env = {}
            for source in container.get("envFrom", []):
                ref = source.get("configMapRef", {})
                env.update({source.get("prefix", "") + name: value for name, value in config_maps.get(ref.get("name"), {}).items()})
            for entry in container.get("env", []):
                ref = entry.get("valueFrom", {}).get("configMapKeyRef", {})
                env[entry["name"]] = entry.get("value", config_maps.get(ref.get("name"), {}).get(ref.get("key")))
            if env.get(key) is not None:
                received.append(str(env[key]))
    return received


def render(chart: Path, values_file: Path | None = None) -> str:
    cmd = ["helm", "template", "probe", str(chart), "--namespace", "probe"]
    if values_file:
        cmd += ["-f", str(values_file)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result.stdout


def prepare(chart: Path, workdir: Path) -> Path:
    """Copy the chart and build its dependencies when it declares any."""
    chart_yaml = yaml.safe_load((chart / "Chart.yaml").read_text())
    if not chart_yaml.get("dependencies"):
        return chart
    copy = workdir / chart.name
    shutil.copytree(chart, copy)
    result = subprocess.run(["helm", "dependency", "build", str(copy)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("helm dependency build failed: " + result.stderr.strip())
    return copy


def check_chart(chart: Path, workdir: Path) -> list[str]:
    values = yaml.safe_load((chart / "values.yaml").read_text()) or {}
    fields = values.get("configurations") or []
    if not fields:
        return []

    rendered_chart = prepare(chart, workdir)
    baseline = render(rendered_chart)
    problems = []
    for index, field in enumerate(fields):
        key = field["key"]
        probe = changed_value(field, lookup(values, key), index)
        if probe == lookup(values, key):
            continue  # A fixed range or one-option select has no alternative.
        values_file = workdir / f"{chart.name}-{index}.yaml"
        values_file.write_text(yaml.safe_dump(nested(key, probe)))
        try:
            output = render(rendered_chart, values_file)
        except RuntimeError as err:
            problems.append(f"{key}: chart fails to render with a changed value: {err}")
            continue
        if key.startswith("agent.config."):
            expected = str(probe).lower() if isinstance(probe, bool) else str(probe)
            reached = expected in configured_environment(output, key.removeprefix("agent.config."))
        else:
            reached = output != baseline if isinstance(probe, bool) else str(probe) in output
        if not reached:
            problems.append(f"{key}: changing it does not change the rendered manifests (the chart never uses it)")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("charts", nargs="*", type=Path, help="chart directories (default: every chart in both hubs)")
    args = parser.parse_args()

    if shutil.which("helm") is None:
        sys.exit("helm is required on PATH")

    charts = args.charts or sorted(
        path for hub in HUBS for path in (args.repo_root / hub).iterdir() if (path / "Chart.yaml").is_file()
    )
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        for chart in charts:
            try:
                problems = check_chart(chart, Path(tmp))
            except (RuntimeError, KeyError, TypeError, ValueError, OSError, yaml.YAMLError) as err:
                problems = [f"cannot check: {err}"]
            for problem in problems:
                print(f"ERROR {chart.name}: {problem}")
            failed = failed or bool(problems)
            if not problems:
                print(f"ok    {chart.name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
