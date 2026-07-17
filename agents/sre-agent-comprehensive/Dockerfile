FROM python:3.12-slim

WORKDIR /sre-agent-comprehensive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml .
COPY src/ src/

RUN pip install --no-cache-dir -e .

ENTRYPOINT ["python", "-m", "sre_comprehensive"]
