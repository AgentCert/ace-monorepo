---
title: "Testing & Coverage"
parent: "Reference"
nav_order: 6
---

# Testing & Code Coverage

This guide covers how to run the test suites across the monorepo, how
coverage is generated per language, and how to stand up SonarQube to view a
consolidated quality & coverage report.

The repo is multi-language — **Python** (certifier), **Go** (chaoscenter
services, litmus-go), and **TypeScript/React** (chaoscenter web) — so each
stack has its own test runner and coverage format. SonarQube ties them
together into one dashboard.

---

## Coverage at a glance

Latest consolidated line coverage (SonarQube, project `ace-monorepo`):

| Component | Language | Coverage |
|---|---|--:|
| **certifier** | Python | **54.7%** |
| chaoscenter / subscriber | Go | 37.1% |
| chaoscenter / authentication | Go | 29.2% |
| chaoscenter / graphql-server | Go | 15.4% |
| chaoscenter / web | TS/React | 9.6% |
| litmus-go | Go | 2.6% |
| **Overall** | — | **18.2%** |

> Coverage measures lines executed by tests that **pass**. Several areas are
> intentionally low because they require integration/e2e harnesses rather than
> unit tests — see [What is *not* unit-tested](#what-is-not-unit-tested).

---

## Running the tests

### Python — certifier (`pytest`)

```bash
cd certifier
# one-time: install the test tooling into the project venv
.venv/bin/python -m pip install pytest pytest-cov pytest-asyncio coverage

# run the whole suite
MONGODB_CONNECTION_STRING=mongodb://localhost:27017 \
  .venv/bin/python -m pytest

# a single module / file / test
.venv/bin/python -m pytest aggregator/tests/
.venv/bin/python -m pytest aggregator/tests/test_numeric_aggregation.py
.venv/bin/python -m pytest aggregator/tests/test_numeric_aggregation.py::TestComputeStats
```

Notes:
- `MONGODB_CONNECTION_STRING` must be set because `main/config/settings.py`
  reads it at import time. **No real database is contacted** — it is only a
  lazy connection-string value; all DB calls in tests are mocked.
- Configuration lives in [`certifier/pytest.ini`](../certifier/pytest.ini)
  (`asyncio_mode = auto`, test discovery roots) and
  [`certifier/conftest.py`](../certifier/conftest.py) (puts the certifier root
  on `sys.path` so absolute imports like `from utils...` resolve from any CWD).

### Go — chaoscenter services & litmus-go (`go test`)

Each Go service is its own module (own `go.mod`). Run from the module root:

```bash
# chaoscenter services
cd AgentCert/chaoscenter/authentication && go test ./...
cd AgentCert/chaoscenter/subscriber     && go test ./...
cd AgentCert/chaoscenter/graphql/server && go test ./...

# litmus-go (pure helper packages only; experiments/ + chaoslib/ need a cluster)
cd litmus-go && go test ./pkg/...
```

### TypeScript/React — chaoscenter web (`jest`)

```bash
cd AgentCert/chaoscenter/web
CI=true yarn jest --watchAll=false            # run all suites
CI=true yarn test:coverage --watchAll=false   # with coverage
```

`node_modules` must be installed (`yarn install`). `jest.config.js` collects
coverage only from `**/*.{tsx,jsx}` — pure `.ts` helpers can still be tested
for correctness, but only `.tsx`/`.jsx` files move the reported percentage.

---

## How we write tests

The suites were rewritten from scratch (the prior tests had drifted from the
code and no longer ran). Conventions:

- **One `test_<source>.py` / `<source>_test.go` per source file**, in the
  package's `tests/` dir (Python) or same package (Go, table-driven).
- **All external I/O is mocked** — Azure/LLM clients, MongoDB, Kubernetes,
  gRPC, git, blob storage, network, and the filesystem (via `tmp_path` /
  `httptest` / `client-go/fake`). Tests never touch a real service.
- **Deterministic assertions** — expected values are derived independently
  (hand/`numpy`-checked); randomized code is seeded or asserted on invariants.
- Async Python uses `asyncio_mode=auto` (no explicit `@pytest.mark.asyncio`);
  async clients are mocked with `AsyncMock`.

---

## Generating coverage reports

SonarQube does **not** run tests or measure coverage itself — it imports a
coverage report produced by each native tool. Generate them first:

### Python → Cobertura XML

```bash
cd certifier
cat > /tmp/coveragerc <<'EOF'
[run]
relative_files = True
source = .
omit = */.venv/*, */tests/*, */test_*.py, conftest.py
EOF
MONGODB_CONNECTION_STRING=mongodb://localhost:27017 \
COVERAGE_RCFILE=/tmp/coveragerc \
  .venv/bin/python -m pytest --cov=. --cov-report=xml:coverage.xml

# Sonar runs from the repo root, so rewrite paths to be repo-root relative:
sed -i 's#filename="#filename="certifier/#g' coverage.xml
sed -i 's#<source>\.</source>#<source></source>#' coverage.xml
```

> The path rewrite is required: coverage.py writes paths relative to
> `certifier/`, but the SonarQube scanner indexes files from the monorepo
> root. Without it, certifier reports 0% coverage.

### Go → coverprofile

```bash
# per module
cd AgentCert/chaoscenter/authentication && go test ./... -coverprofile=coverage.out -covermode=atomic
# ...repeat for subscriber, graphql/server, litmus-go
go tool cover -func=coverage.out | tail -1   # quick total
```

### Web → lcov

```bash
cd AgentCert/chaoscenter/web
CI=true yarn test:coverage --coverageReporters=lcov --watchAll=false
# → coverage/lcov.info
```

---

## SonarQube — consolidated dashboard

Configuration is in [`sonar-project.properties`](../sonar-project.properties)
at the repo root. It declares the source roots, the coverage report paths for
each language, the **test vs. main source split** (`sonar.tests`), and
exclusions for generated code (`graph/generated`, `models_gen.go`, `*.pb.go`)
and vendored dirs.

### 1. Start the server (Docker)

```bash
docker run -d --name sonarqube \
  -p 9001:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_logs:/opt/sonarqube/logs \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  sonarqube:community
```

- Host port **9001** (port 9000 is used by ClickHouse on this host).
- Dashboard: <http://localhost:9001> — default login `admin` / `admin`
  (change on first login).
- The data volume persists across restarts. After a host reboot:
  `docker start sonarqube`.

### 2. Create an analysis token

```bash
curl -s -u admin:<password> -X POST \
  "http://127.0.0.1:9001/api/user_tokens/generate?name=ace-scan&type=GLOBAL_ANALYSIS_TOKEN"
```

### 3. Run the scanner

Generate all coverage reports first (above), then:

```bash
cd /srv/projects/ace-monorepo
CACHE=/tmp/sonarcache_$(id -u); mkdir -p "$CACHE/scannerwork"
docker run --rm --network host -u "$(id -u):$(id -g)" \
  -e SONAR_HOST_URL="http://127.0.0.1:9001" \
  -e SONAR_TOKEN="<token>" \
  -e SONAR_USER_HOME="$CACHE" \
  -v "$(pwd):/usr/src" -v "$CACHE:$CACHE" \
  sonarsource/sonar-scanner-cli \
  -Dsonar.working.directory=$CACHE/scannerwork
```

Then open <http://localhost:9001/dashboard?id=ace-monorepo>.

> **Scanner gotchas (why the flags above):** the container is run as the host
> user (`-u`) so it can read all source files; the working dir and cache are
> pointed at a host-owned `/tmp` directory because the container's user does
> not inherit the host's supplementary groups and cannot write inside the repo
> or the default `/tmp/.scannerwork`. `/tmp` is cleared on reboot — recreate
> the cache dir if a scan fails with a permission error.

---

## What is *not* unit-tested

These areas are intentionally left for integration/e2e coverage — unit tests
would require disproportionate mocking or live infrastructure:

- **certifier**: the `pipeline_service.execute_pipeline` orchestrators (wire
  together all four phases + LLM + on-disk artifacts) and the CLI entrypoints.
- **Go services**: code paths that require a live MongoDB, Kubernetes API,
  gRPC peer, or git remote. Generated GraphQL plumbing is excluded from the
  coverage denominator entirely.
- **litmus-go**: `experiments/` and `chaoslib/` — chaos executors that need a
  real cluster.
- **web**: full React views/pages; only logic-dense components and utilities
  are unit-tested.
