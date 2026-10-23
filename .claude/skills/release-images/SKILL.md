---
name: release-images
description: Build and push all ACE component Docker images to Docker Hub via scripts/build-and-push.sh --push, confirm every image pushed, and report the new certifier:latest digest. Use to publish a new release of the images.
---

# release-images

Publish the monorepo's Docker images to `docker.io/agentcert/*`.

## Prerequisites

- `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` set in the root `.env` (Docker Hub credentials when `IMAGE_REGISTRY` is empty; the target registry's otherwise).
- Docker logged in / able to push to the `agentcert` org.

## Steps

1. **Build and push** (without `--push` the script only builds locally; `--committed-only` builds exactly what is committed):
   ```bash
   ./scripts/build-and-push.sh --push --committed-only
   # or with a custom env file:
   ./scripts/build-and-push.sh --push --committed-only --env-file /path/to/.env
   ```
   For a named release add `--tag RELEASE-N` with a new number (see `docs/setup/setup-and-image-releases.md` §3.1).
2. **Confirm every image pushed** (one per `build` row of `deploy/images.txt`):
   ```bash
   ./scripts/check-registry-images.sh --kind build   # expect 0 MISSING
   ```
3. **Capture the new certifier digest** so the README reference stays accurate:
   ```bash
   docker inspect --format='{{index .RepoDigests 0}}' agentcert/certifier:latest
   ```
4. **Offer to update the README** "Latest digest" line under *Certifier API service (Dockerized)* if it changed.

## Notes

- This is an Admin Action — confirm with the user before pushing (it publishes to a public registry).
- Pull-mode consumers fetch via `./scripts/start-local-services.sh --deploy --only-certifier --pull-certifier`.
