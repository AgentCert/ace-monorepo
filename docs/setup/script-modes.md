---
title: "Build, publish and install script modes"
parent: "Setup"
nav_order: 90
---

# Build, publish and install script modes

## The one distinction that catches people out

`scripts/setup.sh` has two completely different jobs, chosen by a flag:

| Command | What it does | Does it deploy? |
|---|---|---|
| `./scripts/setup.sh` | **Builds images and exits.** It `exec`s `build-and-push.sh` on line 176 and is replaced by it, so no `.env` is written, no cluster is created and no wizard is shown. | **No** |
| `./scripts/setup.sh --deploy` | The installation wizard: writes `.env`, builds, creates/reuses the cluster, installs ACE, connects the chaos infrastructure. | Yes |
| `./scripts/setup.sh --restart` | Re-applies the saved `.env` with no prompts. | Yes |

A successful build-only run ends exactly like this, and then stops:

```text
======================================
  All images built successfully!
======================================
  Build-only run: nothing was deployed and no cluster was changed.
  Next: ./scripts/setup.sh --deploy    (configure .env, create the cluster and install ACE)
```

That banner is a **success**, not an early exit. If you wanted a running platform,
the build was only the first half — run `./scripts/setup.sh --deploy` next.

---

## Building

Build locally from the monorepo root:

```bash
make build
# Equivalent commands:
./scripts/build-and-push.sh
./scripts/setup.sh
```

All three build **every `build` row in `deploy/images.txt`** (14 first-party images).
They do not push, prune images, load a cluster, restart workloads, or change `.env`.
When `IMAGE_REGISTRY` is set they log in to it first, because base images resolve
there (a failed login only warns).
Base images and package dependencies can still be downloaded during a build.
The default rebuilds without Docker's build cache. For a development rebuild:

```bash
make build BUILD_ARGS="--allow-build-cache"
```

`BUILD_ARGS` goes to `build-and-push.sh` (`make build`, `make push`);
`SETUP_ARGS` goes to `setup.sh` (`make install`, e.g. `SETUP_ARGS="--restart"`).
Only `make push` publishes. `make install` refuses a `--push` smuggled into
`SETUP_ARGS` — publish with `make push` instead.

A build that fails ends with this instead, and exits non-zero:

```text
======================================
  Completed with failures:
    ✗ certifier (build)
======================================
```

## Explicit operations

| Entry point | Default | Explicit operation |
|---|---|---|
| `make`, `make all`, `make build` | Build every inventory image locally | `make push` publishes; `make install` opens the deployment wizard |
| `scripts/build-and-push.sh` | Build every inventory image locally | `--push` publishes; `--kind-load` loads KinD images and restarts mapped deployments |
| `scripts/setup.sh` | Build every inventory image locally, then **exit** (it `exec`s `build-and-push.sh`) | `--deploy` or `--setup` installs; `--restart` reapplies the saved installation; publication additionally requires `--push` |
| `scripts/prepare-images.sh` | Build every inventory image locally, then exit; `--hub-only` builds just the bundle | `--deploy` prepares images and registry configuration in the active cluster |
| `scripts/start-local-services.sh` | Build certifier locally, then exit — **no service is started** | `--deploy` starts the selected supporting services; `--restart` explicitly recreates them |
| Component `build-*.sh` wrappers | Build their one inventory image through the common builder | Same `--push` and `--kind-load` options as the common builder |
| Both `build-and-deploy-app-chart.sh` wrappers | Build install-app locally | `--push` publishes; `--deploy` loads Minikube and updates the selected `.env` |
| `scripts/mirror-images.sh` | Pull the upstream third-party images into the local cache (no retagging) | `--push` publishes the copies and then removes only the copies that run created; `--dry-run` previews the operation |
| `agentcert-stack/litellm-setup/build-litellm.sh` | Cache the upstream LiteLLM image locally | `--deploy` applies Kubernetes resources |
| `scripts/apply_cluster_prereqs.sh` | Explain the required deployment flag | `--deploy` applies prerequisites; combine with `--uninstall` to remove the sync controller |
| `scripts/kubectl-apply-images.sh -f FILE` | Render resolved manifests to stdout | `--deploy` applies the rendered manifests |
| Legacy Azure launchers | Build every inventory image locally | `--deploy` enters the legacy host-startup flow; prefer `setup.sh --deploy` for installation |
| Agent harness `setup.sh` scripts | Build their local Docker sandbox image | `--install` additionally installs host development dependencies where supported |
| SRE Qwen harness | Prepare the shared local SRE image | `--check-model` also checks the running Ollama service |
| A2A/MCP harness | Create its local Python environment; it uses no Docker image | — |

`--local` cannot be combined with `--push`, `--kind-load`, or `--deploy` on
entry points that expose those mutually exclusive modes. `--local-build` on
setup selects local images for an explicit deployment and cannot be combined
with `--push`.

## Build selection and tags

```bash
# Build a subset locally:
./scripts/build-and-push.sh --only 'graphql|auth'

# Add a local tag without publishing or changing .env:
./scripts/build-and-push.sh --tag local-test

# Publish a new release explicitly; choose a fresh tag:
./scripts/build-and-push.sh --push --tag RELEASE-N

# Install explicitly:
./scripts/setup.sh --deploy
```

An existing release tag is only re-pushed from the same clean commit: the
publisher compares the image's revision label and otherwise refuses and asks
for a new tag. Registry credentials are
required for `--push`, not for an ordinary local build. A successful complete
`--push --tag` updates `ACE_IMAGE_TAG` in the selected `.env`; a partial
`--only` publication does not.

`ACE_BUILD_NETWORK` is read from the environment or `.env` by the shared
builder. Set it to `host` when the default Docker network cannot reach package
repositories. All five root Compose build definitions also honor it. Component
Makefile builds use the same base-image resolution and network setting.
Explicit Makefile `build-push` targets finish the build before pushing,
including with `make -j`. A component Makefile's `make push` pushes `IMAGE_TAG`
(default `latest`) through the registry library and never `ACE_IMAGE_TAG`;
release tags belong to `build-and-push.sh --push --tag`.

Installer Makefile targets validate and mount kubeconfig and values files,
forward the chosen Kubernetes context, and enable dry-run only for
`DRY_RUN=1`, `true`, or `yes`. KinD-loading Makefile targets require an explicit
`KIND_CLUSTER_NAME`.

## Validation

```bash
python3 scripts/tests/test-script-modes.py
bash scripts/tests/test-registry-tooling.sh
bash scripts/tests/test-cloud-profile.sh
```

The mode tests replace Docker, Kubernetes, Helm and Minikube commands with
test doubles. They check all-image selection, component scoping, argument
errors, conflicting modes, build/login/push failures, immutable release tags,
explicit loading, Makefile ordering, installer mounts, isolated local chart
overrides, and web-hook handling of filenames and failed type checks. They do
not publish images or deploy services. They use Python, Bash, Git, Make and
Node; manifest-rendering checks also use the repository's YAML tooling.

`make test-scripts` runs the three suites above. Live deployment and full
agent/chaos workflows are separate integration checks. Maintained shell scripts
are expected to report zero ShellCheck errors.

Generated dependencies such as Husky's `.husky/_/husky.sh` are excluded from
maintained-source lint checks. Historical handoff documents under `docs_2/`
may describe the previous implicit publish/deploy behavior.
