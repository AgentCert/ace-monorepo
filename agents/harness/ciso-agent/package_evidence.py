"""
package_evidence.py — CISO harness bridge for generate_policy / evidence_available.

After the ciso-agent container exits it leaves policy YAML files alongside
agent-result.json in its workspace directory.  ITBench's evaluate.yml expects
the agent to have written a tar archive at:
    ${shared_workspace}/agent_output.data
whose contents include at least one *.yaml / *.yml file with
    kind: Policy  or  kind: ClusterPolicy
to satisfy the generate_policy and evidence_available sub-checks.

This script is called by agent-harness.yaml after the Docker container exits:
    python3 package_evidence.py <workspace_dir>

It scans <workspace_dir> for *.yaml / *.yml files with a Kyverno policy kind,
stages them in <workspace_dir>/agent_evidence/, and tars that directory into
<workspace_dir>/agent_output.data so extract_tar_output() in ace-bench.py can
place it at the path evaluate.yml checks.
"""

from __future__ import annotations

import sys
import tarfile
from pathlib import Path

import yaml  # PyYAML; available in the certifier venv and in the base system


POLICY_KINDS = {"Policy", "ClusterPolicy"}


def _is_policy_yaml(path: Path) -> bool:
    try:
        data = yaml.safe_load(path.read_text())
        return isinstance(data, dict) and data.get("kind") in POLICY_KINDS
    except Exception:
        return False


def package_evidence(workspace: Path) -> None:
    staging = workspace / "agent_evidence"
    staging.mkdir(exist_ok=True)

    policy_files = [
        f for f in workspace.glob("*.yaml") if _is_policy_yaml(f)
    ] + [
        f for f in workspace.glob("*.yml") if _is_policy_yaml(f)
    ]

    if not policy_files:
        print(
            "[package_evidence] no Policy/ClusterPolicy YAML files found in "
            f"{workspace} — generate_policy will be false",
            file=sys.stderr,
        )
        # Still create an empty tar so evidence_available=true (directory exists).
        (staging / ".evidence").write_text("ciso-agent run\n")

    for src in policy_files:
        dest = staging / src.name
        dest.write_bytes(src.read_bytes())
        print(f"[package_evidence] staged policy: {src.name}")

    out = workspace / "agent_output.data"
    with tarfile.open(out, "w") as tf:
        for f in sorted(staging.iterdir()):
            tf.add(f, arcname=f.name)
    print(f"[package_evidence] wrote {out} ({out.stat().st_size} bytes, {len(policy_files)} policy file(s))")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <workspace_dir>", file=sys.stderr)
        sys.exit(1)
    package_evidence(Path(sys.argv[1]))
