---
name: bump-submodule
description: Advance one or all submodule pointers in the ACE monorepo to the head of their tracked branch, verify the target commit is pushed upstream, and draft a Conventional-Commit pointer-bump commit. Use when updating submodule pointers after a submodule change has merged.
---

# bump-submodule

Safely advance submodule pointers in the monorepo.

## Steps

1. **Identify scope.** Bump a specific submodule, or all of them. The tracked branch for each is declared in `.gitmodules` (most are `main`; `chaos-charts` and `litmus-go` track `master`).
2. **Fast-forward** to the tracked branch head:
   ```bash
   git submodule update --remote --merge <submodule>   # omit name for all
   ```
3. **Verify the target is fetchable upstream** — this is the critical safety check. For each changed submodule, confirm the new SHA exists on the remote tracked branch:
   ```bash
   NEW=$(git -C <submodule> rev-parse HEAD)
   git -C <submodule> branch -r --contains "$NEW"     # must list origin/<tracked-branch>
   ```
   If the SHA is not on the remote, **stop** and tell the user to push the submodule commit upstream first. A pointer to an unpushed commit breaks every other clone.
4. **Show old→new.** Print the old and new SHA for each bumped submodule so the change is reviewable.
5. **Stage and commit:**
   ```bash
   git add <submodule>
   git commit -m "chore: bump <submodule> pointer to <short-sha>"
   ```
   For multiple submodules: `chore: bump submodule pointers`.

## Rules

- Never commit a pointer to an unmerged/unpushed submodule commit.
- Never stage an *unintended* submodule pointer move — confirm each changed pointer is one the user meant to change.
- Defer to the `submodule-pointer-auditor` agent for a deeper pre-PR audit.
