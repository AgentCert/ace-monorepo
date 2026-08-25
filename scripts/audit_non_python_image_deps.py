#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class NodeImageAuditTarget:
    dockerfile: Path
    project_root: Path
    code_roots: list[Path]
    local_base_dir: Path


@dataclass
class GoImageAuditTarget:
    dockerfile: Path
    module_dir: Path


SKIP_PARTS = {".git", ".venv", "node_modules", "__pycache__", ".pytest_cache", ".tmp", "dist", "build"}
JS_EXTS = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
NODE_BUILTINS = {
    "assert",
    "buffer",
    "child_process",
    "cluster",
    "console",
    "constants",
    "crypto",
    "dgram",
    "dns",
    "domain",
    "events",
    "fs",
    "http",
    "http2",
    "https",
    "inspector",
    "module",
    "net",
    "os",
    "path",
    "perf_hooks",
    "process",
    "punycode",
    "querystring",
    "readline",
    "repl",
    "stream",
    "string_decoder",
    "timers",
    "tls",
    "tty",
    "url",
    "util",
    "v8",
    "vm",
    "worker_threads",
    "zlib",
}


def is_skipped(path: Path) -> bool:
    return any(part in SKIP_PARTS for part in path.parts)


def parse_tsconfig_aliases(tsconfig_path: Path) -> set[str]:
    aliases: set[str] = set()
    if not tsconfig_path.exists():
        return aliases

    try:
        data = json.loads(tsconfig_path.read_text(encoding="utf-8"))
    except Exception:
        return aliases

    paths = ((data.get("compilerOptions") or {}).get("paths") or {})
    for key in paths.keys():
        aliases.add(key.rstrip("/*"))
    return aliases


def is_local_alias(pkg: str, aliases: set[str]) -> bool:
    for alias in aliases:
        if pkg == alias or pkg.startswith(alias + "/"):
            return True
    return False


def normalize_node_package(spec: str) -> str | None:
    spec = spec.strip()
    if not spec:
        return None

    if spec.startswith("node:"):
        spec = spec[5:]

    if spec.startswith(".") or spec.startswith("/"):
        return None

    if spec.startswith("@"):
        parts = spec.split("/")
        if len(parts) >= 2:
            return f"{parts[0]}/{parts[1]}"
        return spec

    return spec.split("/", 1)[0]


def extract_import_specs(source_text: str) -> set[str]:
    specs: set[str] = set()

    patterns = [
        r"(?:import|export)\s+(?:[^;]*?\s+from\s+)?['\"]([^'\"]+)['\"]",
        r"require\(\s*['\"]([^'\"]+)['\"]\s*\)",
        r"import\(\s*['\"]([^'\"]+)['\"]\s*\)",
    ]

    for pattern in patterns:
        for match in re.finditer(pattern, source_text):
            specs.add(match.group(1))

    return specs


def parse_declared_node_packages(package_json_path: Path) -> set[str]:
    data = json.loads(package_json_path.read_text(encoding="utf-8"))
    declared: set[str] = set()

    for section in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        for pkg in (data.get(section) or {}).keys():
            declared.add(pkg)

    return declared


def audit_node_target(target: NodeImageAuditTarget) -> dict:
    declared = parse_declared_node_packages(target.project_root / "package.json")
    local_aliases = parse_tsconfig_aliases(target.project_root / "tsconfig.json")
    local_top_level = {
        entry.name for entry in target.local_base_dir.iterdir() if entry.exists() and entry.name not in SKIP_PARTS
    } if target.local_base_dir.exists() else set()

    imports: set[str] = set()
    for root in target.code_roots:
        if not root.exists():
            continue
        for path in root.glob("**/*"):
            if path.suffix not in JS_EXTS or is_skipped(path):
                continue
            try:
                specs = extract_import_specs(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            for spec in specs:
                pkg = normalize_node_package(spec)
                if not pkg:
                    continue
                if pkg in NODE_BUILTINS:
                    continue
                if is_local_alias(pkg, local_aliases):
                    continue
                if pkg in local_top_level:
                    continue
                imports.add(pkg)

    missing = sorted(pkg for pkg in imports if pkg not in declared)

    return {
        "dockerfile": str(target.dockerfile),
        "project_root": str(target.project_root),
        "declared_dep_count": len(declared),
        "imports_checked": len(imports),
        "missing": missing,
    }

def audit_go_target(target: GoImageAuditTarget) -> dict:
    commands = [
        ["go", "list", "-deps", "./..."],
        ["go", "mod", "verify"],
    ]

    command_results: list[dict] = []
    ok = True
    env = os.environ.copy()
    env["GOFLAGS"] = "-mod=readonly"

    for cmd in commands:
        proc = subprocess.run(
            cmd,
            cwd=str(target.module_dir),
            text=True,
            capture_output=True,
            env=env,
        )
        output = ((proc.stdout or "") + (proc.stderr or "")).strip()
        command_results.append(
            {
                "command": " ".join(cmd),
                "exit_code": proc.returncode,
                "output": output[-5000:] if output else "",
            }
        )
        if proc.returncode != 0:
            ok = False

    return {
        "dockerfile": str(target.dockerfile),
        "module_dir": str(target.module_dir),
        "ok": ok,
        "checks": command_results,
    }


def build_node_targets(repo_root: Path) -> list[NodeImageAuditTarget]:
    web_root = repo_root / "AgentCert/chaoscenter/web"
    return [
        NodeImageAuditTarget(
            dockerfile=web_root / "Dockerfile",
            project_root=web_root,
            code_roots=[web_root / "src", web_root / "config"],
            local_base_dir=web_root / "src",
        )
    ]


def build_go_targets(repo_root: Path) -> list[GoImageAuditTarget]:
    return [
        GoImageAuditTarget(
            dockerfile=repo_root / "AgentCert/chaoscenter/authentication/Dockerfile",
            module_dir=repo_root / "AgentCert/chaoscenter/authentication",
        ),
        GoImageAuditTarget(
            dockerfile=repo_root / "AgentCert/chaoscenter/graphql/server/Dockerfile",
            module_dir=repo_root / "AgentCert/chaoscenter/graphql/server",
        ),
        GoImageAuditTarget(
            dockerfile=repo_root / "AgentCert/chaoscenter/event-tracker/Dockerfile",
            module_dir=repo_root / "AgentCert/chaoscenter/event-tracker",
        ),
        GoImageAuditTarget(
            dockerfile=repo_root / "AgentCert/chaoscenter/subscriber/Dockerfile",
            module_dir=repo_root / "AgentCert/chaoscenter/subscriber",
        ),
        GoImageAuditTarget(
            dockerfile=repo_root / "AgentCert/chaoscenter/upgrade-agents/control-plane/Dockerfile",
            module_dir=repo_root / "AgentCert/chaoscenter/upgrade-agents/control-plane",
        ),
        GoImageAuditTarget(
            dockerfile=repo_root / "app-charts/install-app/Dockerfile",
            module_dir=repo_root / "app-charts/install-app",
        ),
    ]


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: audit_non_python_image_deps.py <repo-root> <report-path>", file=sys.stderr)
        return 2

    repo_root = Path(sys.argv[1]).resolve()
    report_path = Path(sys.argv[2]).resolve()

    if not shutil_which("go"):
        report = {
            "error": "go command not found",
            "node": [],
            "go": [],
        }
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print("node_images_scanned=0")
        print("node_missing_dependency_items=0")
        print("go_images_scanned=0")
        print("go_failed_targets=1")
        print(f"report_path={report_path}")
        return 23

    node_results: list[dict] = []
    go_results: list[dict] = []

    node_missing_total = 0
    go_failed_targets = 0

    for target in build_node_targets(repo_root):
        if not target.dockerfile.exists() or not (target.project_root / "package.json").exists():
            continue
        result = audit_node_target(target)
        node_missing_total += len(result["missing"])
        node_results.append(result)

    for target in build_go_targets(repo_root):
        if not target.dockerfile.exists() or not (target.module_dir / "go.mod").exists():
            continue
        result = audit_go_target(target)
        if not result["ok"]:
            go_failed_targets += 1
        go_results.append(result)

    report = {
        "node": node_results,
        "go": go_results,
    }

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"node_images_scanned={len(node_results)}")
    print(f"node_missing_dependency_items={node_missing_total}")
    print(f"go_images_scanned={len(go_results)}")
    print(f"go_failed_targets={go_failed_targets}")
    print(f"report_path={report_path}")

    return 23 if node_missing_total or go_failed_targets else 0


def shutil_which(cmd: str) -> str | None:
    from shutil import which

    return which(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
