"""
Flash Agent – Configuration
============================

Centralised configuration loaded from environment variables.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _load_dotenv() -> None:
    """Load .env / .env.local if python-dotenv is available."""
    try:
        from dotenv import load_dotenv

        env_file = ".env.local" if Path(".env.local").exists() else ".env"
        load_dotenv(env_file, override=True)
    except ImportError:
        pass


@dataclass
class AgentConfig:
    """All agent configuration in one place."""

    # Agent identity
    agent_name: str

    # LLM
    openai_base_url: str
    openai_api_key: str
    model_alias: str
    azure_api_version: str
    llm_request_timeout: float
    llm_max_retries: int

    # MCP Servers (comma-separated URLs)
    mcp_urls: list[str]
    mcp_timeout: int

    # Scan query
    scan_query: str

    # Optional explicit scope override — when set, skips MCP scope discovery
    # and forces the agent to operate within this namespace. Empty = auto-discover.
    scope_override: str

    @classmethod
    def from_env(cls) -> AgentConfig:
        """Create configuration from environment variables."""
        _load_dotenv()

        # Parse MCP_URLs as comma-separated list
        mcp_urls_str = os.getenv("MCP_URLS", "")
        mcp_urls = [url.strip() for url in mcp_urls_str.split(",") if url.strip()]

        return cls(
            agent_name=os.getenv("AGENT_NAME", "flash-agent"),
            openai_base_url=os.getenv("OPENAI_BASE_URL", ""),
            openai_api_key=os.getenv("OPENAI_API_KEY", ""),
            model_alias=os.getenv("MODEL_ALIAS", ""),
            azure_api_version=os.getenv("AZURE_API_VERSION", "2025-04-01-preview"),
            # Hosted APIs (Azure/OpenAI) rarely take more than a few seconds per call, so
            # 120s + the SDK's own 2 retries is plenty of margin. A local CPU-served
            # open-weight model is a different regime entirely: benchmarked directly
            # against this host's Ollama at num_ctx=16384, a single ~3.5K-input-token /
            # ~1.1K-output-token completion took ~4.5 minutes end-to-end (prompt eval
            # ~70 tok/s, generation ~5 tok/s) -- comfortably past the old hardcoded 120s,
            # which is exactly what was crashing later ReAct iterations with "Request
            # timed out." Both knobs are overridable per-backend via env vars.
            llm_request_timeout=float(os.getenv("LLM_REQUEST_TIMEOUT", "120.0")),
            llm_max_retries=int(os.getenv("LLM_MAX_RETRIES", "2")),
            mcp_urls=mcp_urls,
            mcp_timeout=int(os.getenv("MCP_TIMEOUT", "30")),
            scan_query=os.getenv(
                "SCAN_QUERY",
                "Analyse the data from MCP tools and provide insights.",
            ),
            scope_override=os.getenv("AGENT_SCOPE_NAMESPACE", "").strip(),
        )

    def validate(self) -> list[str]:
        """Return list of validation errors. Empty list means valid."""
        errors = []
        if not self.openai_base_url:
            errors.append("OPENAI_BASE_URL is required")
        if not self.model_alias:
            errors.append("MODEL_ALIAS is required")
        if not self.mcp_urls:
            errors.append("MCP_URLS is required")
        return errors
