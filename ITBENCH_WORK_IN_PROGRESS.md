# ITBench integration — work in progress, read before continuing

Branch `feature/itbench-scenarios` has unfinished ITBench SRE-scenario work.

**Full continuation guide:** `chaos-charts/ITBENCH_HANDOFF.md` (in the `chaos-charts` submodule, same branch).

Quick status:
- `app-charts` submodule: bookinfo + otel-demo charts — **complete**.
- `chaos-charts` submodule: 2 of 6 ITBench faults implemented as first-class ChaosHub fault bundles (`scaled-to-zero-kubernetes-workload`, `nonexistent-kubernetes-workload-container-image`); 4 remain, plus category-index registration, `experiments.yaml` regeneration, and rewriting the two app-level Argo workflows to use real `ChaosEngine` CRs. See the handoff doc for exact design notes, inlined ITBench source data, and what's been verified vs. not.
- Check `git remote -v` in this repo and in both submodules before pushing anything — the fork URLs in `.gitmodules` may need updating if repo ownership has moved.

Delete this file once the work in `chaos-charts/ITBENCH_HANDOFF.md` is finished and merged.
