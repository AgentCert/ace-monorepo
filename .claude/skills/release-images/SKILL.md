---
name: release-images
description: Build and push all ACE component Docker images to Docker Hub via scripts/build-and-push.sh, confirm the five images pushed, and report the new certifier:latest digest. Use to publish a new release of the images.
---

# release-images

Publish the monorepo's Docker images to `docker.io/agentcert/*`.

## Prerequisites

- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` set in the root `.env`.
- Docker logged in / able to push to the `agentcert` org.

## Steps

1. **Build and push:**
   ```bash
   ./scripts/build-and-push.sh
   # or with a custom env file:
   ./scripts/build-and-push.sh --env-file /path/to/.env
   ```
2. **Confirm all five images pushed:**
   - `agentcert/agentcert-flash-agent:latest`
   - `agentcert/agent-sidecar:latest`
   - `agentcert/agentcert-install-agent:latest`
   - `agentcert/agentcert-install-app:latest`
   - `agentcert/certifier:latest`
3. **Capture the new certifier digest** so the README reference stays accurate:
   ```bash
   docker inspect --format='{{index .RepoDigests 0}}' agentcert/certifier:latest
   ```
4. **Offer to update the README** "Latest digest" line under *Certifier API service (Dockerized)* if it changed.

## Notes

- This is an Admin Action — confirm with the user before pushing (it publishes to a public registry).
- Pull-mode consumers fetch via `./scripts/start-local-services.sh --only-certifier --pull-certifier`.
