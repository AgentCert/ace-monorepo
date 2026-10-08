# Build stage
# Base images: upstream names by default (plain `docker build` works anywhere).
# scripts/build-and-push.sh, setup.sh and prepare-images.sh pass the copy from
# IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies (scripts/lib/registry.sh).
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE} AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Final stage
FROM ${PYTHON_IMAGE}

# Create non-root user
RUN groupadd -g 1000 agent && useradd -u 1000 -g agent -m agent

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy application
COPY main.py config.py flash_agent.py ./
COPY mcp/ ./mcp/
COPY llm/ ./llm/

# Set ownership
RUN chown -R agent:agent /app

USER agent

# Continuous by default: the image runs as a Deployment beside the app under
# test and must keep scanning until the workflow's cleanup uninstalls it
# (SIGTERM). Set SCAN_INTERVAL=0 for a one-shot run (the ITBench harness does).
ENV SCAN_INTERVAL=120
ENV LOG_LEVEL=INFO

ENTRYPOINT ["python", "-u", "main.py"]
