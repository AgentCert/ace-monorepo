# Verified Docker Hub images — 16 October 2026

Completed: 2026-10-16T13:21:15+05:30 (India time).

All **14 project-owned images** built, pushed and verified. Each image has its standard inventory tag and the shared tag **`verified-20261016-131714`**. Docker Hub digests match the local images used by the runtime checks.

Validation: **143 registry/tooling checks** and **28 runtime checks** passed. All images target **linux/amd64**.

| Image | Standard tag | Verified digest |
|---|---|---|
| `agentcert/agentcert-graphql` | `latest` | `sha256:9c4c73a14ab76be27dc7e317a88f97298f7caf29b0bc1538e1dab53e5aea095a` |
| `agentcert/agentcert-auth` | `latest` | `sha256:2aa661ffa78522b910dffabf342fe11e5ed701c4bcbfb03c8698c78bdecf67f9` |
| `agentcert/agentcert-web` | `latest` | `sha256:02bad512b2dab17df748777f73851c80517c1135f4c27e556f61e4687a354fb5` |
| `agentcert/certifier` | `latest` | `sha256:46bf98e1e309cbf5b93110c6c99e5f03f02df1876ffa7fafc5691f0a9133ee3e` |
| `agentcert/ace-hub-bundle` | `latest` | `sha256:7d2296ce1d653573b3a947fa642c789a1e641a9f0ffcda2d330af2ea47d3b9a8` |
| `agentcert/cluster-init` | `latest` | `sha256:6e4f17d4fbbcab4697e99d119a67bf38b4d4a0fbb338f24cfa202897f82f715d` |
| `agentcert/litmusportal-subscriber` | `3.0.0` | `sha256:3b5efdaf177f13cf339d6363b1fc31cca5545ead9cccb8d9e4f0e750abd5e255` |
| `agentcert/agentcert-install-app` | `latest` | `sha256:2acf49be53d9b6a5ed57bb4456302a39f20f8afa2c93000589d691219d861080` |
| `agentcert/agentcert-install-agent` | `latest` | `sha256:ec14102c3b5a65500ba6f9cce8f61724d1c7177d8b8860700e9747ecd9d0bef1` |
| `agentcert/itbench-experiment` | `dev` | `sha256:246a229a15bd431f701034735a34db0b95eea8f4668fe3e3a45d837ee5fe5c9c` |
| `agentcert/agentcert-flash-agent` | `latest` | `sha256:3b0c1283f875e7b4266d2ee476ce44e74c28adfc8063aa8e7fcac6f38e3b9a89` |
| `agentcert/sre-agent-comprehensive` | `latest` | `sha256:25603b9eb6c74ecb0ffebd244f6a4e0ae783aef933a68c20b0d4381c4629443f` |
| `agentcert/sre-agent-crewai` | `latest` | `sha256:03da9a614aae27f2ef4e1169f5d77de7ce2d74fceada104ce782032c31e486f1` |
| `agentcert/agent-sidecar` | `latest` | `sha256:ed2ca80f294ad63a25152d90ed24a060eadf22a9b40e4ba0ff76d17fb93dd674` |

Use the shared tag above for a consistent release, or the verified digests in the table to pin the exact tested content.

## Fixes

- Added `ACE_BUILD_NETWORK` to the common Docker build helper and all Compose builds. On the build host the default Docker network timed out while the same HTTPS download succeeded with host networking, so the release was built with `ACE_BUILD_NETWORK=host`.
- Restored HTTPS and TLS verification in the install-app Dockerfile and removed its duplicate build-package install.
- Included the web nginx configuration and exposed its configured port, 8185. Compose supplies its own configuration for port 2001. (Superseded later: every deployment mounts its own nginx configuration, so the web image no longer bakes one in and exposes 2001.)
- Added registry-resolved base-image arguments to the itbench Dockerfile.
- Made generated image-map sorting independent of the machine locale and regenerated the maps.

## Validation scope

Runtime checks covered installer help and bundled tools; Python dependency integrity; SRE CLI startup; Flash imports and missing-configuration rejection; subscriber missing-configuration rejection; itbench help; bundled catalogs; cluster-init CLI availability; sidecar HTTP forwarding; Chromium PDF rendering; auth and GraphQL HTTP status with an isolated MongoDB replica set; certifier OpenAPI; and web HTML, health and auth/GraphQL proxy routes.

The Kubernetes subscriber, cluster provisioner, chaos faults and LLM agents require their external services for full workflow validation. No live Kubernetes deployment or chaos experiment was performed.

Images include the current working tree, including existing uncommitted work. Source revision labels ending in `-dirty` identify those contexts; the digest references identify exact image content.

## Evidence

Build and push logs, test harnesses, the digest lock and the registry regression output were captured locally on the build host; they are not checked in.

Repeat the standard-tag build and push:

```bash
IMAGE_REGISTRY= ACE_IMAGE_TAG= ./scripts/build-and-push.sh --push --committed-only
```

Caution: this overwrites the public Docker Hub `:latest` tag of every ACE image; run it only from a commit you intend to publish. `ACE_BUILD_NETWORK` is read from `.env` when set.
