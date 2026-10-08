# Running ACE inside and outside the Infosys network: image registry plan

## 1. problem

ACE runs about 90 container images: our own, Litmus, Langfuse, Mongo, the demo apps and the build base images. Today they are pulled from public registries such as Docker Hub, quay.io, ghcr.io and registry.k8s.io.

- **Inside the Infosys network**, public registries are blocked. Every image has to come from **JFrog Artifactory** (`infyartifactory.jfrog.io/docker-local`), and pulling needs a login.
- **Outside the network** (open source), people have no JFrog access. Everything has to come from the public registries, with no login.

## 2. The goal : let .ENV be the Single Source of Truth

> One setting in `.env` decides where every image comes from.

```bash
# Outside Infosys (default): leave it empty → images come from their normal public home
IMAGE_REGISTRY=

# Inside Infosys: set it → every image comes from JFrog
IMAGE_REGISTRY=infyartifactory.jfrog.io/docker-local
REGISTRY_USERNAME=<your id>
REGISTRY_PASSWORD=<JFrog token>
IMAGE_PULL_SECRET_NAME=registry-pull
```
Nothing else should have to change between the two setups.

### The naming rule

| Setting | `mongo:5` becomes | `quay.io/containers/kubernetes_mcp_server:v0.0.67` becomes |
|---|---|---|
| `IMAGE_REGISTRY` empty | `agentcert/mongo:5` (frozen copy on Docker Hub) | `agentcert/containers-kubernetes_mcp_server:v0.0.67` (frozen copy on Docker Hub) |
| `IMAGE_REGISTRY` set | `infyartifactory.jfrog.io/docker-local/mongo:5` | `infyartifactory.jfrog.io/docker-local/quay.io/containers/kubernetes_mcp_server:v0.0.67` |

In other words: if the setting is set, put it **in front of the normal name**. If it is empty, use ACE's **frozen copy on Docker Hub** (`IMAGE_MIRROR_NAMESPACE`, default `agentcert`). Docker Hub repos can't nest, so the copy's name drops the registry host and turns `/` into `-`. ACE's own `agentcert/*` images keep their names. `IMAGE_MIRROR_NAMESPACE=none` pulls straight from upstream.

**Why frozen copies for open source too:** third-party tags such as `grafana/grafana:latest` or `prometheus-mcp-server:latest` move, and upstream images get archived or deleted. Copying each image once into `agentcert/` pins exactly the version ACE was tested with, for both networks (JFrog copies are frozen the same way).

**Why this rule:**
- **Empty, not `docker.io`.** If the default were `docker.io`, images that live elsewhere would break for open-source users. For example, `docker.io/containers/kubernetes_mcp_server` does not exist.


## 3. How the pieces fit (read this first)

Images get pulled at **three different moments**, by **three different parts** of the system. Each part needs to know the registry, and each needs the login.

```
 ┌──────────── .env (IMAGE_REGISTRY, credentials) ────────────┐
 │                                                            │
 ▼ (1) BUILD time            ▼ (2) DEPLOY time           ▼ (3) EXPERIMENT time
 build-and-push.sh           setup.sh → Helm "ace"       graphql server (Go) creates:
 Dockerfiles (FROM …)        installs the platform:        • chaos infra (Litmus, Argo, MCP)
 → pushes our images         graphql, auth, web,           • workflow → install-app → app-charts
   to the registry           certifier, mongo,               (sock-shop, bookinfo, otel-demo)
                             langfuse, litellm             • workflow → install-agent → agent-charts
                                                             (flash-agent, sre-agents + sidecar)
                                                           • fault pods (chaos-charts)
```


## 4. Where we stand today 

90 images were checked with `check-jfrog-images.sh`:

| Result | Count | Examples |
|---|---|---|
| ✅ Present with the right tag | 64 | mongo, postgres, redis, langfuse, litellm, metrics-server, all Litmus infra and helpers, sock-shop |
| ⚠️ Repo present, **wrong tag** | 12 | `clickhouse-server:26.8` (only `latest`), `kubernetes_mcp_server:v0.0.67` (only `latest`), `alpine/k8s:1.29.2`, `curl:8.10.1`, `node:20-alpine`, `ollama` |
| ❌ Missing | 14 | `ace-hub-bundle`, `itbench-experiment`, `sre-agent*`, `ciso-agent`, 6 bookinfo images (`registry.istio.io`), `ubi10-minimal`, `distroless`, `kindest/node` |
| 🕒 Present but **old** | all `agentcert/*` | old images |

Gaps in the code today:
- The Helm chart has no registry setting and no pull secret.
- `apply_cluster_prereqs.sh` exists, but `setup.sh` never calls it. It also references a file that doesn't exist (`deploy/jfrog-secret-sync.yaml`).
- Two different secret names are used: `jfrog-registry` and `jfrog-pull-secret`.
- The Go server, app-charts, agent-charts and chaos-charts have no way to add a registry or a pull secret.
  - The only exceptions are install-app/install-agent and a Litmus-helper-only prefix.

---

## 5. The phases

Each phase lists **what** changes and **why** it is done that way.

### Phase 0: Fill JFrog with every image

**What**
1. **`deploy/images.txt`:** one list of every image ACE needs, grouped by platform, infra, workflow, agents, apps and build.
2. **`scripts/check-registry-images.sh`:** reports OK / wrong tag / missing for every image in the list. This is the script used for section 4.
3. **`scripts/mirror-images.sh`:** for **third-party** images (mongo, litmus, langfuse, bookinfo, …).
   - Runs on a machine that can reach the internet.
   - Pulls each image from its public home, renames it with the rule from section 2, and pushes it to JFrog.
   - Skips images that are already there.
4. **`scripts/build-and-push.sh` (improved):** for **our own** images (`agentcert/*`).
   - Builds them from this branch and pushes them to `IMAGE_REGISTRY` instead of always to Docker Hub.
   - Pushes `latest` **and** a fixed tag such as the git commit.
   - Covers images that were never pushed: `ace-hub-bundle`, `itbench-experiment`, `sre-agent*`, `ciso-agent`.

   > **what pushes future changes?** Yes. After this phase, running `build-and-push.sh` with `IMAGE_REGISTRY` set pushes new builds to JFrog. With it empty, they go to Docker Hub as today.

**Why**
- **Every later phase only switches image names to JFrog.** If an image isn't there, the pod fails with `ImagePullBackOff`. Filling JFrog first means later failures point at the code, not at missing images.
- **Two scripts, not one.** Our images are *built* from source; third-party images are *copied*. Mixing them would rebuild things we don't own, or copy stale copies of things we do.
- **For wrong-tag images, choose per image:** push the tag we use, or change our files to a tag JFrog already has. Pushing is preferred so the open-source and Infosys setups run the same versions.

### Phase 1: `.env` becomes the single source

**What**
- Add `IMAGE_REGISTRY` (empty by default), `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` and `IMAGE_PULL_SECRET_NAME=registry-pull`.
- **Remove:**
  - `JFROG_HOST`, `JFROG_REGISTRY_PATH`, `JFROG_USER`, `JFROG_TOKEN`
  - `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
  - `LITMUS_HELPER_IMAGES_REGISTRY_PREFIX`

  These are all replaced by the settings above.
- Every `*_IMAGE` value holds the **normal public name** (e.g. `litmuschaos/chaos-operator:3.0.0`), never a JFrog name. The prefix is added later, automatically.
- `*_IMAGE_SOURCE` drops `jfrog | dockerhub | local` and becomes `local | registry`. `registry` means "pull from wherever `IMAGE_REGISTRY` points".

**Why**
- Today the registry is spread over about eight settings, and changing networks means editing many lines. A single setting can't drift out of sync.

### Phase 2: Cluster preparation (`apply_cluster_prereqs.sh`)

**What it does.** It doesn't fetch images. It gives the cluster the **login** and the **corporate certificate**:
1. Creates the pull secret, holding the JFrog username and token, in every namespace that runs our pods: `ace`, `litmus`, `kube-system`, `sock-shop`, `book-info`, `otel-demo`, `itbench`, `litellm`.
2. Attaches the secret to the service accounts in those namespaces, so pods use it automatically.
3. The corporate (Zscaler) root certificate is **not** handled here: `setup.sh`'s `create_ca_configmap` already creates the `ace-ca-certs` ConfigMap graphql mounts, so a second ConfigMap would duplicate it.
4. Installs `deploy/registry-secret-sync.yaml`, which copies the secret into **any new namespace** within seconds and attaches it to every ServiceAccount. Experiments create namespaces on the fly. Namespaces labelled `ace.registry-sync=disabled` are left alone.

**Changes**
- `setup.sh` runs it **only when `IMAGE_REGISTRY` is set**.
- One secret name everywhere (`IMAGE_PULL_SECRET_NAME`), including in `prepare-images.sh`.
- Remove its built-in JFrog default, and stop it from editing `.env`.
- Add the missing sync manifest (`deploy/registry-secret-sync.yaml`, vendor-neutral name). Its kubectl image is `alpine/k8s:1.29.2`, already in `images.txt`.
- Switching `IMAGE_REGISTRY` back to empty removes the sync (`apply_cluster_prereqs.sh --uninstall`).

**Why**
- Pointing an image name at JFrog is only half the job. Without the login, JFrog refuses the pull with `401`.
- Running it only when the setting is set means open-source users never see a JFrog prompt.
- One secret name: today one script creates `jfrog-registry` and another creates `jfrog-pull-secret`, so pods look for a secret that isn't there.
- The sync is needed because experiment namespaces don't exist at setup time, so a one-off script can't cover them.

### Phase 3: Helm chart `ace` (deploy time, the platform)

**What it is:** see section 3. It is the package `setup.sh` installs for graphql, auth, web, certifier, mongo, langfuse and litellm. It runs **once, during `setup.sh`**.

**What changes**
- `values.yaml` gets `imageRegistry: ""` and `imagePullSecretName: ""`.
- A small template helper, `ace.image`, adds the prefix to each image only when `imageRegistry` is set. Every `image:` line uses it.
- Every pod gets `imagePullSecrets`, but only when a secret name is set.
- `setup.sh` passes both values from `.env` into Helm.
- The image-drift check in `setup.sh` (`deploy/image-baseline.tsv`) is updated so it still recognises the prefixed names.

**As built:** images `setup.sh` builds or side-loads keep their public names (`aceImagesLocal` for graphql/auth/web/certifier with `PLATFORM_IMAGE_SOURCE=local`, `chartsHub.bundleLocal`, `runtimeImagesLocal` for metrics-server). Otherwise kubelet would silently pull an older registry copy instead of the fresh local build. The drift check keys each image by the name the cluster actually pulls.

**Why**
- The image names stay readable in `values.yaml`, the prefix is decided in one place, and an empty value gives exactly today's behaviour.
- This replaces main's approach of writing JFrog names into `values.yaml`.

### Phase 4: The graphql server (Go, experiment time)

This is the largest phase, because **most pods are created by graphql while an experiment runs**, not by `setup.sh`.

**What changes**
1. graphql reads `IMAGE_REGISTRY` and `IMAGE_PULL_SECRET_NAME`.
2. **Chaos infra** (subscriber, event-tracker, chaos operator, Argo, MCP servers): graphql writes these manifests itself. It adds the prefix and an `imagePullSecrets` entry.
3. **One rewrite step when a workflow is submitted.** It extends the existing `ApplyLitmusHelperImageOverrides` function, which today only handles Litmus helper images. It must cover:
   - every container image in the workflow,
   - images inside the fault definitions,
   - image values passed as settings (`TC_IMAGE`, `DEBUG_IMAGE`, `GENERATOR_IMAGE`, …).
4. It **must not** rewrite `INVALID_IMAGE` and `INVALID_ARCH_IMAGE`. Those faults deliberately use a broken image.
5. It passes the registry on to install-app (app-charts) and install-agent (agent-charts and the sidecar).
6. Fix an existing bug: a custom `AGENT_SIDECAR_IMAGE` currently gets `docker.io/` stuck in front of it.
7. Send images hardcoded in Go (`litmuschaos/k8s`, `busybox`) through the same rewrite.

**As built:** the rule lives in a new package, `pkg/imageref`. `ApplyRegistryImageOverrides` runs next to `ApplyLitmusHelperImageOverrides` at all four submit points and also adds the workflow's `imagePullSecrets`. Infra manifests get an `#{IMAGE_PULL_SECRETS}` placeholder, which stays a YAML comment on the public path. The sidecar fix splits a registry host into `sidecar.image.registry`, which also renders correctly with older agent charts. Settings reach the installers as environment variables rather than flags, so an older installer image ignores them instead of failing. Components set to `local` in `.env` keep their side-loaded public names.

**Why**
- **Rewrite at run time instead of editing 64 fault files.**
  - The fault files are packed into one "hub bundle" image built from this branch.
  - If they contained JFrog names, there would need to be a separate bundle for each network, and open-source users would get JFrog names. That is what happened on main, where `fault.yaml` files were rewritten with `sed`.
  - With the rewrite, the files stay public and graphql adds the prefix only when it is set.
- **Reusing the existing function** extends tested code instead of adding a second mechanism.

### Phase 5: app-charts and agent-charts (experiment time)

- **app-charts** install the demo app that gets broken on purpose (sock-shop, bookinfo, otel-demo).
- **agent-charts** install the AI agent that has to detect and fix the breakage.

Both are installed **inside the cluster during an experiment**, by the `install-app` and `install-agent` pods that graphql starts.

**What changes**
- **app-charts:**
  - Add a `global.imageRegistry` setting, an image helper and `imagePullSecrets`. This mirrors Phase 3.
  - For otel-demo, use the upstream subchart's own registry and pull-secret settings.
- **agent-charts:**
  - They already have a `registry:` setting, but it always adds a `/`, so an empty value gives `/agentcert/...`, which is invalid. Add a guard.
  - Add `imagePullSecrets`.
  - Turn the fixed `litellm/deployment.yaml` into a template.
- **install-app and install-agent** copy the pull secret into the target namespace before running `helm install`.

**As built (deviation):** image rewriting is done by a Helm **post-renderer** built into `install-app`, `install-agent` and graphql (direct agent installs and uploaded charts), not by template helpers in each app chart. The otel-demo upstream subchart takes images from five settings and hardcodes `busybox:latest` init containers inside value lists, which no chart setting can reach. The post-renderer rewrites every rendered `image:`, adds `imagePullSecrets` to every pod, and needs no new Go dependency. The agent charts additionally got the empty-registry guard and an `imagePullSecrets` value. `agent-charts/litellm/deployment.yaml` is only a manual local-dev manifest (the platform LiteLLM comes from the Helm chart), so it moves to Phase 6. The installers carry a generated copy of `pkg/imageref` (`scripts/lib/sync-imageref.sh`; the test suite fails if a copy drifts).

**Why**
- These charts start about 30 images: the sock-shop services, bookinfo, Prometheus, Grafana and the agents. If they keep public names, experiments fail inside Infosys even when the platform is healthy.
- Copying the secret just before install closes a timing gap: the namespace is brand new, and the sync from Phase 2 may not have reached it yet.

### Phase 6: Builds, compose and the rest

**What changes**
- Every Dockerfile gets `ARG REGISTRY_PREFIX=` (empty by default), used as `FROM ${REGISTRY_PREFIX}golang:1.24`. `build-and-push.sh` passes `IMAGE_REGISTRY/`.
- Add a `KIND_NODE_IMAGE` setting. This only matters for local kind clusters; AKS doesn't use it.
- The docker-compose files use `${IMAGE_REGISTRY:+${IMAGE_REGISTRY}/}mongo:5`. That form adds the prefix and the `/` only when the setting is set.
- Delete the old flat manifests in `deploy/k8s/*.yaml` (Helm replaces them), or render them with `envsubst`.

**Why**
- Building **inside** Infosys also pulls base images (`golang`, `python`, `node`, `ubi`), which are blocked.
- An **empty** default keeps every Dockerfile working on its own for open-source users.
- Plain `${IMAGE_REGISTRY}/mongo:5` breaks when the setting is empty, because it becomes `/mongo:5`. Hence the `:+` form.

### Phase 7: Merge to main

**What**
1. Merge each submodule first (AgentCert, app-charts, agent-charts, chaos-charts, certifier, litmus-go, agent-sidecar), each on its own branch.
2. Then merge the monorepo, updating the submodule pointers.
3. **Do not** bring over main's JFrog-hardcoded values or its `sed`-edited `fault.yaml` files.


---

## 6. Proof ->

The test that matters is: **with `IMAGE_REGISTRY` set, does any pod still try to pull from outside JFrog?** And with it empty: **does anything mention JFrog?**

### Test 1: Before deploying (fast, no cluster)

| Check | How | Pass |
|---|---|---|
| Registry is complete | `scripts/check-registry-images.sh` | Every line `OK` |
| Helm output, set | `helm template ace deploy/helm/ace --set imageRegistry=infyartifactory.jfrog.io/docker-local --set imagePullSecretName=registry-pull \| grep 'image:'` | Every image starts with the JFrog prefix, and every pod has `imagePullSecrets` |
| Helm output, empty | The same command without the `--set` flags | No `jfrog` anywhere; output identical to today |
| Go rewrite | Unit tests on the rewrite function, fed real workflow and fault YAML | Every image prefixed except `INVALID_IMAGE` and `INVALID_ARCH_IMAGE` |
| app/agent charts | `helm template` each chart with and without the registry setting | As for the Helm checks above; no `//` or leading `/` in any image |

### Test 2: Inside Infosys, the real proof (fresh AKS or VM cluster)

1. **Use a brand-new cluster.** Kubernetes caches images on its nodes. On an old cluster, a pod could start from a cached public image, and the test would pass while the real setup is broken.
2. Set `IMAGE_REGISTRY` and the credentials, then run `./scripts/setup.sh`.
3. Run **one experiment of each kind**:
   - sock-shop + flash-agent + pod-delete
   - bookinfo + an sre-agent + network latency
   - one itbench fault
   - then generate a certificate
4. Run the **image audit**. It lists every image every pod actually used:
   ```bash
   kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{range .spec.initContainers[*]}{.image}{" "}{end}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' \
     | tr ' ' '\n' | grep -v '^$' | grep -v '^infyartifactory.jfrog.io/docker-local/' | sort -u
   ```
   **Pass:** the output is empty, apart from `kube-system` cluster add-ons owned by AKS and the deliberately invalid fault images.
5. **Check for pull errors:**
   ```bash
   kubectl get events -A | grep -E 'ErrImagePull|ImagePullBackOff|401|unauthorized'
   ```
   **Pass:** none.

### Test 3: Outside Infosys (open-source path)

1. On a machine outside the network (a personal laptop or a GitHub Actions runner), clone, leave `IMAGE_REGISTRY` empty and run `./scripts/setup.sh` on a fresh kind cluster.
2. Run the same experiments.
3. **Pass:**
   - No JFrog prompt.
   - `grep -ri jfrog` over the rendered values and the running pod specs finds nothing.
   - Every experiment completes.

### Test 4: Switching back and forth

On the Infosys cluster, switch `IMAGE_REGISTRY` from set to empty, re-run `setup.sh --restart`, then switch it back.

**Pass:**
- Each switch changes only image names and pull secrets, with no manual edits.
- The image audit flips as expected.

### Rollout tip

Run Test 1 at the end of every phase, and Tests 2 and 3 once Phase 5 is done. Phases 3–5 can be shipped one at a time: the image audit shows which pods are still on public names, which is effectively a progress bar.

