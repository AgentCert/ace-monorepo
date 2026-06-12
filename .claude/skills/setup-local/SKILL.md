---
name: setup-local
description: Bootstrap a local ACE dev environment — copy and validate .env / build-paths.env, then bring up MongoDB, Langfuse, LiteLLM, and the Certifier via start-local-services.sh. Use when onboarding, after a fresh clone, or when local services are not running.
---

# setup-local

Bring a contributor from a fresh clone to a running local stack.

## Steps

1. **Submodules.** Ensure submodules are initialized:
   ```bash
   git submodule update --init --recursive
   ```
2. **Env files.** If missing, copy the examples:
   ```bash
   cp .env.example .env
   cp build-paths.env.example build-paths.env
   ```
3. **Validate `.env`.** Grep for unfilled placeholders and report each line that still contains `CHANGE_ME` or `REPLACE_ME`. Warn if the docker-bridge IP still shows the example `172.26.0.1` (the real one comes from `ip -4 addr show docker0 | grep inet`). **Never print secret values** — report only the variable names that need attention.
4. **Bring up services.** Run the recommended one-command path:
   ```bash
   ./scripts/start-local-services.sh
   ```
   Scope with `--only-mongo` / `--only-langfuse` / `--only-litellm` / `--only-certifier` if the user only needs part of the stack. Add `--skip-litellm` if there is no Kubernetes cluster yet.
5. **Report reachability.** Confirm and print the endpoints that came up:
   - MongoDB → `mongodb://admin:****@localhost:27017/?authSource=admin`
   - Langfuse → http://localhost:4000
   - LiteLLM → http://localhost:14000
   - Certifier Swagger → http://localhost:8000/docs

## Notes

- `.env` is gitignored — never commit it. `build-paths.env` is safe to commit.
- The script is idempotent; re-run with `--restart` to recreate already-running services.
- For the full backend (auth + GraphQL + frontend), point the user to `scripts/azure_build/start-agentcert-v2.sh` (see README §7).
