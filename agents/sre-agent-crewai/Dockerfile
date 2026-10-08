# Base images: upstream names by default (plain `docker build` works anywhere).
# scripts/build-and-push.sh, setup.sh and prepare-images.sh pass the copy from
# IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies (scripts/lib/registry.sh).
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}

WORKDIR /sre-agent-crewai
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml .
COPY src/ src/

RUN pip install --no-cache-dir -e .

ENTRYPOINT ["python", "-m", "sre_crewai"]
