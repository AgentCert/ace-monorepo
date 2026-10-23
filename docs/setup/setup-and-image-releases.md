# How `setup.sh` works, and how images are published and released

This guide covers three things:

1. What `./scripts/setup.sh --deploy` does, step by step, and which files it uses.
2. How to publish images to JFrog (`infyartifactory.jfrog.io/docker-local/agentcert/…`) and Docker Hub (`agentcert/…`) after a code change or a third-party image change.
3. How a release tag (`RELEASE-1`, `RELEASE-2`, …) gets from `.env` to every pod, so the platform runs that release and not `:latest`.

---

## 1. `setup.sh` code flow

`scripts/setup.sh` is one long script. It runs top to bottom; the work is split into functions defined in the middle of the file and called at the end. The default mode builds images locally. Deployment is opt-in:

| Mode | Command | Asks questions? | How it ends |
|---|---|---|---|
| Local build (default) | `./scripts/setup.sh` | No; no deployment or publication | `exec`s `build-and-push.sh` (line 176) and is replaced by it — prints `All images built successfully!` then the `Next: ./scripts/setup.sh --deploy` hint, and exits |
| Install | `./scripts/setup.sh --deploy` | Yes (the wizard) | `✓ ACE stack deployed via Helm` banner with the URLs and credentials |
| Restart | `./scripts/setup.sh --restart [--local-build]` | No, it reuses `.env` | Same deploy banner; the method is auto-selected when non-interactive |
| Baseline refresh | `./scripts/setup.sh --record-image-baseline` | No | Rewrites `deploy/image-baseline.tsv`, prints `Done (--record-image-baseline).`, `exit 0` — never deploys |

Because the no-flag mode `exec`s the builder, **nothing in `setup.sh` past line 176 runs**: no
configuration wizard, no `.env` is written, no prerequisite self-heal, no cluster. The builder
still *reads* the env file for its own settings (`IMAGE_REGISTRY`, `IMAGE_MIRROR_NAMESPACE`,
`ACE_IMAGE_TAG`, `ACE_BUILD_NETWORK`, `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` via
`registry_load`) and logs in when a registry is set. This mode is the single most common
source of "setup finished but nothing is running".

Publishing images during an install or restart additionally needs `--push` (for example `./scripts/setup.sh --deploy --push`). Flag rules enforced at startup:

- `--push` and `--local-build` cannot be combined → `ERROR: --push and --local-build cannot be combined.`
- `--rootless-docker` and `--agent=` require `--deploy` or `--restart` → `ERROR: --rootless-docker and --agent require --deploy or --restart.`
- Choosing a publish option in the wizard without `--push` stops with `ERROR: publishing images requires --push.`

### 1.1 Preparation (runs in both install modes)

| Step | What happens | Code |
|---|---|---|
| Paths | `REPO_ROOT` is resolved to the physical path (`pwd -P`), so `/home/x` and `/Innovation/home/x` count as the same checkout | top of `setup.sh` |
| Shared helpers | Loads the image naming rule and registry login helpers | `source scripts/lib/registry.sh` |
| Flags | `--deploy` (alias `--setup`), `--restart`, `--push`, `--local-build`, `--rootless-docker`, `--agent=…` (the last two need `--deploy` or `--restart`) | argument loop |
| KUBECONFIG | Fixed to `${KUBECONFIG:-~/.kube/config}`, so `kubectl` and `helm` always talk to the same cluster | "Pin KUBECONFIG" |
| Prerequisites | Checks docker, git, kind, kubectl, helm and prints install commands for anything missing | `scripts/check-prerequisites.sh` |
| Submodules | Initialises any submodule that is still empty | `ensure_submodules_initialized` |
| `.env` | Created from `.env.example` if missing | "prep .env" |
| Copied `.env` | If `.env` came from another checkout (`ACE_ENV_CHECKOUT` does not match), the per-checkout values are cleared so they are recalculated for this user: cluster name, ports, kube dir, Docker socket, staging dirs. Credentials are kept. | block after `set_env` |
| Rootless Docker | Optional private Docker daemon (asked in setup mode, or `--rootless-docker`) | "Rootless Docker bootstrap" |
| Fill in per-checkout values | `ACE_INSTANCE_NAME` (from your login), `HOST_KUBE_DIR`, `OLLAMA_PORT`, `AGENT_CHARTS_ROOT` / `APP_CHARTS_ROOT`, `ACE_KIND_LOAD_TMPDIR` | blocks after the rootless section; `configure_kind_load_tmpdir` |
| Migrate old `.env` keys | `JFROG_*` / `DOCKERHUB_*` → `IMAGE_REGISTRY` + `REGISTRY_USERNAME` / `REGISTRY_PASSWORD`; `*_IMAGE_SOURCE=jfrog\|dockerhub` → `registry` | "Image registry settings now live in one place" |
| Image drift warning | Warns when a `:latest` image changed upstream since the last deploy | `check_image_drift` (uses `deploy/image-baseline.tsv`) |
| Image list | Every `build` row of `deploy/images.txt` (`ALL_BUILD_IMAGES`, generated from the inventory) | `declare -a ALL_BUILD_IMAGES` |

### 1.2 The wizard (setup mode only)

The questions are asked in this order. Answers are written to `.env` in the "write values" block.

0. **Rootless Docker** — `Set up and use rootless Docker for this checkout? [y/N]` (skipped when `--rootless-docker` was passed). Writes `DOCKER_HOST_SOCK`.
1. **Setup style**: `Choice [e/G]` — **e** (all questions now, then unattended) or **g**/Enter (section by section)
2. **`CLUSTER_MODE`**: `auto` / `fresh` / `local` / `cloud`, default `auto` (auto-upgraded to `cloud` when the current kube context is a cloud provider)
3. **Build images?** `Choice [p/l/A/n]` — `p` = build and push (needs `--push` on the command line), `l` = build some locally, **`a`/Enter** = build everything locally, `n` = skip and pull from the registry. This sets `PLATFORM_IMAGE_SOURCE`. On a cloud cluster the question is instead `Choice [p/N]`, where Enter uses the images already published.
4. Experiment image sources: `[l/r, Enter=l]` for install-app, install-agent and workflow runtime images. Skipped when you chose `a` (all set to `local`) or when `CLUSTER_MODE=cloud` (all set to `registry`). Sets `INSTALL_APP_IMAGE_SOURCE`, `INSTALL_AGENT_IMAGE_SOURCE` and `LITMUS_IMAGES_SOURCE`.
5. **IMAGE_REGISTRY**, plus username and token when it is set (`ask_image_registry`); `-` clears it
6. LLM providers: Azure OpenAI (**every follow-up Azure question is skipped when the API key is left empty**), Gemini, OpenRouter, Ollama (`Set up Ollama?` defaults to **Y** when no other provider key was given)
7. Flash-agent model alias — the default is the first *configured* alias in the order Ollama → Azure → Gemini → OpenRouter, deliberately **not** the value saved in `.env`
8. The agent to benchmark (`BENCHMARK_AGENT`) — skipped when `--agent=<name>` was passed
9. The corporate CA certificate (`CUSTOM_CA_CERT_PATH`)
10. **Deploy?** `Choice [k/H/n]` — `k` = kubectl, **`h`/Enter** = Helm, `n` = skip. A `cloud` cluster forces `h`.

In express mode (`e`) the deploy question is asked up front with the others; in guided mode it comes after the build. In restart mode none of these are asked. `CLUSTER_MODE`, `PLATFORM_IMAGE_SOURCE` and the other values come from `.env` (block `if [[ "$SETUP_MODE" == "restart" ]]`), and an interactive restart offers one prompt: `r Reconfigure all choices  |  Enter = Continue with policy above`.

### 1.3 After the wizard

| Step | What happens | Code |
|---|---|---|
| LiteLLM config | Adds the chosen Ollama model to `litellm_config.yaml` | "patch litellm_config.yaml" |
| Ollama | Starts this checkout's Ollama container and pulls the model in the background | `start-local-services.sh --deploy --only-ollama` |
| kind pre-warm | Express mode only: creates the kind cluster in the background while images build | "Pre-warm KinD cluster" → `ensure_kind_cluster` |
| Build | Builds the selected images in parallel, at most half the CPUs at once (min 1, max 6; override with `ACE_BUILD_PARALLELISM`). Logs go to `.tmp/build-logs/<n>.log` — the directory is wiped at the start of every build. Docker's cache is off unless `--allow-build-cache` is passed. Base images come from the registry (`docker_build_resolved`). With `p` (and `--push`) it also pushes them. Any failure stops setup. | "build (push to the image registry or local)" |
| Deploy | `helm_deploy` (default) or `k8s_deploy` | `case "${deploy_choice,,}"` |
| MongoDB restore | Wizard only: offers a `shut_down.sh` backup (the default is an empty database) | `offer_mongodb_restore` |
| Experiment images | Builds or loads the experiment images whose source is `local` | `scripts/prepare-images.sh --deploy` (run in the background during deploy) |

### 1.4 `helm_deploy` in detail (the default)

| # | Step | Code |
|---|---|---|
| 1 | Point `.env` service URLs at Kubernetes DNS names | inside `helm_deploy` |
| 2 | Create or reuse the kind cluster `agentcert-<ACE_INSTANCE_NAME>`. Free host ports are found by `pick_kind_hostport`; the config is rendered by `deploy/kind/render-kind-config.sh`. A cluster owned by another checkout is refused (ownership marker volume `ace-kind-owner-<name>`). The node image is resolved from the registry (`kind_node_image`). | `ensure_kind_cluster`, `assert_kind_cluster_ownership` |
| 2b | Load the locally built images into kind | `load_images_into_kind` |
| 3 | Check `kubectl` works; prepare the hub bundle (fault and chart catalogue) | `prepare_hub_bundle_for_deploy` |
| 3b | Start `prepare-images.sh` in the background | `maybe_launch_prepare_images_bg` |
| 4 | Write `deploy/helm/ace/values-env.yaml` (mode 0600) from `.env`, with image names already resolved by `scripts/lib/resolve_image_env.py` | `generate_helm_values_env` |
| 4b | Create the `ace` namespace and the CA ConfigMap | `create_ca_configmap` |
| 4c | Only when `IMAGE_REGISTRY` is set: create the image pull Secret `registry-pull` in the namespaces, and start `registry-secret-sync`, which copies it into every new namespace | `apply_registry_prereqs` → `scripts/apply_cluster_prereqs.sh`, `deploy/registry-secret-sync.yaml` |
| 5 | `helm upgrade --install ace deploy/helm/ace -f values-env.yaml --set-string imageRegistry=… imageMirrorNamespace=… aceImageTag=… imagePullSecretName=… --set aceImagesLocal=…` | `helm_cmd` |
| 5a | Restart deployments whose images were rebuilt locally; wait for core services and metrics-server | `restart_locally_built_deployments`, `wait_for_core_services` |
| 5c | Connect host services (LiteLLM, Ollama) to the cluster | inside `helm_deploy` |
| 5d | **Chaos infrastructure.** `scripts/register-chaos-infra.py` logs in, creates the `ace-local` environment and infrastructure (or reuses them), downloads the install manifest and applies it with `kubectl` (subscriber, Argo, chaos operator in `litmus`). Then setup waits until the infrastructure reports *Connected*. | `ensure_chaos_infrastructure`, `sync_subscriber_secret`, `wait_for_chaos_infrastructure` |
| 5e | Example experiments, only with `ACE_SEED_EXPERIMENTS=true` | `seed_flash_agent_*` |
| 6 | Print the UI URL and credentials | end of `helm_deploy` |

`k8s_deploy` follows the same steps but applies `deploy/k8s/*.yaml` with `kubectl`. Images are resolved first with `resolve_image_env.py --rewrite-manifests` (`apply_manifest_resolved`).

### 1.5 Files `setup.sh` reads and writes

| File | Role |
|---|---|
| `.env` | All settings and secrets (git-ignored). The single source of truth. |
| `.env.example` | Template for a new `.env` |
| `deploy/images.txt` | Inventory of every image (`build` rows = ACE builds them; `mirror` rows = third-party copies) |
| `scripts/lib/registry.sh`, `scripts/lib/resolve_image_env.py` | The image naming rule (bash and Python) |
| `deploy/helm/ace/` | Platform chart; `templates/_helpers.tpl` `ace.image` is the same rule in Helm |
| `deploy/helm/ace/values-env.yaml` | Generated from `.env` (git-ignored, 0600) |
| `deploy/kind/kind-agentcert.yaml` → `.tmp/kind-agentcert.rendered.yaml` | kind config with this checkout's ports |
| `scripts/prepare-images.sh` | Experiment images (build, load or pull) |
| `scripts/register-chaos-infra.py` | Creates `ace-local` and connects it |
| `.tmp/` | Logs, build results, rendered configs, MongoDB backups |

---

## 2. Images: where they live and how they are named

### 2.1 Two kinds of image

| Kind | Examples | Where defined | Who publishes it |
|---|---|---|---|
| **ACE images** (`build` rows) | graphql, auth, web, certifier, cluster-init, subscriber, install-app, install-agent, itbench-experiment, flash-agent, sre-agent-*, agent-sidecar, ace-hub-bundle | `deploy/images.txt` rows starting `build|`, built from this repo | `scripts/build-and-push.sh` |
| **Third-party images** (`mirror` rows) | mongo, postgres, redis, litmuschaos/*, prometheus, otel demo, golang/python/node base images, kindest/node | `deploy/images.txt` rows starting `mirror|` | `scripts/mirror-images.sh` (copies upstream → our registry) |

Everywhere in the code, an image is written by its **public name** (`mongo:5`, `agentcert/certifier:latest`). Where it is actually pulled from is decided at deploy time by one rule.

### 2.2 The naming rule

Settings in `.env`:

| Setting | Example | Meaning |
|---|---|---|
| `IMAGE_REGISTRY` | `infyartifactory.jfrog.io/docker-local` | Empty = Docker Hub |
| `IMAGE_MIRROR_NAMESPACE` | `agentcert` (default) | The folder under the registry, or the Docker Hub namespace |
| `ACE_IMAGE_TAG` | `RELEASE-1` | Release tag for ACE images; empty = their own tag (`:latest`) |

| Image in the code | `IMAGE_REGISTRY=…/docker-local` | `IMAGE_REGISTRY` empty (Docker Hub) |
|---|---|---|
| `mongo:5` | `…/docker-local/agentcert/mongo:5` | `agentcert/mongo:5` |
| `quay.io/containers/kubernetes_mcp_server:v0.0.67` | `…/docker-local/agentcert/quay.io/containers/kubernetes_mcp_server:v0.0.67` | `agentcert/containers-kubernetes_mcp_server:v0.0.67` (flat: Docker Hub cannot nest) |
| `agentcert/certifier:latest` | `…/docker-local/agentcert/certifier:latest` (`agentcert/` is not repeated) | `agentcert/certifier:latest` |
| `agentcert/certifier:latest` + `ACE_IMAGE_TAG=RELEASE-1` | `…/docker-local/agentcert/certifier:RELEASE-1` | `agentcert/certifier:RELEASE-1` |
| `mongo:5` + `ACE_IMAGE_TAG=RELEASE-1` | `…/docker-local/agentcert/mongo:5` (third-party tags never change) | `agentcert/mongo:5` |

Other cases:

- Images built locally and loaded into kind (`*_IMAGE_SOURCE=local`, `--local-build`) keep their public name and `:latest`. The registry and the release tag do not apply to them.
- `IMAGE_MIRROR_NAMESPACE=none` turns off the folder. `IMAGE_REGISTRY=…/docker-local/agentcert` also works and resolves to the same place.

The rule is implemented four times, once per language, and the copies must agree:

| Where | Function |
|---|---|
| `scripts/lib/registry.sh` | `registry_ref`, `registry_base`, `registry_join`, `image_retag`, `image_is_ace` |
| `scripts/lib/resolve_image_env.py` | `registry_ref`, `registry_base`, `registry_join`, `retag`, `is_ace_image` |
| `AgentCert/chaoscenter/graphql/server/pkg/imageref/imageref.go` | `Resolve`, `Base`, `JoinRegistry`, `WithAceTag`, `IsAceImage`. Copied into `app-charts/install-app/` and `agent-charts/install-agent/` by `scripts/lib/sync-imageref.sh` |
| `deploy/helm/ace/templates/_helpers.tpl` | `ace.image` |

Two lists are generated from `deploy/images.txt` by `scripts/lib/sync-imageref.sh`:

- **Images with a frozen copy** (`mirroredImages`)
- **ACE images** (`aceImages`, the ones `ACE_IMAGE_TAG` applies to)

They are written to `pkg/imageref/mirrored.go`, the two installer copies, and `deploy/helm/ace/templates/_mirrored.tpl`. `scripts/tests/test-registry-tooling.sh` checks that all four implementations give the same answer for every image.

---

## 3. Publishing images

Run these on a machine that can reach both the public registries and JFrog. Credentials come from `.env`:

| Target | Credentials |
|---|---|
| JFrog | `IMAGE_REGISTRY=infyartifactory.jfrog.io/docker-local`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` (JFrog identity token) |
| Docker Hub | `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in the same `.env`. When a command overrides `IMAGE_REGISTRY` to empty (`IMAGE_REGISTRY= ./scripts/…`), `registry_load` uses these instead of the JFrog credentials. |

### 3.1 ACE code changed → publish a new release

1. **Commit and push the code first.** Images are labelled with the git revision, and `--committed-only` builds exactly what is committed.
2. **Pick the next release number.** A release number is never reused (JFrog refuses to overwrite a tag, and the script will not either).
3. Run:

```bash
# JFrog: builds every ACE image from the committed code and pushes them
./scripts/build-and-push.sh --push --committed-only --tag RELEASE-2

# Docker Hub: the same images, without rebuilding
IMAGE_REGISTRY= ./scripts/build-and-push.sh --push --committed-only --reuse-local --tag RELEASE-2

# Check that every image is there (expect every image OK, 0 MISSING)
./scripts/check-registry-images.sh --kind build
IMAGE_REGISTRY= ./scripts/check-registry-images.sh --kind build
```

What `build-and-push.sh` does for each `build` row of `deploy/images.txt`:

1. It works out the source revision (git commit of the image's folder, with `-dirty` if there are uncommitted changes). With `--committed-only`, a dirty folder is exported from `HEAD` into `.tmp/build-src` and built from there; the working tree is not touched.
2. It builds with `--no-cache`. Base images come from the registry (`docker_build_resolved` turns each `ARG <NAME>_IMAGE=` in the Dockerfile into a registry name). The image gets the label `org.opencontainers.image.revision=<revision>`. With `--reuse-local`, a local image with the same label is reused instead of rebuilt.
3. With `--push`, it pushes `…/agentcert/<image>:<revision>` first, then `…/agentcert/<image>:RELEASE-2` (the name comes from `registry_ref`, which applies `ACE_IMAGE_TAG`).
   - An existing release tag is only re-pushed from the same clean commit (the script compares the image's revision label).
   - If it exists with a different build, the script reports *"already exists with a different build — use a new release number"* and fails.
4. When every image was pushed and `--only` was not used, it writes **`ACE_IMAGE_TAG=RELEASE-2` into `.env`**.

Useful options:

If package downloads time out inside Docker while they work on the Linux host,
set `ACE_BUILD_NETWORK=host` in `.env` (or export it for one run). This applies
to setup, `build-and-push.sh`, and Compose builds. The default is
`default`; runtime service networks are unchanged. Keep HTTPS and TLS
verification enabled in Dockerfiles.

| Option | Effect |
|---|---|
| `--only 'graphql\|auth'` | Rebuild only some images. `ACE_IMAGE_TAG` is then **not** written, because the other images would not have the new tag. |
| `--local` | Build only; no push (default) |
| `--push` | Explicitly publish built images |
| `--kind-load` | Build and load into the local kind cluster |
| `--allow-build-cache` | Faster rebuilds, but stale layers are possible |

### 3.2 A third-party image changed (new version, or a new image)

Third-party images are pinned. A change means a new tag, never overwriting the old one.

1. Change the reference where it is used (Helm `values.yaml`, a chart, a Dockerfile `ARG …_IMAGE=`, a fault definition).
2. Add or update the matching `mirror|…` row in `deploy/images.txt`.
3. Regenerate the lists and run the tests:
   ```bash
   ./scripts/lib/sync-imageref.sh
   ./scripts/tests/test-registry-tooling.sh
   ```
4. Copy the image into both registries. Images that are already present are skipped, so re-running is cheap.
   ```bash
   ./scripts/mirror-images.sh --dry-run                 # show what would be copied to JFrog
   ./scripts/mirror-images.sh --push                    # → …/docker-local/agentcert/<public name>
   IMAGE_REGISTRY= ./scripts/mirror-images.sh --push    # → docker.io/agentcert/<flat name>
   ./scripts/check-registry-images.sh --kind mirror   # expect 0 MISSING
   ```
5. Commit. Deployments pick the new image up on the next `setup.sh --deploy` or `--restart`.

`mirror-images.sh` pulls each upstream image for `linux/amd64`, tags it with the target name and caches it locally. `--push` explicitly publishes it. `--only REGEX`, `--jobs N` and `--force` (copy again even if present) are available.

---

## 4. How a deployment ends up on `RELEASE-N`

Everything follows from **one line in `.env`**: `ACE_IMAGE_TAG=RELEASE-N`.

- `build-and-push.sh --push --tag` writes it on the machine that published.
- On any other machine (for example Azure), set it by hand.

Then run `./scripts/setup.sh --deploy` (or `--restart`). Each part of the platform gets the tag this way:

| Part | How the tag reaches it | Code |
|---|---|---|
| Platform pods (graphql, auth, web, certifier, hub bundle, …) | `helm_deploy` passes `--set-string aceImageTag=$ACE_IMAGE_TAG`; `ace.image` swaps the tag on images listed in `ace.aceImages` | `setup.sh` `helm_cmd`, `_helpers.tpl`, `_mirrored.tpl` |
| `kubectl` deploys (`deploy/k8s`) | Manifests are rewritten with the tag before `kubectl apply` | `resolve_image_env.py --rewrite-manifests` (`apply_manifest_resolved`) |
| Image settings handed to graphql (`INSTALL_APPLICATION_IMAGE`, `INSTALL_AGENT_IMAGE`, `SUBSCRIBER_IMAGE`, `FLASH_AGENT_IMAGE`, `AGENT_SIDECAR_IMAGE`, …) | Resolved with the tag and written into `values-env.yaml` (the `ace-env` Secret) | `resolve_image_env.py resolve()`, `generate_helm_values_env` |
| graphql itself | Reads `ACE_IMAGE_TAG` from its environment (`imageref.FromEnv`) | `pkg/imageref/imageref.go` |
| Experiment workflows (install-app, install-agent, itbench-experiment, helper steps) | When a run starts, graphql rewrites every image in the workflow | `ops/registry_images.go` `ApplyRegistryImageOverrides`, `WorkflowImage` |
| App and agent charts installed by an experiment (flash-agent, sidecar, …) | graphql passes `ACE_IMAGE_TAG` to the installer pod (`installerImageEnv`); the installer runs Helm with itself as post-renderer and rewrites the chart's images | `install-app/registry.go`, `install-agent/registry.go`, `imageref.PostRender` |
| Agents installed directly from the UI | graphql's own post-renderer | `agent_registry/helm.go` → `imageref.HelmPostRenderer` |
| Chaos infrastructure (subscriber) | `SUBSCRIBER_IMAGE` resolved as above, placed into the infra manifest | `chaos_infrastructure/infra_utils.go` |
| Docker Compose | `ACE_IMG_*` variables resolved per image | `compose_image_env` in `registry.sh` |

### What keeps this safe

- **A tag means one build.** Release tags are never overwritten. A deployment on `RELEASE-2` keeps running that exact build until someone changes `ACE_IMAGE_TAG`.
- **New tag, new pull.** A new tag is a new image name, so Kubernetes pulls it even with `imagePullPolicy: IfNotPresent`. Pods never keep a cached old `:latest` by mistake.
- **`.env` is only updated after a complete push.** `ACE_IMAGE_TAG` is not written after a failed or partial (`--only`) push.
- **Check before deploying.** `check-registry-images.sh --kind build` shows `OK` / `OLD` / `MISSING` for every ACE image under the current `ACE_IMAGE_TAG`, using the revision label. Run it before setting the tag on another machine. A missing tag shows up in the cluster as `ImagePullBackOff`.
- **Local builds are unaffected.** Images built and loaded locally always keep `:latest`.
- **Rolling back** means setting `ACE_IMAGE_TAG` to the previous release and running `./scripts/setup.sh --restart`.

### Release checklist

```bash
git push                                   # 1. code committed and pushed
./scripts/build-and-push.sh --push --committed-only --tag RELEASE-N        # 2. JFrog
IMAGE_REGISTRY= ./scripts/build-and-push.sh --push --committed-only --reuse-local --tag RELEASE-N   # 3. Docker Hub
./scripts/check-registry-images.sh --kind build                     # 4. every build row OK
# 5. on each deployment: ACE_IMAGE_TAG=RELEASE-N in .env, then
./scripts/setup.sh --restart
# 6. confirm
kubectl get pods -n ace -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```

For a deployment that pulls everything from the registry, these must be `registry` in `.env`:

- `INSTALL_APP_IMAGE_SOURCE`
- `INSTALL_AGENT_IMAGE_SOURCE`
- `LITMUS_IMAGES_SOURCE`
- `SRE_AGENTS_IMAGE_SOURCE`
- `ITBENCH_EXPERIMENT_IMAGE_SOURCE`
- `HUB_BUNDLE_IMAGE_SOURCE`

`PLATFORM_IMAGE_SOURCE` must be `skip` (answer **n** to "Build images?"). Any of them left on `local` is built locally and keeps `:latest`.
