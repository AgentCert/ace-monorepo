# Sandbox image for agents/sre-agent/ (ITBench SRE Agent).
# Build context must be agents/sre-agent/ — setup.sh does this automatically.
#
# Prerequisites before docker build:
#   bash agents/harness/sre-agent/setup.sh   # populates nested submodules first

FROM python:3.12-slim

# System packages: git (workspace init by zero), bash, jq, curl (Node setup)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git bash jq curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS (required by Codex CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Codex CLI — exact version required (later versions have OpenRouter issues)
RUN npm install -g @openai/codex@0.94.0

# uv (Python package manager used by the agent)
RUN pip install --no-cache-dir uv

WORKDIR /sre-agent

# Copy agent source (build context = agents/sre-agent/)
COPY . /sre-agent/

# Install Python deps from the locked uv.lock
RUN uv sync

ENTRYPOINT ["uv", "run", "python", "-m", "zero"]
