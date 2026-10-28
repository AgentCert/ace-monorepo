# shellcheck shell=bash
# =============================================================================
# model_registry.sh — the .env settings behind the LLM Models registry.
# =============================================================================
# With LITELLM_DATABASE_URL and LITELLM_SALT_KEY both set, LiteLLM stores the
# models projects add from the UI, and their API keys, in a database named
# litellm on Langfuse's Postgres (it creates the database itself). The Helm
# chart and docker-compose.yml turn the registry on only when both are set.
# Sourced by scripts/setup.sh; it only defines functions.
# =============================================================================

# model_registry_new_salt — 32 random bytes as hex.
model_registry_new_salt() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }

# model_registry_database_url USER PASSWORD — LiteLLM's database on the
# Postgres both deploy paths name "postgres".
model_registry_database_url() { printf 'postgresql://%s:%s@postgres:5432/litellm' "$1" "$2"; }

# model_registry_env GET SET NEW_SALT — fill in the registry's .env keys.
# GET KEY prints a value and SET KEY VALUE writes one (setup.sh: cur, set_env),
# so tests can run this against a scratch file.
model_registry_env() {
    local get="$1" set="$2" new_salt="$3" url
    # The salt key encrypts every stored API key: generated once, never
    # replaced. A new one would make every stored key unreadable.
    if [[ -z "$("${get}" LITELLM_SALT_KEY)" ]]; then
        "${set}" LITELLM_SALT_KEY "$("${new_salt}")"
    fi
    url="$("${get}" LITELLM_DATABASE_URL)"
    # A URL naming another server is the user's own database: keep it.
    [[ -z "${url}" || "${url}" == *"@postgres:5432/litellm" ]] || return 0
    if [[ "$("${get}" LITELLM_MODE)" == external ]]; then
        # ACE does not run that gateway; whether it has a database is its own.
        "${set}" LITELLM_DATABASE_URL ""
    else
        # Re-derived on every run, so it follows POSTGRES_USER/PASSWORD.
        "${set}" LITELLM_DATABASE_URL "$(model_registry_database_url "$("${get}" POSTGRES_USER)" "$("${get}" POSTGRES_PASSWORD)")"
    fi
}
