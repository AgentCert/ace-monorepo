---
name: new-pr
description: Open a pull request following the ACE CONTRIBUTING conventions — Conventional-Commit title, the standard PR description template, and auto-detected affected submodules / pointer bumps. Use when the user is ready to raise a PR.
---

# new-pr

Create a PR that conforms to CONTRIBUTING.md.

## Steps

1. **Pre-flight checks** (mirror the CONTRIBUTING checklist):
   - Branch is off `main` and named `feature/…`, `fix/…`, or `chore/…`.
   - Diff is one logical concern; no secrets, `.env`, or machine-specific paths.
   - Any submodule pointer bump references an already-pushed commit (run the `submodule-pointer-auditor` agent if pointers changed).
2. **Detect scope.** From the diff, determine affected submodules and whether any submodule pointer moved.
3. **Push the branch** if not yet pushed.
4. **Open the PR** with `gh`, using a Conventional-Commit title and this body:
   ```markdown
   ## What
   <short description>

   ## Why
   <problem / motivation>. Closes #<issue>.

   ## How
   <key implementation notes>

   ## Testing
   <commands run, output observed, screenshots for UI>

   ## Scope
   - [ ] Submodule(s) affected: <name(s)>, or "monorepo only"
   - [ ] Submodule pointer bumped: <yes/no — new SHA(s)>
   ```
   ```bash
   gh pr create --base main --title "<type>(<scope>): <summary>" --body "<filled template>"
   ```
5. **Report the PR URL.**

## Rules

- The PR title often becomes the squash-merge commit — keep it a valid Conventional Commit.
- Do not push or open the PR without the user's go-ahead.
