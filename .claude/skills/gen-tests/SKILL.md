---
name: gen-tests
description: Generate and run unit tests for the current diff in the correct framework per language (Go testing/table-driven, Python pytest, TS), then report pass/fail. Use before opening a PR to satisfy the "tests added/updated" checklist item.
---

# gen-tests

Generate tests for changed code and run them.

## Steps

1. **Scope the diff.** Identify changed files and which submodule/language each belongs to:
   ```bash
   git status --porcelain
   git diff --name-only
   ```
2. **Generate tests in the right framework**, matching the conventions already used in that submodule:
   - **Go** (AgentCert, litmus-go, agent-sidecar): table-driven tests in `_test.go` files using the standard `testing` package; mirror existing test style.
   - **Python** (certifier, scripts): `pytest` tests under the submodule's test dir; use fixtures consistent with the existing suite.
   - **TypeScript/JS** (frontend): use the framework already configured in the frontend submodule.
3. **Cover the meaningful paths** — new branches, error handling, edge cases — not just the happy path. Delegate complex generation to the `unit-test-generator` agent if needed.
4. **Run the tests** for the affected component:
   - Go: `go test ./...`
   - Python: `pytest`
   - Frontend: the submodule's `yarn test` / configured runner
5. **Report** which tests were added and the pass/fail result. Do not claim success unless the tests actually ran and passed.
