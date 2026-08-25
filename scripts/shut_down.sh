#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ACE infrastructure teardown
# =============================================================================
# Removes every Docker container, named volume, and KinD cluster that
# setup.sh / start-local-services.sh created for THIS checkout's
# ACE_INSTANCE_NAME.  Never touches resources that belong to another user or
# checkout on this shared host.
#
#   ./scripts/shut_down.sh                       # interactive confirmation; if neither
#                                                  # --keep-ollama-model nor --delete-ollama-model
#                                                  # is given, asks whether to keep the pulled
#                                                  # ollama-models-<instance> volume (default: keep)
#   ./scripts/shut_down.sh --yes                  # non-interactive (CI / scripted use);
#                                                  # defaults to keeping the ollama model volume
#                                                  # unless --delete-ollama-model is also given
#   ./scripts/shut_down.sh --keep-ollama-model    # preserve the ollama-models-<instance>
#                                                  # volume so pulled models survive teardown
#                                                  # and don't need to be re-downloaded by
#                                                  # the next setup.sh run (this is the default
#                                                  # outcome even without the flag — see above)
#   ./scripts/shut_down.sh --delete-ollama-model  # explicitly delete the ollama-models-<instance>
#                                                  # volume without being asked
#   ./scripts/shut_down.sh --keep-langfuse-traces  # preserve Langfuse's Postgres, ClickHouse,
#                                                  # Redis, and MinIO data volumes so traces
#                                                  # reappear on the next setup/compose bring-up
#                                                  # (opt-in; default teardown deletes them)
#   ./scripts/shut_down.sh --delete-langfuse-traces # explicitly delete Langfuse trace volumes
#   ./scripts/shut_down.sh --no-mongo-backup       # skip the automatic MongoDB dump (see below)
#   ./scripts/shut_down.sh --clean-itbench-pods    # standalone: delete only Completed pods in
#                                                    # whichever namespace(s) currently have a
#                                                    # connected chaos infrastructure (subscriber
#                                                    # Deployment) on THIS checkout's own KinD
#                                                    # cluster. Prompts if more than one such
#                                                    # namespace is found. Does not touch Docker
#                                                    # containers/volumes or the cluster itself,
#                                                    # and exits without running the rest of the
#                                                    # teardown below. See §"Clean itbench pods".
#   ./scripts/shut_down.sh --clean-itbench-pods \
#       --namespace=sock-shop                       # same, but skips discovery/prompt and
#                                                    # targets the given namespace directly —
#                                                    # for scripted/CI use alongside --yes.
#
# MongoDB backup: by default, if a Kubernetes-deployed MongoDB (mongodb-0 pod,
# `ace` namespace) is reachable on this checkout's KinD cluster, it is
# mongodump'd BEFORE the cluster is deleted below -- kind delete cluster
# destroys local-path-provisioner's PV data unconditionally, and a fresh
# `setup.sh` run reprovisions an empty volume (dynamically-provisioned PVs get
# a fresh random on-disk path each time, so simply keeping the PVC/PV config
# around does not preserve data across a cluster recreation).
#
# Each run gets its OWN timestamped, independent archive --
# .tmp/mongodb-backups/<instance>/mongodb-<UTC timestamp>.archive.gz -- never
# overwriting a previous one, so a bad/partial teardown never destroys a good
# backup from an earlier session, and older generations stay available if a
# more recent one turns out to be the wrong pick. Pruned to the newest
# MONGO_BACKUP_RETAIN (default 10) after each successful dump so this doesn't
# grow unbounded. Each archive also gets a small sidecar
# (mongodb-<timestamp>.archive.gz.meta) recording what the database it was
# dumped from was itself started from — "scratch" or the filename of an
# earlier backup — so the lineage between backups is visible, not just their
# timestamps. setup.sh's interactive (non---restart) wizard lists all of them
# (newest first, with that lineage) and lets the user pick one to restore, or
# start with a brand-new empty database. This does NOT cover the separate
# docker-compose.yml root-stack MongoDB (its mongodb_data volume already
# survives `docker compose down` without -v; only `down -v` removes it,
# independent of this script).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
say()  { echo -e "$*"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
YES=0
KEEP_OLLAMA_MODEL=1   # default: keep the pulled model volume unless told otherwise
OLLAMA_MODEL_FLAG_SET=0
KEEP_LANGFUSE_TRACES=0   # default: old workflow — delete trace volumes unless told otherwise
LANGFUSE_TRACE_FLAG_SET=0
SKIP_MONGO_BACKUP=0   # default: back up MongoDB (K8s path) before deleting the KinD cluster
CLEAN_ITBENCH_PODS=0  # standalone mode: only clean Completed pods in the in-use namespace(s), see below
CLEAN_NAMESPACE=""    # optional explicit target for --clean-itbench-pods; skips discovery/prompt
for _arg in "$@"; do
    case "${_arg}" in
        -y|--yes) YES=1 ;;
        -k|--keep-ollama-model) KEEP_OLLAMA_MODEL=1; OLLAMA_MODEL_FLAG_SET=1 ;;
        --delete-ollama-model) KEEP_OLLAMA_MODEL=0; OLLAMA_MODEL_FLAG_SET=1 ;;
        --keep-langfuse-traces) KEEP_LANGFUSE_TRACES=1; LANGFUSE_TRACE_FLAG_SET=1 ;;
        --delete-langfuse-traces) KEEP_LANGFUSE_TRACES=0; LANGFUSE_TRACE_FLAG_SET=1 ;;
        --no-mongo-backup) SKIP_MONGO_BACKUP=1 ;;
        --clean-itbench-pods) CLEAN_ITBENCH_PODS=1 ;;
        --namespace=*) CLEAN_NAMESPACE="${_arg#--namespace=}" ;;
        -h|--help)
            say "Usage: $0 [--yes|-y] [--keep-ollama-model|-k] [--delete-ollama-model] [--keep-langfuse-traces] [--delete-langfuse-traces] [--no-mongo-backup] [--clean-itbench-pods [--namespace=NS]]"
            say "  Tears down all ACE infrastructure for the ACE_INSTANCE_NAME in .env."
            say "  --yes / -y                skip the confirmation prompt"
            say "  --keep-ollama-model / -k  don't delete the ollama-models-<instance> volume"
            say "                            (preserves already-pulled models for next setup)"
            say "                            — this is the default even without the flag"
            say "  --delete-ollama-model     delete the ollama-models-<instance> volume"
            say "  --keep-langfuse-traces    keep Langfuse Postgres/ClickHouse/Redis/MinIO"
            say "                            data volumes so traces are reused next setup"
            say "                            — opt-in; default teardown deletes them"
            say "  --delete-langfuse-traces  delete Langfuse trace/data volumes"
            say "  If neither ollama-model flag is given: interactive runs are asked; --yes"
            say "  runs (no prompt possible) default to keeping the volume."
            say "  If neither Langfuse flag is given: interactive runs are asked; --yes"
            say "  runs default to deleting Langfuse trace volumes (old behavior)."
            say "  --no-mongo-backup         skip the automatic MongoDB dump normally taken"
            say "                            before the KinD cluster is deleted (see header"
            say "                            comment above) — this is done by default."
            say "  --clean-itbench-pods      standalone: delete only Completed pods in whichever"
            say "                            namespace(s) currently have a connected chaos"
            say "                            infrastructure (subscriber Deployment) on this"
            say "                            checkout's own KinD cluster (verified via the same"
            say "                            ownership marker used before deleting the cluster"
            say "                            itself). If more than one such namespace is found,"
            say "                            you are asked which one to clean. Does NOT touch"
            say "                            Docker containers/volumes or the cluster, and does"
            say "                            not run the rest of teardown."
            say "  --namespace=NS            with --clean-itbench-pods: target NS directly,"
            say "                            skipping discovery and the multi-namespace prompt"
            say "                            (for scripted/CI use, typically alongside --yes)."
            exit 0 ;;
        *) err "Unknown argument: ${_arg}"; exit 1 ;;
    esac
done
unset _arg

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    err ".env not found at ${ENV_FILE}"
    err "This checkout has never been configured by setup.sh — nothing to tear down."
    exit 1
fi

cur() { grep -m1 "^${1}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true; }

ACE_INSTANCE_NAME="$(cur ACE_INSTANCE_NAME)"
if [[ -z "${ACE_INSTANCE_NAME}" ]]; then
    err "ACE_INSTANCE_NAME is not set in .env."
    err "Cannot determine which resources belong to this checkout."
    exit 1
fi

KIND_CLUSTER_NAME="$(cur KIND_CLUSTER_NAME)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentcert-${ACE_INSTANCE_NAME}}"
CLUSTER_MODE="$(cur CLUSTER_MODE)"; CLUSTER_MODE="${CLUSTER_MODE:-auto}"

INST="${ACE_INSTANCE_NAME}"

echo
say "${CYAN}══════════════════════════════════════════════════════${NC}"
say "${CYAN}  ACE infrastructure teardown — instance: ${BOLD}${INST}${NC}"
say "${CYAN}══════════════════════════════════════════════════════${NC}"
say "${DIM}  Repo root : ${REPO_ROOT}${NC}"
say "${DIM}  .env      : ${ENV_FILE}${NC}"
echo

# ── Ownership helpers ─────────────────────────────────────────────────────────

# Return 0 (safe to proceed) if the named container either does not exist, or
# exists and was created by this checkout.  Return 1 (skip) if it was created
# by a different checkout — prints an error so the caller can skip that stack.
#
# Ownership is determined by comparing the inode of the container's
# com.docker.compose.project.environment_file label against the inode of our
# own ENV_FILE.  Path-string comparison is unreliable here because the host
# exposes the same directory tree under two mount paths (/home/... and
# /Innovation/home/...) — same inode, different strings.  stat -c '%d:%i'
# returns device:inode, which is path-alias-proof.
container_is_ours() {
    local name="$1"
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        return 0   # does not exist — safe to proceed
    fi
    local their_env their_ino our_ino
    their_env="$(docker inspect "${name}" \
        --format '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' \
        2>/dev/null || true)"
    [[ -z "${their_env}" ]] && return 0   # no env-file label — not a managed stack container
    our_ino="$(stat -c '%d:%i' "${ENV_FILE}" 2>/dev/null || true)"
    their_ino="$(stat -c '%d:%i' "${their_env}" 2>/dev/null || true)"
    if [[ -n "${their_ino}" && "${their_ino}" != "${our_ino}" ]]; then
        err "  Container '${name}' belongs to a different checkout: ${their_env}"
        err "  Refusing to touch it. If this is wrong, check ACE_INSTANCE_NAME in .env."
        return 1
    fi
    return 0
}

# Return 0 if ALL containers in a compose project belong to this checkout
# (or the project has no containers at all).  Return 1 otherwise.
project_is_ours() {
    local project="$1"
    local foreign=0
    local our_ino
    our_ino="$(stat -c '%d:%i' "${ENV_FILE}" 2>/dev/null || true)"
    while IFS= read -r cname; do
        [[ -z "${cname}" ]] && continue
        local their_env their_ino
        their_env="$(docker inspect "${cname}" \
            --format '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' \
            2>/dev/null || true)"
        [[ -z "${their_env}" ]] && continue   # no env-file label — skip
        their_ino="$(stat -c '%d:%i' "${their_env}" 2>/dev/null || true)"
        if [[ -n "${their_ino}" && "${their_ino}" != "${our_ino}" ]]; then
            err "  Container '${cname}' (project '${project}') belongs to a different checkout: ${their_env}"
            err "  Refusing to touch this stack. Check ACE_INSTANCE_NAME in .env."
            foreign=1
        fi
    done < <(docker ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true)
    [[ "${foreign}" -eq 1 ]] && return 1
    return 0
}

# Compare two paths for referring to the same directory, alias-proof — the
# same "same tree under two mount paths" issue documented above for
# container_is_ours/project_is_ours also applies to the KinD ownership
# marker, which stores a path string rather than an inode. Compare device:inode
# of the directories instead of the raw strings.
same_dir() {
    local a b
    a="$(stat -c '%d:%i' "$1" 2>/dev/null || true)"
    b="$(stat -c '%d:%i' "$2" 2>/dev/null || true)"
    [[ -n "${a}" && "${a}" == "${b}" ]]
}

# ── Clean itbench pods (standalone; exits before touching anything else) ──────
# Every ChaosEngine under chaos-charts/faults/itbench/ sets
# jobCleanUpPolicy: retain, so LitmusChaos never deletes the runner Job/pod
# for a fault run — they're kept around so logs stay inspectable post-hoc.
# Nothing else reaps them, so at N=30-runs-per-fault scale they accumulate
# without bound. This does the minimum needed to clean that up: only
# Completed (phase=Succeeded) pods, only in the namespace(s) that currently
# have a connected chaos infrastructure, only on THIS checkout's own KinD
# cluster — no Docker containers/volumes, no unrelated namespace, and the
# cluster itself is never touched.
#
# "Currently in use" is not a fixed namespace — a chaos infra (the LitmusChaos
# subscriber agent connecting a target namespace to this ChaosCenter) can be
# registered against sock-shop, book-info, otel-demo, itbench, or any other
# app namespace, and more than one can be connected at once. Every connected
# infra runs its own `subscriber` Deployment labelled app=subscriber in the
# namespace it targets (see setup.sh's restart_subscriber_deployments, which
# discovers them the same way via `kubectl get deployment -A -l app=subscriber`)
# — that label is the authoritative, dynamic signal for "which namespace(s) are
# in use" used below, rather than a hardcoded namespace name.
#
# Daemon-agnostic by construction: this whole block only ever calls `docker`
# and `kind`/`kubectl` (the kubeconfig kind exports below), never a hardcoded
# socket path. Both transparently follow whichever `docker context` is active
# for this shell (rootless or the shared root daemon — see CLAUDE.md §6
# "Personal rootless Docker") — so under rootless, `kind get clusters` simply
# won't list a cluster that lives on the shared daemon (and vice versa), which
# is exactly the isolation this needs with no extra handling required here.
if [[ "${CLEAN_ITBENCH_PODS}" -eq 1 ]]; then
    say "${CYAN}══════════════════════════════════════════════════════${NC}"
    say "${CYAN}  Clean Completed pods — active chaos infrastructure${NC}"
    say "${CYAN}══════════════════════════════════════════════════════${NC}"
    say "${DIM}  This does NOT touch Docker containers, volumes, or the KinD cluster itself —${NC}"
    say "${DIM}  only Completed (phase=Succeeded) pods in the namespace(s) with a connected${NC}"
    say "${DIM}  chaos infrastructure (subscriber Deployment).${NC}"
    say "${DIM}  Error/Running/Pending pods and Job/ChaosEngine objects are left untouched.${NC}"
    echo

    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        err "CLUSTER_MODE=cloud — the target cluster may be shared with other users, and"
        err "individual pod ownership can't be verified the way the KinD-cluster marker"
        err "below verifies whole-cluster ownership. Refusing to auto-delete pods here —"
        err "clean up manually with kubectl once you've confirmed which pods are yours."
        exit 1
    fi

    if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
        err "kind/kubectl not on PATH — cannot verify cluster ownership or clean pods."
        exit 1
    fi

    if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
        err "KinD cluster '${KIND_CLUSTER_NAME}' not found — nothing to clean."
        exit 1
    fi

    _owner_marker="ace-kind-owner-${KIND_CLUSTER_NAME}"
    _cluster_owner="$(docker volume inspect "${_owner_marker}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if ! same_dir "${_cluster_owner}" "${REPO_ROOT}"; then
        err "KinD cluster '${KIND_CLUSTER_NAME}' is not owned by this checkout"
        err "(owner marker: ${_cluster_owner:-none}). Refusing to touch its pods."
        exit 1
    fi
    ok "Verified '${KIND_CLUSTER_NAME}' is owned by this checkout (${REPO_ROOT})."
    unset _owner_marker _cluster_owner

    if ! kind export kubeconfig --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1; then
        err "Could not export kubeconfig for cluster '${KIND_CLUSTER_NAME}'."
        exit 1
    fi

    # ── Resolve the target namespace(s) ───────────────────────────────────────
    _target_ns=""
    if [[ -n "${CLEAN_NAMESPACE}" ]]; then
        if ! kubectl get ns "${CLEAN_NAMESPACE}" >/dev/null 2>&1; then
            err "Namespace '${CLEAN_NAMESPACE}' (from --namespace) does not exist on this cluster."
            exit 1
        fi
        _target_ns="${CLEAN_NAMESPACE}"
        say "${DIM}Using explicit --namespace=${_target_ns} (skipping discovery).${NC}"
    else
        mapfile -t _infra_namespaces < <(kubectl get deployment -A -l app=subscriber \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null \
            | sort -u || true)

        if [[ ${#_infra_namespaces[@]} -eq 0 ]]; then
            say "${DIM}No connected chaos infrastructure (subscriber Deployment) found on this cluster.${NC}"
            say "${DIM}Nothing to clean.${NC}"
            exit 0
        elif [[ ${#_infra_namespaces[@]} -eq 1 ]]; then
            _target_ns="${_infra_namespaces[0]}"
            ok "Found one active chaos infrastructure — namespace: ${_target_ns}"
        else
            echo
            say "${BOLD}Found ${#_infra_namespaces[@]} namespaces with an active chaos infrastructure:${NC}"
            for _i in "${!_infra_namespaces[@]}"; do
                say "    $(( _i + 1 ))) ${_infra_namespaces[${_i}]}"
            done
            unset _i
            echo
            if [[ "${YES}" -eq 1 ]]; then
                err "Multiple chaos infrastructure namespaces found and --yes was given with no"
                err "--namespace= to disambiguate. Re-run with --namespace=<one of the above>."
                exit 1
            fi
            read -rp "$(echo -e "Which namespace should be cleaned? [1-${#_infra_namespaces[@]}]: ")" _ns_choice
            if ! [[ "${_ns_choice}" =~ ^[0-9]+$ ]] || (( _ns_choice < 1 || _ns_choice > ${#_infra_namespaces[@]} )); then
                say "${DIM}Invalid selection — aborted, nothing was changed.${NC}"
                exit 0
            fi
            _target_ns="${_infra_namespaces[$(( _ns_choice - 1 ))]}"
            unset _ns_choice
            echo
        fi
        unset _infra_namespaces
    fi

    mapfile -t _completed_pods < <(kubectl get pods -n "${_target_ns}" \
        --field-selector=status.phase=Succeeded -o name 2>/dev/null || true)

    if [[ ${#_completed_pods[@]} -eq 0 ]]; then
        say "${DIM}No Completed pods found in '${_target_ns}'. Nothing to clean.${NC}"
        exit 0
    fi

    echo
    say "${BOLD}Found ${#_completed_pods[@]} Completed pod(s) in '${_target_ns}':${NC}"
    for _p in "${_completed_pods[@]}"; do say "    • ${_p#pod/}"; done
    unset _p
    echo

    if [[ "${YES}" -eq 0 ]]; then
        read -rp "$(echo -e "Delete these ${#_completed_pods[@]} Completed pod(s)? Type ${BOLD}yes${NC} to proceed: ")" _confirm
        echo
        if [[ "${_confirm}" != "yes" ]]; then
            say "${DIM}Aborted — nothing was changed.${NC}"
            exit 0
        fi
        unset _confirm
    fi

    if kubectl delete pods -n "${_target_ns}" --field-selector=status.phase=Succeeded; then
        ok "Deleted ${#_completed_pods[@]} Completed pod(s) from '${_target_ns}'."
    else
        err "kubectl delete failed — see output above."
        exit 1
    fi
    exit 0
fi

# ── Ask about the ollama model volume if the caller didn't say ────────────────
# Only bother asking if the volume actually exists — nothing to decide otherwise.
_OLLAMA_MODELS_VOL="ollama-models-${INST}"
if [[ "${OLLAMA_MODEL_FLAG_SET}" -eq 0 ]] && docker volume inspect "${_OLLAMA_MODELS_VOL}" >/dev/null 2>&1; then
    if [[ "${YES}" -eq 1 ]]; then
        say "${DIM}No --keep-ollama-model/--delete-ollama-model given with --yes; defaulting to keep '${_OLLAMA_MODELS_VOL}'.${NC}"
    else
        echo
        read -rp "$(echo -e "Keep the pulled Ollama model volume '${BOLD}${_OLLAMA_MODELS_VOL}${NC}'? [${BOLD}Y${NC}/n]: ")" _keep_model
        if [[ "${_keep_model}" =~ ^[Nn] ]]; then
            KEEP_OLLAMA_MODEL=0
        else
            KEEP_OLLAMA_MODEL=1
        fi
        unset _keep_model
    fi
    echo
fi

langfuse_trace_volume() {
    local vname="$1"
    [[ "${vname}" =~ ^(ace|ace-langfuse)-${INST}_langfuse_(postgres_data|clickhouse_data|clickhouse_logs|minio_data|redis_data)$ ]]
}

mapfile -t _LANGFUSE_TRACE_VOLUMES < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
    | grep -E "^(ace-${INST}|ace-langfuse-${INST})_langfuse_(postgres_data|clickhouse_data|clickhouse_logs|minio_data|redis_data)$" \
    | sort || true)
if [[ "${LANGFUSE_TRACE_FLAG_SET}" -eq 0 && ${#_LANGFUSE_TRACE_VOLUMES[@]} -gt 0 ]]; then
    if [[ "${YES}" -eq 1 ]]; then
        say "${DIM}No --keep-langfuse-traces/--delete-langfuse-traces given with --yes; defaulting to delete existing Langfuse trace volumes (old behavior).${NC}"
    else
        echo
        say "${BOLD}Found Langfuse trace/data volumes for this instance:${NC}"
        for _lfv in "${_LANGFUSE_TRACE_VOLUMES[@]}"; do say "    • ${_lfv}"; done
        read -rp "$(echo -e "Keep these Langfuse volumes so traces reappear on the next setup? [y/${BOLD}N${NC}]: ")" _keep_langfuse
        if [[ "${_keep_langfuse}" =~ ^[Yy] ]]; then
            KEEP_LANGFUSE_TRACES=1
        else
            KEEP_LANGFUSE_TRACES=0
        fi
        unset _keep_langfuse _lfv
    fi
    echo
fi

# ── Safeguard: verify at least some infra exists on this host ─────────────────
say "${BOLD}Scanning for ACE infrastructure (instance: ${BOLD}${INST}${NC}${BOLD})…${NC}"
echo

FOUND_CONTAINERS=()
FOUND_VOLUMES=()
KEPT_VOLUMES=()
FOUND_KIND=""

# -- Known container names created by setup.sh / start-local-services.sh ------
for cname in \
    "agentcert-mongo-${INST}" \
    "ace-mongo-keyfile-${INST}" \
    "ace-mongo-init-${INST}" \
    "ace-cluster-init-${INST}" \
    "ace-workspace-init-${INST}" \
    "agentcert-auth-${INST}" \
    "agentcert-graphql-${INST}" \
    "agentcert-web-${INST}" \
    "litellm-proxy-${INST}" \
    "certifier_app_${INST}" \
    "ollama-${INST}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${cname}"; then
        FOUND_CONTAINERS+=("${cname}")
    fi
done

# -- Langfuse containers are named by Compose (no explicit container_name:) ---
while IFS= read -r cname; do
    [[ -n "${cname}" ]] && FOUND_CONTAINERS+=("${cname} [langfuse]")
done < <(docker ps -a \
    --filter "label=com.docker.compose.project=ace-langfuse-${INST}" \
    --format '{{.Names}}' 2>/dev/null || true)

# -- Named volumes whose names encode ACE_INSTANCE_NAME -----------------------
while IFS= read -r vname; do
    [[ -z "${vname}" ]] && continue
    if [[ "${vname}" == "${_OLLAMA_MODELS_VOL}" && "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
        KEPT_VOLUMES+=("${vname}")
        continue
    fi
    if langfuse_trace_volume "${vname}" && [[ "${KEEP_LANGFUSE_TRACES}" -eq 1 ]]; then
        KEPT_VOLUMES+=("${vname}")
        continue
    fi
    FOUND_VOLUMES+=("${vname}")
done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E \
    "^(ace-${INST}_|ace-langfuse-${INST}_|ace-litellm-${INST}_|ace-certifier-${INST}_|ollama-models-${INST}$)" \
    || true)

# -- KinD cluster (only count it if this checkout owns it) --------------------
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    _owner_marker="ace-kind-owner-${KIND_CLUSTER_NAME}"
    _cluster_owner="$(docker volume inspect "${_owner_marker}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_cluster_owner}" "${REPO_ROOT}"; then
        FOUND_KIND="${KIND_CLUSTER_NAME}"
    else
        warn "KinD cluster '${KIND_CLUSTER_NAME}' exists but is owned by a different checkout"
        warn "(owner label: ${_cluster_owner:-none}). It will NOT be deleted."
    fi
    unset _owner_marker _cluster_owner
fi

TOTAL_FOUND=$(( ${#FOUND_CONTAINERS[@]} + ${#FOUND_VOLUMES[@]} ))
[[ -n "${FOUND_KIND}" ]] && TOTAL_FOUND=$(( TOTAL_FOUND + 1 ))

# -- Hard stop if nothing belongs to this checkout ----------------------------
if [[ "${TOTAL_FOUND}" -eq 0 ]]; then
    say "${YELLOW}No ACE infrastructure found for instance '${INST}' on this host.${NC}"
    say "${DIM}Nothing to shut down."
    if [[ ${#KEPT_VOLUMES[@]} -gt 0 ]]; then
        say "${DIM}(Kept data volumes: ${KEPT_VOLUMES[*]})${NC}"
    fi
    say "If resources were created under a different instance name, check ACE_INSTANCE_NAME in .env.${NC}"
    exit 0
fi

# ── Show the teardown plan ────────────────────────────────────────────────────
say "${BOLD}Found the following resources owned by this checkout:${NC}"
echo

if [[ ${#FOUND_CONTAINERS[@]} -gt 0 ]]; then
    say "  ${CYAN}Containers (${#FOUND_CONTAINERS[@]}):${NC}"
    for c in "${FOUND_CONTAINERS[@]}"; do say "    • ${c}"; done
    echo
fi
if [[ ${#FOUND_VOLUMES[@]} -gt 0 ]]; then
    say "  ${CYAN}Volumes (${#FOUND_VOLUMES[@]}):${NC}"
    for v in "${FOUND_VOLUMES[@]}"; do say "    • ${v}"; done
    echo
fi
if [[ ${#KEPT_VOLUMES[@]} -gt 0 ]]; then
    say "  ${CYAN}Kept data volumes:${NC}"
    for v in "${KEPT_VOLUMES[@]}"; do say "    • ${v} ${DIM}(will NOT be deleted)${NC}"; done
    echo
fi
if [[ -n "${FOUND_KIND}" ]]; then
    say "  ${CYAN}KinD cluster:${NC}  ${FOUND_KIND}"
    echo
fi
if [[ "${CLUSTER_MODE}" == "local" || "${CLUSTER_MODE}" == "cloud" ]]; then
    warn "CLUSTER_MODE=${CLUSTER_MODE} — Kubernetes resources in the external cluster are NOT"
    warn "managed by this script. Run 'helm uninstall ace -n ace' or 'kubectl delete ns ace'"
    warn "manually against that cluster if needed."
    echo
fi

say "${RED}${BOLD}⚠  This permanently deletes all listed containers and their data volumes.${NC}"
say "${DIM}Docker images are NOT removed. Use 'docker image prune' or 'docker rmi' separately.${NC}"
echo

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "${YES}" -eq 0 ]]; then
    read -rp "$(echo -e "Type ${BOLD}yes${NC} to proceed, anything else to abort: ")" _confirm
    echo
    if [[ "${_confirm}" != "yes" ]]; then
        say "${DIM}Aborted — nothing was changed.${NC}"
        exit 0
    fi
    unset _confirm
fi

# ── 0. MongoDB backup (before anything below is destroyed) ────────────────────
# Only the Kubernetes-deployed MongoDB (StatefulSet/PVC on the KinD cluster) is
# at risk here -- kind delete cluster (step 6) wipes local-path-provisioner's
# PV data unconditionally, and re-provisioning on the next `setup.sh` run gets
# a fresh, empty volume (dynamic PVs get a new random on-disk path each time,
# so nothing about the PVC/PV *configuration* surviving helps). The
# docker-compose.yml root-stack MongoDB is a separate instance with its own
# durable, instance-scoped named volume (mongodb_data-<instance>) that this
# script's `down -v` below does remove -- not covered here, since a Compose
# volume dump/restore is unnecessary complexity, not something threatened by
# the same "dynamic path re-provisioning" problem the K8s path has.
MONGO_BACKUP_DIR="${REPO_ROOT}/.tmp/mongodb-backups/${INST}"
MONGO_BACKUP_RETAIN=10   # keep the newest N independent backups per instance; prune older ones
# Written by setup.sh's offer_mongodb_restore() right after it decides how the
# currently-running database was brought up (fresh, or restored from a named
# backup) -- read here so each new backup records its own lineage. Missing
# (e.g. a database that predates this feature, or was never deployed through
# setup.sh's interactive wizard) just means "unknown", not an error.
MONGO_LINEAGE_FILE="${MONGO_BACKUP_DIR}/current-started-from"
if [[ "${SKIP_MONGO_BACKUP}" -eq 1 ]]; then
    say "${DIM}Skipping MongoDB backup (--no-mongo-backup).${NC}"
elif [[ -z "${FOUND_KIND}" ]]; then
    : # no KinD cluster owned by this checkout — nothing to back up from
else
    echo
    say "${CYAN}▸ MongoDB backup (before deleting the KinD cluster)${NC}"
    if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
        warn "  kind/kubectl not on PATH — skipping backup."
    elif ! kind export kubeconfig --name "${FOUND_KIND}" >/dev/null 2>&1; then
        warn "  Could not get a kubeconfig for cluster '${FOUND_KIND}' — skipping backup."
    elif ! kubectl get pod mongodb-0 -n ace >/dev/null 2>&1; then
        say "  ${DIM}No mongodb-0 pod in namespace 'ace' on this cluster — nothing to back up.${NC}"
    else
        _mongo_user="$(cur MONGODB_USERNAME)"; _mongo_user="${_mongo_user:-admin}"
        _mongo_pass="$(cur MONGODB_PASSWORD)"; _mongo_pass="${_mongo_pass:-1234}"
        mkdir -p "${MONGO_BACKUP_DIR}"
        # Each run gets its own file -- never overwritten, so a failed dump
        # here can never clobber a good backup from an earlier session, and
        # older generations stay pickable in setup.sh even after newer ones
        # are taken. UTC + colon-free so the filename sorts chronologically
        # and is safe on every filesystem.
        _backup_file="${MONGO_BACKUP_DIR}/mongodb-$(date -u '+%Y%m%dT%H%M%SZ').archive.gz"
        _tmp_backup="${_backup_file}.tmp"
        if kubectl exec -n ace mongodb-0 -- mongodump --archive --gzip \
                -u "${_mongo_user}" -p "${_mongo_pass}" --authenticationDatabase admin \
                > "${_tmp_backup}" 2>/dev/null \
           && [[ -s "${_tmp_backup}" ]]; then
            mv "${_tmp_backup}" "${_backup_file}"
            # Record what this database was started from (scratch, or a named
            # backup) alongside the archive itself — a plain sidecar file, not
            # baked into the archive, so it's readable without a mongorestore
            # round-trip. "unknown" if setup.sh never left a marker (older
            # database, or one that never went through the interactive wizard).
            _started_from="unknown"
            [[ -f "${MONGO_LINEAGE_FILE}" ]] && _started_from="$(cat "${MONGO_LINEAGE_FILE}")"
            echo "started_from=${_started_from}" > "${_backup_file}.meta"
            ok "  Backed up MongoDB to ${_backup_file} ($(du -h "${_backup_file}" 2>/dev/null | cut -f1), started from: ${_started_from})"
            say "  ${DIM}setup.sh (interactive, no --restart) will list this alongside any older backups next time.${NC}"
            # Prune to the newest MONGO_BACKUP_RETAIN — ls -1t sorts newest
            # first (mtime, but these filenames also sort identically since
            # they're UTC timestamps), so anything past the head is old.
            _old_backups="$(ls -1t "${MONGO_BACKUP_DIR}"/mongodb-*.archive.gz 2>/dev/null | tail -n "+$((MONGO_BACKUP_RETAIN + 1))" || true)"
            if [[ -n "${_old_backups}" ]]; then
                while IFS= read -r _old; do
                    [[ -z "${_old}" ]] && continue
                    rm -f "${_old}" "${_old}.meta" && say "  ${DIM}Pruned older backup: $(basename "${_old}") (keeping newest ${MONGO_BACKUP_RETAIN})${NC}"
                done <<< "${_old_backups}"
            fi
            unset _old_backups _old _started_from
        else
            rm -f "${_tmp_backup}"
            warn "  mongodump failed or produced an empty archive — skipping this backup."
            warn "  Any previously saved backups in ${MONGO_BACKUP_DIR} were left untouched."
        fi
        unset _backup_file _tmp_backup _mongo_user _mongo_pass
    fi
fi

# ── Teardown helper ───────────────────────────────────────────────────────────
# teardown_compose PROJECT COMPOSE_DIR FILE [FILE ...]
#   Stops and removes all containers + declared volumes for a compose project.
#   Falls back to label-based removal if any compose file is missing.
teardown_compose() {
    local project="$1"
    local compose_dir="$2"
    shift 2
    local compose_file_args=()

    # Verify ownership before touching anything in this project.
    if ! project_is_ours "${project}"; then
        warn "  Skipping project '${project}' — see error above."
        return 0
    fi

    # Check whether every supplied compose file actually exists.
    local all_exist=1
    for f in "$@"; do
        if [[ -f "${f}" ]]; then
            compose_file_args+=(-f "${f}")
        else
            all_exist=0
            warn "  Compose file not found: ${f}"
        fi
    done

    local down_args=(down -v --remove-orphans)
    if [[ "${KEEP_LANGFUSE_TRACES}" -eq 1 && "${project}" == "ace-langfuse-${INST}" ]]; then
        down_args=(down --remove-orphans)
    fi

    if [[ "${all_exist}" -eq 1 && ${#compose_file_args[@]} -gt 0 ]]; then
        if ( cd "${compose_dir}" && \
             COMPOSE_PROJECT_NAME="${project}" \
             docker compose "${compose_file_args[@]}" \
             --env-file "${ENV_FILE}" \
             "${down_args[@]}" 2>/dev/null ); then
            if [[ "${down_args[*]}" == "down --remove-orphans" ]]; then
                ok "  Project '${project}' stopped; preserved requested Langfuse data volumes."
                _remove_project_volumes_except_kept "${project}"
            else
                ok "  Project '${project}' stopped and volumes removed."
            fi
            return 0
        else
            warn "  'docker compose down' failed for '${project}' — falling back to label-based removal."
        fi
    fi

    # Fallback: remove by project label (handles stopped containers too).
    _remove_by_label "${project}"
}

volume_should_be_kept() {
    local vname="$1"
    if [[ "${vname}" == "${_OLLAMA_MODELS_VOL}" && "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
        return 0
    fi
    if langfuse_trace_volume "${vname}" && [[ "${KEEP_LANGFUSE_TRACES}" -eq 1 ]]; then
        return 0
    fi
    return 1
}

_remove_project_volumes_except_kept() {
    local project="$1"
    while IFS= read -r vname; do
        [[ -z "${vname}" ]] && continue
        if volume_should_be_kept "${vname}"; then
            ok "  Kept volume: ${vname}"
            continue
        fi
        if docker volume rm "${vname}" >/dev/null 2>&1; then
            ok "  Removed volume: ${vname}"
        else
            warn "  Could not remove volume: ${vname} (may still be in use)"
        fi
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep "^${project}_" || true)
}

# Remove all containers in a compose project by label, then prune their volumes.
_remove_by_label() {
    local project="$1"
    local did_something=0

    while IFS= read -r cname; do
        [[ -z "${cname}" ]] && continue
        if docker rm -f "${cname}" >/dev/null 2>&1; then
            ok "  Removed container: ${cname}"
            did_something=1
        else
            warn "  Could not remove container: ${cname}"
        fi
    done < <(docker ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true)

    while IFS= read -r vname; do
        [[ -z "${vname}" ]] && continue
        if volume_should_be_kept "${vname}"; then
            ok "  Kept volume: ${vname}"
            did_something=1
            continue
        fi
        if docker volume rm "${vname}" >/dev/null 2>&1; then
            ok "  Removed volume: ${vname}"
            did_something=1
        else
            warn "  Could not remove volume: ${vname} (may still be in use)"
        fi
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep "^${project}_" || true)

    [[ "${did_something}" -eq 0 ]] && say "  ${DIM}Nothing found for project '${project}'.${NC}"
}

# Explicitly remove a single named volume if it exists.
remove_volume() {
    local vname="$1"
    if docker volume inspect "${vname}" >/dev/null 2>&1; then
        if docker volume rm "${vname}" >/dev/null 2>&1; then
            ok "  Removed volume: ${vname}"
        else
            warn "  Could not remove volume: ${vname} (may still be in use)"
        fi
    else
        say "  ${DIM}Volume '${vname}' not found.${NC}"
    fi
}

# ── 1. Certifier ──────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ Certifier stack (ace-certifier-${INST})${NC}"
teardown_compose \
    "ace-certifier-${INST}" \
    "${REPO_ROOT}/certifier" \
    "${REPO_ROOT}/certifier/docker-compose.yml" \
    "${REPO_ROOT}/compose/certifier.override.yml"

# ── 2. LiteLLM ───────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ LiteLLM stack (ace-litellm-${INST})${NC}"
_LITELLM_DIR="${REPO_ROOT}/agentcert-stack/litellm-setup"
teardown_compose \
    "ace-litellm-${INST}" \
    "${_LITELLM_DIR}" \
    "${_LITELLM_DIR}/docker-compose-litellm.yml" \
    "${REPO_ROOT}/compose/litellm.override.yml"
unset _LITELLM_DIR

# ── 3. Langfuse ──────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ Langfuse stack (ace-langfuse-${INST})${NC}"
# start-local-services.sh always clones into .tmp/langfuse — use the same path.
_LANGFUSE_DIR="${REPO_ROOT}/.tmp/langfuse"
teardown_compose \
    "ace-langfuse-${INST}" \
    "${_LANGFUSE_DIR}" \
    "${_LANGFUSE_DIR}/docker-compose.yml" \
    "${REPO_ROOT}/compose/langfuse.override.yml"
unset _LANGFUSE_DIR

# ── 4. Root compose stack (MongoDB, auth, graphql, web, workspace-init …) ────
echo
say "${CYAN}▸ Root stack (ace-${INST}: MongoDB, auth, graphql, web…)${NC}"
# The root docker-compose.yml carries  name: ace-${ACE_INSTANCE_NAME}  so we
# pass --env-file instead of COMPOSE_PROJECT_NAME to let Compose resolve it
# from the file itself (which is how setup.sh originally created everything).
if project_is_ours "ace-${INST}"; then
    _ROOT_DOWN_ARGS=(down -v --remove-orphans)
    _ROOT_KEEPS_VOLUME=0
    if [[ "${KEEP_OLLAMA_MODEL}" -eq 1 ]] && docker volume inspect "${_OLLAMA_MODELS_VOL}" >/dev/null 2>&1; then
        _ROOT_KEEPS_VOLUME=1
    elif [[ "${KEEP_LANGFUSE_TRACES}" -eq 1 ]] && docker volume ls --format '{{.Name}}' 2>/dev/null \
            | grep -qE "^ace-${INST}_langfuse_(postgres_data|clickhouse_data|clickhouse_logs|minio_data|redis_data)$"; then
        _ROOT_KEEPS_VOLUME=1
    fi
    if [[ "${_ROOT_KEEPS_VOLUME}" -eq 1 ]]; then
        _ROOT_DOWN_ARGS=(down --remove-orphans)
    fi
    if ( cd "${REPO_ROOT}" && \
         docker compose -f docker-compose.yml \
         --env-file "${ENV_FILE}" \
         "${_ROOT_DOWN_ARGS[@]}" 2>/dev/null ); then
        if [[ "${_ROOT_DOWN_ARGS[*]}" == "down --remove-orphans" ]]; then
            ok "  Root stack stopped; preserved requested data volumes."
            _remove_project_volumes_except_kept "ace-${INST}"
            remove_volume "mongodb_data-${INST}"
        else
            ok "  Root stack stopped and volumes removed."
        fi
    else
        warn "  'docker compose down' failed for root stack — falling back to label-based removal."
        _remove_by_label "ace-${INST}"
    fi
    unset _ROOT_DOWN_ARGS _ROOT_KEEPS_VOLUME
else
    warn "  Skipping root stack — see ownership error above."
fi

# ── 5. Ollama (standalone container — started with docker run, not compose) ───
echo
say "${CYAN}▸ Ollama (standalone)${NC}"
_OLLAMA_CONT="ollama-${INST}"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${_OLLAMA_CONT}"; then
    # Ollama is started with docker run; it carries no compose project label,
    # so ownership is implicit from the name encoding ACE_INSTANCE_NAME.
    if docker rm -f "${_OLLAMA_CONT}" >/dev/null 2>&1; then
        ok "  Removed container: ${_OLLAMA_CONT}"
    else
        warn "  Could not remove container: ${_OLLAMA_CONT}"
    fi
else
    say "  ${DIM}Container '${_OLLAMA_CONT}' not found.${NC}"
fi
unset _OLLAMA_CONT

# The ollama-models volume has an explicit name: override in docker-compose.yml
# (name: ollama-models-${ACE_INSTANCE_NAME}) which bypasses the compose project
# prefix, so it may not have been removed by the root compose down above.
if [[ "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
    ok "  Kept volume: ${_OLLAMA_MODELS_VOL} ${DIM}(--keep-ollama-model)${NC}"
else
    remove_volume "${_OLLAMA_MODELS_VOL}"
fi

# ── 6. KinD cluster ───────────────────────────────────────────────────────────
echo
say "${CYAN}▸ KinD cluster${NC}"
_OWNER_MARKER="ace-kind-owner-${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    _cluster_owner="$(docker volume inspect "${_OWNER_MARKER}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_cluster_owner}" "${REPO_ROOT}"; then
        if kind delete cluster --name "${KIND_CLUSTER_NAME}"; then
            ok "  Deleted KinD cluster: ${KIND_CLUSTER_NAME}"
        else
            warn "  Failed to delete KinD cluster: ${KIND_CLUSTER_NAME}"
        fi
        # Remove the ownership marker regardless of whether kind delete succeeded.
        docker volume rm "${_OWNER_MARKER}" >/dev/null 2>&1 \
            && ok "  Removed ownership marker volume: ${_OWNER_MARKER}" || true
    else
        warn "  Cluster '${KIND_CLUSTER_NAME}' is owned by a different checkout"
        warn "  (owner: ${_cluster_owner:-none}). Skipping."
    fi
    unset _cluster_owner
else
    say "  ${DIM}KinD cluster '${KIND_CLUSTER_NAME}' not found.${NC}"
    # Remove a stale ownership marker that points to us (cluster already gone).
    _stale_owner="$(docker volume inspect "${_OWNER_MARKER}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_stale_owner}" "${REPO_ROOT}"; then
        docker volume rm "${_OWNER_MARKER}" >/dev/null 2>&1 \
            && ok "  Removed stale ownership marker: ${_OWNER_MARKER}" || true
    fi
    unset _stale_owner
fi
unset _OWNER_MARKER

# ── 7. Final verification ─────────────────────────────────────────────────────
echo
say "${CYAN}▸ Verification${NC}"

_remaining_containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E \
    "^(agentcert-mongo|ace-mongo-keyfile|ace-mongo-init|ace-cluster-init|ace-workspace-init|agentcert-auth|agentcert-graphql|agentcert-web)-${INST}$|\
^(litellm-proxy|ollama)-${INST}$|\
^certifier_app_${INST}$" || true)"

# Also check Langfuse containers via project label
_remaining_langfuse="$(docker ps -a \
    --filter "label=com.docker.compose.project=ace-langfuse-${INST}" \
    --format '{{.Names}}' 2>/dev/null || true)"

_remaining_volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E \
    "^(ace-${INST}_|ace-langfuse-${INST}_|ace-litellm-${INST}_|ace-certifier-${INST}_|ollama-models-${INST}$)" \
    || true)"
if [[ "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
    _remaining_volumes="$(echo "${_remaining_volumes}" | grep -vx "${_OLLAMA_MODELS_VOL}" || true)"
fi
if [[ "${KEEP_LANGFUSE_TRACES}" -eq 1 ]]; then
    _remaining_volumes="$(echo "${_remaining_volumes}" | grep -Ev "^(ace-${INST}|ace-langfuse-${INST})_langfuse_(postgres_data|clickhouse_data|clickhouse_logs|minio_data|redis_data)$" || true)"
fi

_all_remaining="${_remaining_containers}${_remaining_langfuse}${_remaining_volumes}"

if [[ -z "${_all_remaining}" ]]; then
    ok "All ACE resources for instance '${INST}' have been removed from this host."
else
    warn "Some resources could not be removed (check errors above):"
    for _r in ${_remaining_containers} ${_remaining_langfuse}; do
        [[ -n "${_r}" ]] && warn "  container: ${_r}"
    done
    for _r in ${_remaining_volumes}; do
        [[ -n "${_r}" ]] && warn "  volume:    ${_r}"
    done
fi
unset _remaining_containers _remaining_langfuse _remaining_volumes _all_remaining

echo
say "${BOLD}Teardown complete.${NC}"
say "${DIM}Docker images were NOT removed. To free image disk space:${NC}"
say "${DIM}  docker rmi agentcert/certifier:latest agentcert/agentcert-flash-agent:latest \\"
say "           agentcert/agent-sidecar:latest agentcert/agentcert-install-agent:latest \\"
say "           agentcert/agentcert-install-app:latest agentcert/cluster-init:latest${NC}"
echo
