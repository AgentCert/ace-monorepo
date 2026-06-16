---
title: Contributing
nav_order: 6
---

# Contributing to ACE

ACE is an open source project, and contributions are very welcome — whether that's a new fault scenario, a domain-specific certifier, a bug fix, or documentation.

**Before you open your first PR:** join [Slack ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw) — it's the fastest place to get a question answered or discuss an idea before investing time in a change.

---

## Where things live

ACE is a **monorepo of git submodules**. Each component is its own repository; the monorepo pins the SHA.

| Submodule | What it is |
|---|---|
| `AgentCert` | Control plane: GraphQL API (Go), auth (Go), web UI (React/TS) |
| `certifier` | 4-phase certification pipeline (FastAPI/Python) + report rendering |
| `flash-agent` | Flash ITOps agent implementation |
| `agent-sidecar` | Agent sidecar (OTEL instrumentation) |
| `agentcert-stack` | Full stack compose + LiteLLM config |
| `app-charts` | Application Helm charts (SockShop etc.) |
| `agent-charts` | Agent Helm charts |
| `chaos-charts` | Chaos experiment Helm charts |
| `litmus-go` | LitmusChaos experiment implementations (Go) |

**Rule of thumb:** if your change is inside a component, open the PR in that submodule's repo first, then bump the pointer here. If it's orchestration, scripts, or docs — PR here directly.

---

## Getting set up

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
cp .env.example .env        # fill in AZURE_OPENAI_* and any other CHANGE_ME values
docker compose up -d        # full platform
```

See the [Setup guide →](setup/README.md) for the full walkthrough.

---

## What to contribute

<div class="topic-grid">
  <div class="topic-card">
    <div class="topic-card-title">Fault Scenarios <span style="font-size:.72rem;background:#fef3c7;color:#92400e;border-radius:4px;padding:.1rem .4rem;font-weight:700;vertical-align:middle;margin-left:.35rem">highest impact</span></div>
    <div class="topic-card-desc">The fault library is what makes ACE general. Adding a scenario for your cloud provider, agent framework, or domain expands what every user can certify against. Scenarios live in <code>chaos-charts</code> and <code>litmus-go</code>.</div>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Domain Certifiers</div>
    <div class="topic-card-desc">The SRE certifier is the first. Healthcare, finance, legal, DevSec — each domain has different failure modes and evidence requirements. A domain certifier is a Python module that plugs into the Phase 0–3 pipeline.</div>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Agent Adapters</div>
    <div class="topic-card-desc">ACE currently ships with the Flash ITOps agent. Adapters for AutoGen, LangChain, Semantic Kernel, or your own agent framework let more teams use the platform without forking.</div>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Bug Fixes &amp; Improvements</div>
    <div class="topic-card-desc">Open an issue first for anything non-trivial so the approach can be agreed before work starts. For obvious bugs, a PR with a clear description is fine.</div>
  </div>
</div>

---

## Branching and commits

- Branch off `main`. Name: `feature/`, `fix/`, `chore/`, `docs/`.
- Follow **[Conventional Commits](https://www.conventionalcommits.org/)**: `feat(certifier): add healthcare fault bucketing`.
- Keep commits atomic and PRs focused on one logical change.
- Rebase on `main` before opening or updating a PR — no merge commits.

---

## PR checklist

Before requesting review:

- [ ] Branch is rebased on current `main`
- [ ] Change builds and the affected service runs locally
- [ ] Tests added/updated where applicable
- [ ] No `.env` files, secrets, or machine-specific paths committed
- [ ] Docs updated if behaviour or setup steps changed
- [ ] For submodule pointer bumps: referenced SHA is already merged and pushed upstream

### PR description template

```markdown
## What
Short description of the change.

## Why
Problem it solves. Link the issue: Closes #123.

## How
Key implementation decisions worth a reviewer's attention.

## Testing
How you verified the change.
```

---

## Submodule workflow

```bash
# Make your change in the submodule, commit and push it there first.
# Then in the monorepo:
git submodule update --remote --merge   # advance pointer to branch head
git add <submodule-name>
git commit -m "chore: bump <submodule> pointer (<what changed>)"
```

Never commit a pointer to an unmerged or unpushed submodule commit — others can't fetch it.

---

## Code style

- **Go** — `gofmt` / `goimports` / `go vet`. Target Go 1.21+.
- **Python** — PEP 8. Certifier scripts are runnable as `./script.py` with documented flags.
- **TypeScript** — follow the lint/format config in the frontend submodule.
- Match the style of surrounding code — naming, comment density, structure.

---

## Security

Never commit secrets. `.env` is gitignored for a reason. Redact keys and tokens from issues, PRs, and log pastes. Report vulnerabilities privately to the maintainers rather than in a public issue.

---

By contributing you agree your changes are licensed under the [Apache License 2.0](https://github.com/AgentCert/ace-monorepo/blob/main/LICENSE).
