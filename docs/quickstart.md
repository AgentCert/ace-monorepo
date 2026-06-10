# Try it out

Get a local ACE stack running in a few minutes. This is the condensed path —
full prerequisites and per-service detail live in the
[README](https://github.com/AgentCert/ace-monorepo#setup).

## 1. Clone with submodules

Each ACE component lives in its own submodule, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo.git
cd ace-monorepo
```

Already cloned without `--recurse-submodules`? Initialise them:

```bash
git submodule update --init --recursive
```

## 2. Configure

Copy the two example files at the repo root and fill them in:

```bash
cp .env.example .env
cp build-paths.env.example build-paths.env
```

- **`.env`** — secrets, image tags, ports, and the MongoDB / Langfuse / LiteLLM /
  Azure OpenAI endpoints. Replace every `CHANGE_ME` and `REPLACE_ME` placeholder.
  It is gitignored — never commit secrets.
- **`build-paths.env`** — submodule checkout paths and git URLs. Paths resolve
  relative to the file, so no editing is required.

!!! tip
    The bridge IP `172.26.0.1` in the examples is the docker bridge gateway.
    Find yours with `ip -4 addr show docker0 | grep inet` and replace it everywhere.

## 3. Start the local stack

Once `.env` is filled in, bring up **MongoDB + Langfuse + LiteLLM + the Certifier
API** with a single command:

```bash
./scripts/start-local-services.sh
```

The script is idempotent — re-run it anytime. Scope it with `--only-mongo`,
`--only-langfuse`, `--only-litellm`, or `--only-certifier` (or the matching
`--skip-*` flags), and add `--restart` to recreate already-running services.

| Service | Reachable at |
|---|---|
| MongoDB | `mongodb://admin:1234@localhost:27017/?authSource=admin` |
| Langfuse | <http://localhost:4000> |
| LiteLLM | <http://localhost:14000> |
| Certifier (Swagger) | <http://localhost:8000/docs> |

## 4. Verify the certifier

Open the Swagger UI at <http://localhost:8000/docs> to confirm the certifier API
is up, then continue with the certification pipeline described in the
[README command reference](https://github.com/AgentCert/ace-monorepo#quick-command-reference).
