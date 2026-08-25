#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass
class ImageAuditTarget:
    dockerfile: Path
    code_roots: list[Path]


SKIP_PARTS = {".git", ".venv", "node_modules", "__pycache__", ".pytest_cache", ".tmp"}
SKIP_DIR_NAMES = {"tests", "test", "docs", "notebooks"}

IMPORT_TO_PACKAGE = {
    "yaml": ["pyyaml"],
    "dotenv": ["python-dotenv"],
    "jwt": ["pyjwt"],
    "bs4": ["beautifulsoup4"],
    "PIL": ["pillow"],
    "dateutil": ["python-dateutil"],
    "litellm": ["litellm"],
    "pydantic": ["pydantic"],
    "plotly": ["plotly"],
    "pytest": ["pytest"],
    "fastapi": ["fastapi"],
    "uvicorn": ["uvicorn"],
    "pymongo": ["pymongo"],
    "motor": ["motor"],
    "langgraph": ["langgraph"],
    "langfuse": ["langfuse"],
    "langchain": ["langchain", "langchain-core"],
    "langchain_core": ["langchain-core"],
    "langchain_openai": ["langchain-openai"],
    "langchain_anthropic": ["langchain-anthropic"],
    "scipy": ["scipy"],
    "statsmodels": ["statsmodels"],
    "altair": ["altair"],
    "vl_convert": ["vl-convert-python"],
    "pandas": ["pandas"],
    "agent_framework": ["agent-framework-core"],
    "crewai": ["crewai"],
    "mcp": ["mcp"],
    "httpx": ["httpx"],
    "requests": ["requests"],
}

IGNORE_IMPORT_MODULES = {
    "api",
}


def normalize_pkg(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_requirement_name(spec: str) -> str | None:
    spec = spec.strip()
    if not spec or spec.startswith("#"):
        return None
    if spec.startswith(("-r ", "--requirement ", "-c ", "--constraint ")):
        return None
    if spec.startswith(("-e ", "--editable ")):
        parts = spec.split(maxsplit=1)
        if len(parts) != 2:
            return None
        spec = parts[1].strip()

    m = re.match(r"^([A-Za-z0-9_.-]+)", spec)
    if not m:
        return None
    return normalize_pkg(m.group(1))


def iter_requirements(path: Path) -> Iterable[str]:
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = re.split(r"\s+#", raw.strip(), 1)[0].strip()
        name = parse_requirement_name(line)
        if name:
            yield name


def iter_pyproject_dependencies(path: Path) -> Iterable[str]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    project = data.get("project", {})
    deps: list[str] = []
    deps.extend(project.get("dependencies", []) or [])
    for extra in (project.get("optional-dependencies", {}) or {}).values():
        deps.extend(extra or [])
    for dep in deps:
        name = parse_requirement_name(dep)
        if name:
            yield name


def is_skipped(path: Path) -> bool:
    return any(part in SKIP_PARTS for part in path.parts)


def parse_declared_deps(dockerfile: Path) -> set[str]:
    text = dockerfile.read_text(encoding="utf-8")
    declared: set[str] = set()

    for match in re.finditer(r"pip\s+install[^\n]*?-r\s+([^\s\\]+)", text):
        req_rel = match.group(1).strip().strip("\"'")
        req_file = (dockerfile.parent / req_rel).resolve()
        if req_file.exists():
            declared.update(iter_requirements(req_file))

    if re.search(r"pip\s+install[^\n]*(?:-e\s+\.|\s\.)", text):
        pyproject = dockerfile.parent / "pyproject.toml"
        if pyproject.exists():
            declared.update(iter_pyproject_dependencies(pyproject))

    return declared


def collect_imports(code_roots: list[Path]) -> tuple[set[str], set[str]]:
    imports: set[str] = set()
    local_mods: set[str] = set()
    stdlib = set(getattr(sys, "stdlib_module_names", set()))

    for root in code_roots:
        if not root.exists():
            continue
        for py_file in root.glob("**/*.py"):
            if is_skipped(py_file):
                continue
            if any(part in SKIP_DIR_NAMES for part in py_file.parts):
                continue

            local_mods.add(py_file.stem)
            try:
                tree = ast.parse(py_file.read_text(encoding="utf-8"), filename=str(py_file))
            except Exception:
                continue

            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        imports.add(alias.name.split(".", 1)[0])
                elif isinstance(node, ast.ImportFrom):
                    if node.module:
                        imports.add(node.module.split(".", 1)[0])

        for init_file in root.glob("**/__init__.py"):
            if is_skipped(init_file):
                continue
            if any(part in SKIP_DIR_NAMES for part in init_file.parts):
                continue
            local_mods.add(init_file.parent.name)

    external = {
        name
        for name in imports
        if name
        and name not in stdlib
        and name not in local_mods
        and name != "__future__"
        and name not in IGNORE_IMPORT_MODULES
    }

    return external, local_mods


def import_satisfied(mod: str, declared: set[str]) -> tuple[bool, list[str]]:
    if mod == "typing_extensions":
        return True, ["typing-extensions"]
    if mod == "azure":
        return (any(dep.startswith("azure-") for dep in declared), ["azure-*"])

    candidates = IMPORT_TO_PACKAGE.get(mod, [normalize_pkg(mod)])
    return any(candidate in declared for candidate in candidates), candidates


def build_targets(repo_root: Path) -> list[ImageAuditTarget]:
    return [
        ImageAuditTarget(repo_root / "agents/sre-agent-crewai/Dockerfile", [repo_root / "agents/sre-agent-crewai/src"]),
        ImageAuditTarget(repo_root / "agents/sre-agent-comprehensive/Dockerfile", [repo_root / "agents/sre-agent-comprehensive/src"]),
        ImageAuditTarget(repo_root / "agents/flash-agent/Dockerfile", [repo_root / "agents/flash-agent"]),
        ImageAuditTarget(repo_root / "agents/ciso-agent/Dockerfile", [repo_root / "agents/ciso-agent/src"]),
        ImageAuditTarget(repo_root / "certifier/Dockerfile", [
            repo_root / "certifier/main",
            repo_root / "certifier/aggregator",
            repo_root / "certifier/fault_analyzer",
            repo_root / "certifier/metrics_extractor",
            repo_root / "certifier/cert_builder",
            repo_root / "certifier/cert_reporter",
            repo_root / "certifier/hypothesis_framework",
            repo_root / "certifier/utils",
        ]),
    ]


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: audit_python_image_deps.py <repo-root> <report-path>", file=sys.stderr)
        return 2

    repo_root = Path(sys.argv[1]).resolve()
    report_path = Path(sys.argv[2]).resolve()

    report: list[dict] = []
    total_missing = 0

    for target in build_targets(repo_root):
        if not target.dockerfile.exists():
            continue

        declared = parse_declared_deps(target.dockerfile)
        imports, _ = collect_imports(target.code_roots)

        missing: list[dict] = []
        for mod in sorted(imports):
            ok, expected = import_satisfied(mod, declared)
            if not ok:
                missing.append({
                    "import_module": mod,
                    "expected_packages": expected,
                })

        total_missing += len(missing)
        report.append(
            {
                "dockerfile": str(target.dockerfile.relative_to(repo_root)),
                "declared_dep_count": len(declared),
                "import_count": len(imports),
                "missing": missing,
            }
        )

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"images_scanned={len(report)}")
    print(f"missing_dependency_items={total_missing}")
    print(f"report_path={report_path}")

    return 13 if total_missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
