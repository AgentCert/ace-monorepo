FROM python:3.12-slim

WORKDIR /sre-agent
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock README.md ./
COPY zero/ zero/
COPY sre_tools/ sre_tools/
COPY ITBench-Evaluations/ ITBench-Evaluations/

# uv.lock, not plain pip: the dependency set has a real conflict pip cannot solve
# (drain3 pins cachetools==4.2.1 while litellm[proxy] needs >=5.0.0). The
# committed lock is the only known-good resolution.
RUN uv sync --frozen --no-dev

ENV PATH="/sre-agent/.venv/bin:${PATH}"

# `zero` is the console script declared in pyproject.toml ([project.scripts]).
ENTRYPOINT ["zero"]
