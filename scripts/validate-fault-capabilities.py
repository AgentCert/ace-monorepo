#!/usr/bin/env python3
"""Conformance check for the fault catalog, charts, and dispatcher.

Runs with no cluster and no Go toolchain, so it belongs in CI. It exists because
every fault bug this repo has hit was detectable from static configuration:

  * a fault selectable in the UI with no implementation behind it
  * an implementation no chart exposes, so nobody notices it is broken
  * a tunable whose "unset" sentinel differs between the chart and the Go code,
    so the intended default branch is dead and an empty string reaches the
    command line (`stress-ng --hdd-bytes %`)
  * a fault whose target requirements are satisfied by almost no real workload

Exit status 0 = clean, 1 = at least one ERROR. Warnings never fail the build.

Usage:
    scripts/validate-fault-capabilities.py [--repo-root DIR] [--quiet]
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")


LIFECYCLE_STEPS = {
    "install-application",
    "install-agent",
    "uninstall-application",
    "uninstall-agent",
}

# Names that are directories under faults/<category>/ but are not faults.
NON_FAULT_DIRS = {"icons"}


@dataclass
class Findings:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def load_catalog(repo: Path, f: Findings) -> dict:
    path = repo / "chaos-charts" / "faults" / "fault-capabilities.yaml"
    if not path.is_file():
        f.error(f"catalog not found: {path.relative_to(repo)}")
        return {}
    doc = yaml.safe_load(path.read_text()) or {}
    spec = doc.get("spec") or {}
    if not spec.get("faults"):
        f.error(f"{path.relative_to(repo)} declares no spec.faults")
    return spec


def chart_fault_dirs(repo: Path, category: str) -> set[str]:
    base = repo / "chaos-charts" / "faults" / category
    if not base.is_dir():
        return set()
    return {
        d.name
        for d in base.iterdir()
        if d.is_dir() and d.name not in NON_FAULT_DIRS and d.name not in LIFECYCLE_STEPS
    }


def hub_catalog_faults(repo: Path, category: str, f: Findings) -> set[str]:
    """Fault names in the category CSV — the set the UI's picker actually shows."""
    path = (
        repo / "chaos-charts" / "faults" / category / f"{category}.chartserviceversion.yaml"
    )
    if not path.is_file():
        f.warn(f"no hub catalog for category {category!r} ({path.name} missing)")
        return set()
    doc = yaml.safe_load(path.read_text()) or {}
    faults = ((doc.get("spec") or {}).get("faults")) or []
    names = set()
    for entry in faults:
        if isinstance(entry, dict) and entry.get("name"):
            names.add(entry["name"])
        elif isinstance(entry, str):
            names.add(entry)
    return {n for n in names if n not in LIFECYCLE_STEPS}


def dispatcher_cases(repo: Path, f: Findings) -> set[str]:
    """Fault names the itbench dispatcher can actually execute."""
    path = repo / "litmus-go" / "bin" / "itbench-experiment" / "main.go"
    if not path.is_file():
        f.warn(f"itbench dispatcher not found: {path}")
        return set()
    return set(re.findall(r'case\s+"([a-z0-9][a-z0-9-]*)"', path.read_text()))


def chart_env_defaults(repo: Path, category: str, fault: str) -> dict[str, str]:
    """env name -> value from a fault's ChaosExperiment CR."""
    path = repo / "chaos-charts" / "faults" / category / fault / "fault.yaml"
    if not path.is_file():
        return {}
    try:
        doc = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError:
        return {}
    env = (((doc.get("spec") or {}).get("definition")) or {}).get("env") or []
    out = {}
    for item in env:
        if isinstance(item, dict) and "name" in item:
            out[item["name"]] = "" if item.get("value") is None else str(item["value"])
    return out


def check_inventory(repo: Path, spec: dict, f: Findings) -> None:
    catalog = spec.get("faults") or {}

    for category in ("kubernetes", "itbench"):
        dirs = chart_fault_dirs(repo, category)
        hub = hub_catalog_faults(repo, category, f)
        cataloged = {n for n, v in catalog.items() if (v or {}).get("category") == category}

        # Selectable in the UI but with no chart directory behind it: the run
        # fails at fault-install time with a missing ChaosExperiment.
        for name in sorted(hub - dirs):
            f.error(f"[{category}] {name}: in the hub catalog but has no chart directory")

        # A chart nobody can reach from the UI. This is how pod-fio-stress's
        # 100%-fatal SEQUENCE bug stayed invisible.
        for name in sorted(dirs - hub):
            f.warn(f"[{category}] {name}: chart exists but is absent from the hub catalog (unreachable in the UI)")

        for name in sorted(dirs - cataloged):
            f.error(f"[{category}] {name}: has a chart but no entry in fault-capabilities.yaml")

        for name in sorted(cataloged - dirs):
            f.error(f"[{category}] {name}: in fault-capabilities.yaml but has no chart directory")

    # The itbench dispatcher must implement exactly what itbench exposes.
    cases = dispatcher_cases(repo, f)
    if cases:
        itb_hub = hub_catalog_faults(repo, "itbench", f)
        for name in sorted(itb_hub - cases):
            f.error(f"[itbench] {name}: selectable in the UI but the dispatcher has no case for it — will fail at runtime")
        for name in sorted(cases - itb_hub):
            f.warn(f"[itbench] {name}: dispatcher implements it but no hub entry exposes it")


def load_application_registry(repo: Path, f: Findings) -> dict[str, dict]:
    """Applications are onboarded in app-charts, not in the fault catalog.

    Reading them from there is what makes onboarding an application a single
    chart edit: every generic fault widens to it automatically. The cost is that
    a fault pinning `requiredApp` now references another chart repo, which is
    exactly the cross-reference this function exists to check.
    """
    base = repo / "app-charts" / "charts"
    if not base.is_dir():
        f.warn(f"app charts directory not found: {base.relative_to(repo)}")
        return {}

    registry: dict[str, dict] = {}
    for path in sorted(base.glob("*.chartserviceversion.yaml")):
        try:
            doc = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError as exc:
            f.error(f"{path.relative_to(repo)}: not valid YAML ({exc})")
            continue
        for app in ((doc.get("spec") or {}).get("applications")) or []:
            if not isinstance(app, dict) or not app.get("name"):
                continue
            registry[app["name"]] = app

    if not registry:
        f.error("no applications found in app-charts — every fault would derive an empty compatible-app set")
    return registry


def check_applications(repo: Path, spec: dict, f: Findings) -> None:
    """Every app-specific fault must pin an application that actually exists.

    A `requiredApp` matching no registered application silently derives an EMPTY
    compatible-app set, which makes the fault unselectable in the builder for
    every application — a fault that quietly disappears from the UI rather than
    failing loudly.
    """
    apps = load_application_registry(repo, f)
    if not apps:
        return

    seen_folders: dict[str, str] = {}
    for name, app in apps.items():
        for folder in [name, *(app.get("aliases") or [])]:
            if folder in seen_folders and seen_folders[folder] != name:
                f.error(
                    f"application {name!r}: folder/alias {folder!r} is already claimed by "
                    f"{seen_folders[folder]!r} — an install-application step carrying "
                    f"it would resolve ambiguously"
                )
            seen_folders[folder] = name
        if not app.get("namespace"):
            f.error(f"application {name!r}: missing required field 'namespace'")
        if not app.get("labelKey"):
            f.warn(
                f"application {name!r}: no labelKey, falling back to "
                f"app.kubernetes.io/name for pre-deployment applabel synthesis"
            )

    for name, entry in (spec.get("faults") or {}).items():
        entry = entry or {}
        required_app = (entry.get("targetRequirements") or {}).get("requiredApp")
        classification = entry.get("classification")

        if classification == "application-specific":
            if not required_app:
                f.error(
                    f"{name}: classification='application-specific' but "
                    f"targetRequirements.requiredApp is unset, so its compatible-app "
                    f"set derives empty and the fault is unselectable"
                )
            elif required_app not in apps:
                f.error(
                    f"{name}: targetRequirements.requiredApp={required_app!r} is not a "
                    f"registered application {sorted(apps)} "
                    f"(app-charts/charts/*.chartserviceversion.yaml)"
                )
        elif required_app:
            f.error(
                f"{name}: classification={classification!r} but it pins "
                f"targetRequirements.requiredApp={required_app!r} — mark it "
                f"'application-specific' or drop the pin"
            )


def check_agent_compatibility(repo: Path, f: Findings) -> None:
    """An agent may restrict itself to applications, but only to real ones."""
    base = repo / "agent-charts" / "charts"
    if not base.is_dir():
        f.warn(f"agent charts directory not found: {base.relative_to(repo)}")
        return

    apps = load_application_registry(repo, f)
    if not apps:
        return

    for path in sorted(base.glob("*.chartserviceversion.yaml")):
        try:
            doc = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError as exc:
            f.error(f"{path.relative_to(repo)}: not valid YAML ({exc})")
            continue
        for agent in ((doc.get("spec") or {}).get("agents")) or []:
            if not isinstance(agent, dict):
                continue
            declared = agent.get("compatibleApplications")
            if declared is None:
                continue  # unrestricted, and stays that way as apps are added
            for app in declared:
                if app not in apps:
                    f.error(
                        f"agent {agent.get('name')!r}: compatibleApplications lists "
                        f"{app!r}, which is not a registered application {sorted(apps)}"
                    )


def check_vocabularies(spec: dict, f: Findings) -> None:
    vocab = spec.get("vocabularies") or {}
    required = ("mechanism", "scope", "concurrency", "category", "classification")
    for key in required:
        if not vocab.get(key):
            f.error(f"vocabularies.{key} is missing — values cannot be validated")

    for name, entry in (spec.get("faults") or {}).items():
        entry = entry or {}
        for key in required:
            allowed = vocab.get(key) or []
            value = entry.get(key)
            if value is None:
                f.error(f"{name}: missing required field {key!r}")
            elif allowed and value not in allowed:
                f.error(f"{name}: {key}={value!r} is not in the declared vocabulary {allowed}")


def check_mechanism_consistency(spec: dict, f: Findings) -> None:
    """A fault's target requirements must follow from its mechanism.

    This is the check that would have caught pod-io-stress before it ever ran:
    the mechanism that enters the target's mount namespace inherently requires a
    writable filesystem, and a mechanism with no container access inherently
    requires nothing.
    """
    NO_TARGET_ACCESS = {"k8s-api", "helper-cgroup", "helper-netns", "helper-node", "node-ssh"}
    CONTAINER_FS_ACCESS = {"helper-mount-ns", "host-proc-write"}

    for name, entry in (spec.get("faults") or {}).items():
        entry = entry or {}
        mech = entry.get("mechanism")
        reqs = entry.get("targetRequirements") or {}

        if mech in CONTAINER_FS_ACCESS and not reqs.get("writableFilesystem"):
            f.error(
                f"{name}: mechanism {mech!r} writes inside the target, so "
                f"targetRequirements.writableFilesystem must be true"
            )

        if mech == "exec-in-target" and not reqs.get("shell"):
            f.error(
                f"{name}: mechanism 'exec-in-target' runs /bin/sh in the target, so "
                f"targetRequirements.shell must be true"
            )

        if mech in NO_TARGET_ACCESS:
            for impossible in ("writableFilesystem", "shell", "binaryInTarget"):
                if reqs.get(impossible):
                    f.error(
                        f"{name}: mechanism {mech!r} has no access to the target "
                        f"container, so it cannot require {impossible!r}"
                    )

        # A node- or cluster-scoped fault can never be parallel-safe.
        scope, conc = entry.get("scope"), entry.get("concurrency")
        if scope in ("node", "cluster") and conc == "parallel-safe":
            f.error(f"{name}: scope={scope!r} cannot be concurrency='parallel-safe'")

        # Anything that can take out a whole node must say so, because on a
        # single-node cluster that means every unrelated workload too.
        if scope == "cluster" and not entry.get("singleNodeDanger"):
            f.warn(f"{name}: scope='cluster' but singleNodeDanger is not set")


def check_env_sentinels(repo: Path, spec: dict, f: Findings) -> None:
    """The chart's default and the code's 'unset' sentinel must agree.

    The whole `""` vs `"0"` bug class lives here: the chart ships an empty string
    to mean "deselect this tunable" while the Go branch logic compares against
    "0", so the default branch is unreachable and "" flows into an argument.
    """
    for name, entry in (spec.get("faults") or {}).items():
        entry = entry or {}
        category = entry.get("category")
        if category not in ("kubernetes", "itbench"):
            continue
        declared = entry.get("requiredEnv") or []
        if not declared:
            continue

        chart_env = chart_env_defaults(repo, category, name)
        if not chart_env:
            continue

        for item in declared:
            if not isinstance(item, dict) or "name" not in item:
                continue
            key = item["name"]
            sentinel = item.get("unsetSentinel")
            if key not in chart_env:
                if item.get("required"):
                    f.error(f"{name}: env {key} is declared required but the chart does not define it")
                else:
                    f.warn(f"{name}: env {key} is declared in the catalog but absent from fault.yaml")
                continue

            chart_value = chart_env[key].strip()
            if sentinel is not None and chart_value == "" and sentinel != "":
                f.error(
                    f"{name}: fault.yaml ships {key}=\"\" but the code treats "
                    f"{sentinel!r} as unset — the default branch is unreachable and "
                    f"the empty value reaches the command line"
                )

            if item.get("required") and chart_value == "":
                f.warn(f"{name}: env {key} is required but the chart ships it empty")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--quiet", action="store_true", help="print only the summary and errors")
    args = ap.parse_args()

    repo = args.repo_root.resolve()
    f = Findings()

    spec = load_catalog(repo, f)
    if spec:
        check_vocabularies(spec, f)
        check_applications(repo, spec, f)
        check_agent_compatibility(repo, f)
        check_inventory(repo, spec, f)
        check_mechanism_consistency(spec, f)
        check_env_sentinels(repo, spec, f)

    total = len(spec.get("faults") or {}) if spec else 0

    if f.warnings and not args.quiet:
        print(f"\n{len(f.warnings)} warning(s):")
        for w in f.warnings:
            print(f"  ⚠  {w}")

    if f.errors:
        print(f"\n{len(f.errors)} error(s):")
        for e in f.errors:
            print(f"  ✗  {e}")
        print(f"\nFAIL — {total} fault(s) checked, {len(f.errors)} error(s), {len(f.warnings)} warning(s)")
        return 1

    print(f"\nOK — {total} fault(s) checked, 0 errors, {len(f.warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
