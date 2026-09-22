"""
Generic Agent – configuration
==============================

The ACE env contract, and nothing else. Every value the agent needs arrives as
an environment variable; the agent never reads Kubernetes, Helm, Argo or
Langfuse state directly.

Required : OPENAI_BASE_URL, MODEL_ALIAS, MCP_URLS
Optional : OPENAI_API_KEY, MCP_TIMEOUT, SCAN_QUERY, AGENT_SCOPE_NAMESPACE,
           AGENT_NAME, AZURE_API_VERSION, LLM_REQUEST_TIMEOUT, LLM_MAX_RETRIES
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

    # Task given to the agent for this run
    scan_query: str

    # Optional explicit scope override — when set, skips MCP scope discovery
    # and forces the agent to operate within this namespace. Empty = auto-discover.
    scope_override: str

    @classmethod
    def from_env(cls) -> AgentConfig:
        """Create configuration from environment variables."""
        _load_dotenv()

        mcp_urls_str = os.getenv("MCP_URLS", "")
        mcp_urls = [url.strip() for url in mcp_urls_str.split(",") if url.strip()]

        return cls(
            agent_name=os.getenv("AGENT_NAME", "generic-agent"),
            openai_base_url=os.getenv("OPENAI_BASE_URL", ""),
            openai_api_key=os.getenv("OPENAI_API_KEY", ""),
            model_alias=os.getenv("MODEL_ALIAS", ""),
            azure_api_version=os.getenv("AZURE_API_VERSION", "2025-04-01-preview"),
            # Local open-weight models served on CPU can take minutes per completion,
            # far past the hosted-API norm of a few seconds — both knobs are
            # overridable per-backend so one image works against either regime.
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
