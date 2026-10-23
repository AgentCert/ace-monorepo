# Build, publish and install script modes

Build locally from the monorepo root:

```bash
make build
# Equivalent commands:
./scripts/build-and-push.sh
./scripts/setup.sh
```

All three build **every `build` row in `deploy/images.txt`**. They do not log
in, push, prune images, load a cluster, restart workloads, or change `.env`.
Base images and package dependencies can still be downloaded during a build.
The default rebuilds without Docker's build cache. For a development rebuild:

```bash
make build BUILD_ARGS="--allow-build-cache"
```

## Explicit operations

| Entry point | Default | Explicit operation |
|---|---|---|
| `make`, `make all`, `make build` | Build every inventory image locally | `make push` publishes; `make install` opens the deployment wizard |
| `scripts/build-and-push.sh` | Build every inventory image locally | `--push` publishes; `--kind-load` loads KinD images and restarts mapped deployments |
| `scripts/setup.sh` | Build every inventory image locally | `--deploy` or `--setup` installs; `--restart` reapplies the saved installation; publication additionally requires `--push` |
| `scripts/prepare-images.sh` | Build every inventory image locally; `--hub-only` builds just the bundle | `--deploy` prepares images and registry configuration in the active cluster |
| `scripts/start-local-services.sh` | Build certifier locally | `--deploy` starts the selected supporting services; `--restart` explicitly recreates them |
| Component `build-*.sh` wrappers | Build their one inventory image through the common builder | Same `--push` and `--kind-load` options as the common builder |
| Both `build-and-deploy-app-chart.sh` wrappers | Build install-app locally | `--push` publishes; `--deploy` loads Minikube and updates the selected `.env` |
| `scripts/mirror-images.sh` | Pull and tag third-party images into the local cache | `--push` publishes the copies; `--dry-run` previews the operation |
| `agentcert-stack/litellm-setup/build-litellm.sh` | Cache the upstream LiteLLM image locally | `--deploy` applies Kubernetes resources |
| `scripts/apply_cluster_prereqs.sh` | Explain the required deployment flag | `--deploy` applies prerequisites; combine with `--uninstall` to remove the sync controller |
| `scripts/kubectl-apply-images.sh -f FILE` | Render resolved manifests to stdout | `--deploy` applies the rendered manifests |
| Legacy Azure launchers | Build every inventory image locally | `--deploy` enters the legacy host-startup flow; prefer `setup.sh --deploy` for installation |
| Agent harness `setup.sh` scripts | Build their local Docker sandbox image | `--install` additionally installs host development dependencies where supported |
| SRE Qwen harness | Prepare the shared local SRE image | `--check-model` also checks the running Ollama service |
| A2A/MCP harness | Show installation instructions; it uses no Docker image | `--install` creates its local Python environment |

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

The publisher refuses to replace an existing named release when it cannot
prove that the existing image has the same digest. Registry credentials are
required for `--push`, not for an ordinary local build. A successful complete
`--push --tag` updates `ACE_IMAGE_TAG` in the selected `.env`; a partial
`--only` publication does not.

`ACE_BUILD_NETWORK` is read from the environment or `.env` by the shared
builder. This checkout uses `host` because its default Docker network could
not reach package repositories. All five root Compose build definitions also
honor it. Component Makefile builds use the same base-image resolution and
network setting. Explicit Makefile `build-push` targets finish the build before
pushing, including with `make -j`.

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

The 16 October 2026 audit passed **103 mode checks**, **143 registry checks**,
**66 cloud/install checks**, and syntax checks for all **49 shell scripts**.
An actual local build completed **every inventory image** successfully.
Evidence is in `.tmp/script-audit/`. Live deployment and full agent/chaos
workflows are separate integration checks.

Local ShellCheck analysis of the **48 maintained shell scripts** reported
**zero errors**. The binary came from Ubuntu's package repository and was
extracted into `.tmp/script-audit/`, without a system-wide installation.

Generated dependencies such as Husky's `.husky/_/husky.sh` are excluded from
maintained-source lint checks. Historical handoff documents under `docs_2/`
may describe the previous implicit publish/deploy behavior.
