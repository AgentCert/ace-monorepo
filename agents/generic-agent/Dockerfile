# Build stage
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Final stage
FROM python:3.12-slim

# Cluster policy requires non-root
RUN groupadd -g 1000 agent && useradd -u 1000 -g agent -m agent

WORKDIR /app

COPY --from=builder /install /usr/local

COPY main.py config.py agent_core.py ./
COPY mcp/ ./mcp/
COPY llm/ ./llm/

RUN chown -R agent:agent /app

USER agent

# Single-shot by default; ACE overrides SCAN_INTERVAL per experiment.
ENV SCAN_INTERVAL=0
ENV LOG_LEVEL=INFO

ENTRYPOINT ["python", "-u", "main.py"]
