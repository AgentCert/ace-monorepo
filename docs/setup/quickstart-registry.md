---
title: "Quick start: inside or outside the Infosys network"
parent: "Setup"
nav_order: 1
---

# Quick start: inside or outside the Infosys network

One setting in `.env` decides where every container image comes from:

| You are… | `IMAGE_REGISTRY` | Images come from |
|---|---|---|
| **Outside Infosys** (open source) | *(empty)* | Docker Hub: ACE's own images, plus frozen copies of third-party images under `agentcert/`. No login. |
| **Inside Infosys** | `infyartifactory.jfrog.io/docker-local` | JFrog Artifactory. Needs your JFrog username and an access token. |

Nothing else changes between the two.

**You need:** Docker, git, kind, kubectl, helm and python3. `setup.sh` checks them first and tells you how to install anything missing. You also need an Azure OpenAI key for the agent's LLM calls.

---

## Outside the Infosys network

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
./scripts/setup.sh
```

At the **Image registry** question, press **Enter** to leave it empty. Answer the Azure OpenAI questions. That's it.

---

## Inside the Infosys network

1. **Clone.** Use your usual Infosys Git access.
   ```bash
   git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
   cd ace-monorepo
   ```
2. **Check that JFrog has every image.** Optional, takes about a minute, and every line should say `OK`:
   ```bash
   cp .env.example .env
   # edit .env: IMAGE_REGISTRY=infyartifactory.jfrog.io/docker-local
   #            REGISTRY_USERNAME=<your Infosys id>   REGISTRY_PASSWORD=<JFrog access token>
   ./scripts/check-registry-images.sh
   ```
3. **Run setup.**
   ```bash
   ./scripts/setup.sh
   ```
   At **Image registry**, enter `infyartifactory.jfrog.io/docker-local`, then your JFrog username and access token. If your machine sits behind the corporate proxy (Zscaler), give the path of the corporate CA certificate when asked.

`setup.sh` then logs in to JFrog, puts the login into the cluster (`scripts/apply_cluster_prereqs.sh`), and deploys. Every image the cluster pulls comes from JFrog.

> Use the **Helm** deploy option (the default). For a JFrog access token: JFrog UI → your profile → *Generate an Identity Token*.

---

## Check that it worked

Run these after setup and after your first experiment.

```bash
# Inside Infosys: every image actually pulled must come from JFrog (prints nothing when correct)
kubectl get events -A -o jsonpath='{range .items[?(@.reason=="Pulling")]}{.message}{"\n"}{end}' \
  | grep -v 'infyartifactory.jfrog.io/docker-local/'

# Either network: no pull errors (prints nothing when correct)
kubectl get events -A | grep -E 'ErrImagePull|ImagePullBackOff|401|unauthorized'
```

---

## Switching networks later

Edit `IMAGE_REGISTRY` in `.env`, then run `./scripts/setup.sh --restart`. Set it empty to use public images, or to the JFrog value to use JFrog.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| `401` / `unauthorized` when pulling | Token expired or wrong: update `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` in `.env`, then run `./scripts/apply_cluster_prereqs.sh` |
| `ImagePullBackOff`, `not found` | The image is missing from the registry: `./scripts/check-registry-images.sh` lists what's missing. Ask a maintainer to publish it (below) |
| `x509: certificate signed by unknown authority` | Corporate proxy: set `CUSTOM_CA_CERT_PATH=<corporate CA .crt>` in `.env`, then run `./scripts/setup.sh --restart` |

---

## For maintainers: publishing images

All images are listed once, in `deploy/images.txt`.

```bash
# third-party images (copied as-is, skips what is already there)
./scripts/mirror-images.sh                 # into JFrog (IMAGE_REGISTRY from .env)
IMAGE_REGISTRY= ./scripts/mirror-images.sh # into the frozen Docker Hub copies (agentcert/)

# ACE's own images, built from the committed code
./scripts/build-and-push.sh --committed-only --reuse-local                 # JFrog
IMAGE_REGISTRY= ./scripts/build-and-push.sh --committed-only --reuse-local # Docker Hub

# verify both, and refresh the link lists
./scripts/check-registry-images.sh --markdown docs/setup/registry-images.md
IMAGE_REGISTRY= ./scripts/check-registry-images.sh --markdown docs/setup/registry-images-dockerhub.md
```

To add an image, add a line to `deploy/images.txt` and run the commands above. For how it all works, see [registry-migration-plan.md](registry-migration-plan.md).
