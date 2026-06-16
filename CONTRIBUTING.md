# Contributing to ACE

Thanks for taking the time to contribute to the **Agent Certification Engine (ACE)** monorepo. This guide covers how the repository is structured, how to get set up, and the conventions we follow for issues and pull requests.

Please read it before opening your first issue or PR — it will save everyone a round-trip.

## Table of Contents

- [Getting Help](#getting-help)
- [Code of Conduct](#code-of-conduct)
- [Repository Layout](#repository-layout)
- [Getting Set Up](#getting-set-up)
- [Working with Submodules](#working-with-submodules)
- [Branching Model](#branching-model)
- [Commit Messages](#commit-messages)
- [Creating Issues](#creating-issues)
- [Creating Pull Requests](#creating-pull-requests)
- [Skills & Subagents](#skills--subagents)
- [Code Style & Quality](#code-style--quality)
- [Security & Secrets](#security--secrets)

---

## Getting Help

Have a question, want to discuss an idea before opening an issue, or need a hand getting set up? Join the project **Slack workspace**:

**[👉 Join the AgentCert Slack](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw)**

Slack is the best place for quick questions, design discussion, and coordinating work across submodules. For tracked work — bugs, feature requests, and changes — please still open an issue or PR so it's documented.

---

## Code of Conduct

Be respectful, assume good intent, and keep discussion focused on the work. Harassment or abuse of any kind is not tolerated.

---

## Repository Layout

ACE is a **monorepo of git submodules** — each concern lives in its own repository so components can be versioned, built, and released independently. The monorepo itself pins each submodule to a specific commit SHA.

| Module | Description |
|--------|-------------|
| [AgentCert](./AgentCert) | Core AgentCert platform (GraphQL control plane, auth, frontend) |
| [certifier](./certifier) | Certification engine (Phase 0–3 pipeline + report rendering) |
| [flash-agent](./flash-agent) | Flash agent implementation |
| [agent-sidecar](./agent-sidecar) | Agent sidecar |
| [agentcert-stack](./agentcert-stack) | Full stack deployment (LiteLLM setup, compose) |
| [app-charts](./app-charts) | Application Helm charts |
| [agent-charts](./agent-charts) | Agent Helm charts |
| [chaos-charts](./chaos-charts) | Chaos engineering charts |
| [litmus-go](./litmus-go) | Litmus chaos experiments (Go) |

**Where should my change go?**

- A change scoped to a single component → open a PR **in that submodule's repository**.
- A change to orchestration scripts, root config, docs, or the submodule pointers → open a PR **in this monorepo**.

See [`.gitmodules`](./.gitmodules) for the upstream URL and tracked branch of each submodule.

---

## Getting Set Up

The [README](./README.md) is the source of truth for environment setup. The short version:

1. **Clone with submodules:**
   ```bash
   git clone --recurse-submodules <repo-url>
   # or, if already cloned:
   git submodule update --init --recursive
   ```
2. **Configure env files** — copy and fill in the placeholders:
   ```bash
   cp .env.example .env
   cp build-paths.env.example build-paths.env
   ```
   Replace every `CHANGE_ME` / `REPLACE_ME`. **`.env` is gitignored — never commit secrets.**
3. **Bring up local services** (MongoDB + Langfuse + LiteLLM + Certifier) with the recommended one-command path:
   ```bash
   ./scripts/start-local-services.sh
   ```
4. **Start AgentCert** once `kubectl` access is configured:
   ```bash
   bash scripts/azure_build/start-agentcert-v2.sh \
     --env-file $(pwd)/.env --paths-file $(pwd)/build-paths.env
   ```

For the full walkthrough — prerequisites, MongoDB/Langfuse/LiteLLM, Kubernetes access, and the build pipeline — see [Setup](./README.md#setup) and `scripts/azure_build/AZURE_BUILD_GUIDE.md`.

**Always verify your change locally** before opening a PR. Run the affected service (or the full stack) and confirm the behaviour you intend. For certifier changes, the dev tools (`scripts/run_certification.py`, `scripts/dump_langfuse_trace.py`) let you exercise the pipeline without the FastAPI service.

---

## Working with Submodules

Submodules are the most common source of confusion in this repo. A few rules:

- **Code changes happen in the submodule.** Commit and push your change to the submodule's own repository (and open a PR there) first.
- **The monorepo only pins SHAs.** After your submodule change is merged, advance the pointer here:
  ```bash
  git submodule update --remote --merge   # fast-forward to the tracked branch head
  git add <submodule>                      # stage the new pointer
  git commit -m "chore: bump <submodule> pointer"
  ```
- A monorepo PR that bumps a submodule pointer should state **which submodule commit(s)** it now points to and why.
- Never commit a submodule pointer that references an unmerged or unpushed commit — others won't be able to fetch it.

---

## Branching Model

- The default integration branch is **`main`**. Do not commit directly to it.
- Create a topic branch off `main` for your work. Use a descriptive, prefixed name:
  - `feature/<short-description>` — new functionality
  - `fix/<short-description>` — bug fixes
  - `chore/<short-description>` — tooling, deps, config, docs
- Keep branches focused on a single logical change. Rebase on the latest `main` before opening or updating your PR.

---

## Commit Messages

This repo follows **[Conventional Commits](https://www.conventionalcommits.org/)**. The format is:

```
<type>(<optional scope>): <short summary>
```

**Types used in this repo:** `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `ci`, `perf`.

Examples from the history:

```
fix(scripts): correct PROM_MCP_URL fallback to sock-shop:8083
chore: bump submodule pointers and add litmus-go submodule
docs: document the certifier pull-from-Docker-Hub flow
```

Guidelines:

- Use the **imperative mood** ("add", "fix", "correct" — not "added"/"fixes").
- Keep the summary under ~72 characters; put detail in the body if needed.
- Reference issues in the body or footer (`Closes #123`).
- Make each commit a coherent, self-contained change.

---

## Creating Issues

Good issues are reproducible and scoped. Before opening one:

- **Search existing issues** to avoid duplicates.
- **Pick the right repo.** A bug in the certifier belongs in the `certifier` repo; an orchestration/script/docs bug belongs here.

### Bug reports

Include:

- **Summary** — one line describing what's wrong.
- **Component** — which submodule or script (e.g. `certifier`, `start-local-services.sh`).
- **Environment** — OS, Docker/Go/Node versions, Kubernetes context (local kind, AKS, etc.), and which setup path you used.
- **Steps to reproduce** — exact commands, including the script flags used.
- **Expected vs. actual behaviour.**
- **Logs / evidence** — relevant output. Service logs live under `/tmp/agentcert-runtime/.{auth,graphql,frontend}.log`. **Redact secrets** (keys, tokens, connection strings) before pasting.

### Feature requests

Include the **problem / use case** (not just a proposed solution), the **component** it affects, and any **alternatives** you've considered.

---

## Creating Pull Requests

### Before you open a PR

- [ ] Branch is up to date with `main` (rebased, no merge commits where avoidable).
- [ ] Change is scoped to one logical concern.
- [ ] Code builds and the affected service runs locally.
- [ ] Tests added/updated where it makes sense, and existing tests pass.
- [ ] No secrets, `.env` files, or machine-specific paths are committed.
- [ ] Docs updated if behaviour, flags, or setup steps changed (README, this file, or the relevant submodule docs).
- [ ] For submodule pointer bumps: the referenced submodule commit is already merged and pushed upstream.

### PR description

Use this structure:

```markdown
## What
A short description of the change.

## Why
The problem it solves or the motivation. Link the issue: Closes #123.

## How
Key implementation notes / decisions worth a reviewer's attention.

## Testing
How you verified the change (commands run, output observed, screenshots for UI).

## Scope
- [ ] Submodule(s) affected: <name(s)>, or "monorepo only"
- [ ] Submodule pointer bumped: <yes/no — new SHA(s)>
```

### Guidelines

- **Keep PRs small.** Large PRs are slow to review; split unrelated changes.
- **Title using Conventional Commits** — the PR title is often what lands as the squash-commit message.
- **Self-review the diff** before requesting review — catch stray debug code, commented-out blocks, and unintended file changes (especially accidental submodule pointer moves).
- **Respond to review feedback** with follow-up commits; squash on merge.
- **CI must pass** before merge. Don't merge red.
- Request review from a maintainer of the affected component.

---

## Skills & Subagents

This repo ships a set of [Claude Code](https://claude.com/claude-code) skills and subagents under [`.claude/`](./.claude) to automate the most common — and most error-prone — ACE workflows. They encode the conventions in this guide so you don't have to remember them.

**Skills** (invoke as slash commands, e.g. `/setup-local`):

| Skill | Use it to |
|---|---|
| `setup-local` | Bootstrap a local dev environment — copy/validate `.env` & `build-paths.env`, then bring up the local stack |
| `bump-submodule` | Safely advance submodule pointer(s) to the tracked-branch head and draft the bump commit |
| `run-certification` | Run the certifier pipeline (Phase 0–3) locally via `run_certification.py` |
| `pipeline-smoke-test` | Run the documented certifier end-to-end smoke test against the running API |
| `release-images` | Build & push the five component images to Docker Hub and report the new certifier digest |
| `gen-tests` | Generate and run unit tests for the current diff in the right framework |
| `new-pr` | Open a PR using the Conventional-Commit + template conventions below |

**Subagents** (delegated automatically, or invoke by name):

| Agent | Role |
|---|---|
| `frontend-developer` | AgentCert frontend (UI + GraphQL/auth integration) |
| `go-backend-developer` | Go GraphQL control plane and auth service |
| `certifier-backend-developer` | FastAPI certifier pipeline and endpoints |
| `k8s-deployer` | Helm charts, manifests, and namespace/cluster config |
| `unit-test-generator` | Idiomatic tests across Go, Python, and TypeScript |
| `submodule-pointer-auditor` | Pre-PR audit that every staged submodule SHA is pushed upstream (read-only) |
| `secret-scanner` | Pre-PR scan of the diff for leaked secrets and committed `.env` files (read-only) |

Before raising a PR, the `submodule-pointer-auditor` and `secret-scanner` agents are worth running as a safety check — they directly enforce two items on the [PR checklist](#before-you-open-a-pr). These tools are optional conveniences; nothing here is required to contribute.

## Code Style & Quality

- **Go** (AgentCert, litmus-go, etc.): run `gofmt`/`goimports` and `go vet`; follow standard Go idioms. Target Go 1.21+.
- **Python** (certifier, scripts): follow PEP 8; keep scripts runnable as `./script.py` with the documented flags.
- **TypeScript/JS** (frontend): follow the existing lint/format config in the submodule.
- **Shell scripts**: keep them idempotent and POSIX-friendly where the existing scripts are; preserve the `--only-*` / `--skip-*` flag conventions.
- Match the style of the surrounding code — naming, comment density, and structure.

---

## Security & Secrets

- **Never commit secrets.** `.env` is gitignored for a reason; `build-paths.env` carries no machine-specific state and is safe to commit.
- Redact keys, tokens, and connection strings from issues, PRs, and logs.
- Report security vulnerabilities **privately** to the maintainers rather than in a public issue.

---

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](./LICENSE).
