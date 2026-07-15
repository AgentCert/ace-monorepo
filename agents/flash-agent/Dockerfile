# Build stage
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Final stage
FROM python:3.12-slim

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

# CronJob mode by default (run once). Override SCAN_INTERVAL>0 for continuous.
ENV SCAN_INTERVAL=120
ENV LOG_LEVEL=INFO

ENTRYPOINT ["python", "-u", "main.py"]
