# Base images: upstream names by default (plain `docker build` works anywhere).
# scripts/build-and-push.sh, setup.sh and prepare-images.sh pass the copy from
# IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies (scripts/lib/registry.sh).
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}

WORKDIR /sre-agent-comprehensive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies first, keyed only on pyproject.toml, so an iteration
# that only touches src/ reuses the (slow) dependency layer instead of
# re-resolving crewai + its transitive tree every build. A stub package is
# enough for `pip install -e .` to pull the deps and lay down the editable
# link; the real sources are overlaid by the COPY below and picked up at
# runtime because the install is editable.
COPY pyproject.toml .
RUN mkdir -p src/sre_comprehensive \
    && touch src/sre_comprehensive/__init__.py \
    && pip install --no-cache-dir -e .

COPY src/ src/

ENTRYPOINT ["python", "-m", "sre_comprehensive"]
