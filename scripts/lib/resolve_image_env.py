#!/usr/bin/env python3
"""Resolve the image settings in .env into the values the cluster should use.

.env holds every image under its normal public name (e.g.
``litmuschaos/chaos-operator:3.0.0``) plus one registry setting,
``IMAGE_REGISTRY``. This script prints ``KEY=VALUE`` overrides that put the
registry in front of each image whose component pulls from the registry, so
the deploy step (setup.sh: Helm values-env.yaml and the kubectl ace-env Secret)
hands graphql the right references. .env itself is never modified.

Rules (same naming rule as scripts/lib/registry.sh):
  * IMAGE_REGISTRY empty      -> the frozen Docker Hub copy,
                                 <IMAGE_MIRROR_NAMESPACE>/<flat name> (default
                                 agentcert/; IMAGE_MIRROR_NAMESPACE=none keeps
                                 the upstream name).
  * component source=local    -> unchanged (setup side-loads the public name
                                 into the cluster; the node must find it there).
  * component source=registry -> <IMAGE_REGISTRY>/<public name>.

It also derives LITMUS_HELPER_IMAGES_REGISTRY_PREFIX, which graphql uses to
rewrite Litmus helper images at workflow submit:
  registry source + IMAGE_REGISTRY set -> "<IMAGE_REGISTRY>/"
  otherwise                             -> "docker.io" (the KinD cache / Docker Hub name)

Legacy source values "jfrog" and "dockerhub" are treated as "registry".

Usage:  resolve_image_env.py ENV_FILE            print overrides
        resolve_image_env.py ENV_FILE --explain  also print why, to stderr
        resolve_image_env.py --rewrite-manifests ENV_FILE [--keep-ace-images] [--keep IMAGE]...
            stdin -> stdout: resolve every image in plain Kubernetes YAML and add
            the pull secret (for deploy/k8s and other kubectl-applied files)
"""
import re
import sys

# image key -> the *_SOURCE key that decides where that image comes from
IMAGE_SOURCES = {
    "INSTALL_APPLICATION_IMAGE": "INSTALL_APP_IMAGE_SOURCE",
    "INSTALL_AGENT_IMAGE": "INSTALL_AGENT_IMAGE_SOURCE",
    "FLASH_AGENT_IMAGE": "SRE_AGENTS_IMAGE_SOURCE",
    "AGENT_SIDECAR_IMAGE": "SRE_AGENTS_IMAGE_SOURCE",
    # Chaos infrastructure images are prepared together with the Litmus
    # runtime images (scripts/prepare-images.sh, LITMUS_IMAGES_SOURCE).
    "SUBSCRIBER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "EVENT_TRACKER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "ARGO_WORKFLOW_CONTROLLER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "ARGO_WORKFLOW_EXECUTOR_IMAGE": "LITMUS_IMAGES_SOURCE",
    "CHAOS_OPERATOR_IMAGE": "LITMUS_IMAGES_SOURCE",
    "CHAOS_RUNNER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "CHAOS_EXPORTER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "KUBERNETES_MCP_SERVER_IMAGE": "LITMUS_IMAGES_SOURCE",
    "PROMETHEUS_MCP_SERVER_IMAGE": "LITMUS_IMAGES_SOURCE",
}

# Defaults mirror scripts/prepare-images.sh so an absent key behaves the same.
SOURCE_DEFAULTS = {
    "INSTALL_APP_IMAGE_SOURCE": "registry",
    "INSTALL_AGENT_IMAGE_SOURCE": "registry",
    "LITMUS_IMAGES_SOURCE": "registry",
    "SRE_AGENTS_IMAGE_SOURCE": "local",
}


def read_env(path):
    """Last value wins, like setup.sh's cur()."""
    env = {}
    with open(path) as fh:
        for line in fh:
            m = re.match(r"^([A-Za-z0-9_.]+)=(.*)$", line.rstrip("\n"))
            if m:
                env[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return env


def normalize_registry(value):
    value = value.strip()
    for scheme in ("https://", "http://"):
        if value.startswith(scheme):
            value = value[len(scheme):]
    value = value.replace("/ui/native/", "/")
    return value.rstrip("/")


def normalize_source(value):
    value = (value or "").strip().lower()
    if value in ("jfrog", "dockerhub"):
        return "registry"
    return value


def canonical(ref):
    """Drop an explicit docker.io/library prefix, add :latest if untagged."""
    for prefix in ("docker.io/", "index.docker.io/", "registry-1.docker.io/"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    if ref.startswith("library/"):
        ref = ref[len("library/"):]
    last = ref.rsplit("/", 1)[-1]
    if ":" not in last and "@" not in ref:
        ref += ":latest"
    return ref


def flat_ref(ref, namespace):
    """agentcert/<name with host dropped and "/" -> "-">:<tag>."""
    if ref.startswith(namespace + "/"):
        return ref
    name, tag = ref.rsplit(":", 1)
    first = name.split("/", 1)[0]
    if "/" in name and ("." in first or ":" in first or first == "localhost"):
        name = name.split("/", 1)[1]
    return f"{namespace}/{name.replace('/', '-')}:{tag}"


_MIRRORED = None


def is_mirrored(canonical_ref):
    """Has a frozen copy: a non-optional "mirror" row of deploy/images.txt."""
    global _MIRRORED
    if _MIRRORED is None:
        import os
        inv = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "deploy", "images.txt")
        _MIRRORED = set()
        try:
            for line in open(inv):
                f = line.strip().split("|")
                if len(f) >= 3 and f[0].strip() == "mirror" and "optional" not in "|".join(f[3:]):
                    _MIRRORED.add(canonical(f[2]))
        except OSError:
            pass
    return canonical_ref in _MIRRORED


def registry_ref(ref, registry, mirror_namespace="agentcert"):
    if registry:
        if ref.startswith(registry + "/"):
            return ref  # already resolved — never double-prefix
        return f"{registry}/{canonical(ref)}"
    c = canonical(ref)
    if mirror_namespace and mirror_namespace != "none" and is_mirrored(c):
        return flat_ref(c, mirror_namespace)
    return c


def resolve(env):
    registry = normalize_registry(env.get("IMAGE_REGISTRY", ""))
    mirror_ns = env.get("IMAGE_MIRROR_NAMESPACE", "") or "agentcert"
    out, why = {}, []
    for key, src_key in IMAGE_SOURCES.items():
        public = env.get(key, "")
        if not public:
            continue
        source = normalize_source(env.get(src_key) or SOURCE_DEFAULTS.get(src_key, "registry"))
        if source == "registry":
            resolved = registry_ref(public, registry, mirror_ns)
            if resolved != public:
                out[key] = resolved
                why.append(f"{key}: {public} -> {resolved} ({src_key}=registry)")
            else:
                why.append(f"{key}: {public} unchanged (already at its registry name)")
        else:
            why.append(f"{key}: {public} unchanged ({src_key}={source or 'unset'}: side-loaded under its public name)")

    litmus_src = normalize_source(env.get("LITMUS_IMAGES_SOURCE") or SOURCE_DEFAULTS["LITMUS_IMAGES_SOURCE"])
    # graphql's helper-image rewrite only knows "<prefix>/<repo>/<name>" (nested),
    # so with IMAGE_REGISTRY empty helper images stay on their upstream
    # docker.io names until that rewrite learns the flat agentcert/ form.
    prefix = f"{registry}/" if (litmus_src == "registry" and registry) else "docker.io"
    out["LITMUS_HELPER_IMAGES_REGISTRY_PREFIX"] = prefix
    why.append(f"LITMUS_HELPER_IMAGES_REGISTRY_PREFIX={prefix} (LITMUS_IMAGES_SOURCE={litmus_src})")
    return out, why


# ── Manifest rewriting (Python twin of graphql pkg/imageref RewriteText /
#    AddPullSecretText; scripts/tests/test-registry-tooling.sh checks parity) ──
_IMAGE_LINE = re.compile(r"""(?m)^(\s*(?:-\s+)?image:[ \t]*)(["']?)([^"'\s#{}]+)(["']?)""")
_IMAGE_ENV = re.compile(r"""(?m)^(\s*-?\s*name:[ \t]*["']?)([A-Z0-9_]*_IMAGE)(["']?[ \t]*\r?\n\s*value:[ \t]*)(["']?)([^"'\s#{}]+)(["']?)""")
_CONTAINERS = re.compile(r"^(\s*)containers:\s*$")
_BROKEN_ON_PURPOSE = {"INVALID_IMAGE", "INVALID_ARCH_IMAGE"}


def resolve_ref(ref, registry, mirror_namespace):
    """registry_ref that leaves empty and templated references alone."""
    if not ref.strip() or "{{" in ref or "$(" in ref:
        return ref
    return registry_ref(ref.strip(), registry, mirror_namespace)


def rewrite_text(text, registry, mirror_namespace="agentcert", skip=None):
    """Resolve every image: line and *_IMAGE env value (not INVALID_*IMAGE)."""
    if not registry and mirror_namespace == "none":
        return text
    def res(ref):
        return ref if skip and skip(ref) else resolve_ref(ref, registry, mirror_namespace)
    text = _IMAGE_LINE.sub(lambda m: m.group(1) + m.group(2) + res(m.group(3)) + m.group(4), text)
    return _IMAGE_ENV.sub(lambda m: m.group(0) if m.group(2) in _BROKEN_ON_PURPOSE else
                          m.group(1) + m.group(2) + m.group(3) + m.group(4) + res(m.group(5)) + m.group(6), text)


def add_pull_secret_text(text, secret):
    """Insert imagePullSecrets before every pod spec's containers: key."""
    if not secret:
        return text
    lines = text.split("\n")
    out = []
    for i, line in enumerate(lines):
        m = _CONTAINERS.match(line)
        if m and not _sibling_key_exists(lines, i, m.group(1), "imagePullSecrets:"):
            out += [m.group(1) + "imagePullSecrets:", m.group(1) + "- name: " + secret]
        out.append(line)
    return "\n".join(out)


def _sibling_key_exists(lines, at, indent, key):
    def in_mapping(l):
        t = l.strip()
        return t == "" or t.startswith("#") or (l.startswith(indent) and len(l) > len(indent))
    for step in (-1, 1):
        j = at + step
        while 0 <= j < len(lines) and in_mapping(lines[j]):
            if lines[j].startswith(indent + key):
                return True
            if lines[j].strip() == "---":
                break
            j += step
    return False


def rewrite_manifests(env, text, keep_ace_images=False, keep=()):
    """Rewrite plain Kubernetes manifests for this .env: resolve images and add
    the pull secret. keep_ace_images keeps agentcert/* names (built and
    side-loaded locally); keep lists other public names to leave alone."""
    registry = normalize_registry(env.get("IMAGE_REGISTRY", ""))
    mirror_ns = env.get("IMAGE_MIRROR_NAMESPACE", "") or "agentcert"
    keep = set(canonical(k) for k in keep)
    def skip(ref):
        c = canonical(ref)
        return c in keep or (keep_ace_images and c.startswith("agentcert/"))
    out = rewrite_text(text, registry, mirror_ns, skip)
    secret = (env.get("IMAGE_PULL_SECRET_NAME", "") or "registry-pull") if registry else ""
    return add_pull_secret_text(out, secret)


def main(argv):
    # --rewrite-manifests ENV_FILE [--keep-ace-images] [--keep IMAGE]... < in > out
    if len(argv) >= 3 and argv[1] == "--rewrite-manifests":
        rest = argv[3:]
        keep = [rest[i + 1] for i, a in enumerate(rest) if a == "--keep" and i + 1 < len(rest)]
        sys.stdout.write(rewrite_manifests(read_env(argv[2]), sys.stdin.read(),
                                           "--keep-ace-images" in rest, keep))
        return 0
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    overrides, why = resolve(read_env(argv[1]))
    for key, value in overrides.items():
        print(f"{key}={value}")
    if "--explain" in argv[2:]:
        for line in why:
            print("  " + line, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
