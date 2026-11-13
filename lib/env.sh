#!/usr/bin/env bash
# env.sh - environments and secrets.
#
# A project keeps its variables in the central directory (see home.sh):
#   $REQ_CONFIG_DIR/projects/<id>/vars        variables shared by every environment
#   $REQ_CONFIG_DIR/projects/<id>/env/<env>   variables of one environment
# Both are plain "key=value" files. The environment wins over the project variables.
# An invalid file is only reported, never fixed or overwritten. The old format
# ($REQ_CONFIG_DIR/env/<env>/secrets.json, T5.1) is not read and not migrated.

declare -gA REQ_SECRETS=()      # variables of the last loaded environment (key -> value)

# req_env_file <project id> <env> - path of the file of an environment.
req_env_file() {
    req_project_state_dir "$1" "env/$2"
}

# req_vars_file <project id> - path of the project variables.
req_vars_file() {
    req_project_state_dir "$1" vars
}

# req_env_legacy_file <env> - path of the T5.1 secrets file, which is no longer read.
req_env_legacy_file() {
    printf '%s/env/%s/secrets.json' "$(req_config_dir)" "$1"
}

# shellcheck disable=SC2034  # REQ_SECRETS is read by the callers
# req_secrets_load <env> [project id] - loads the variables of the project (default: the
# one in REQ_PROJECT_ID) and then those of the environment into REQ_SECRETS, so the
# environment wins. A missing file is not an error. Without a project (its state could
# not be saved) nothing is loaded. If a file is invalid, every problem is reported with
# its absolute path, REQ_SECRETS stays empty and the status is 1. When the old
# secrets.json of the environment exists, a warning says where the variables live now.
req_secrets_load() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file legacy line
    local -A loaded=()
    REQ_SECRETS=()
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    legacy=$(req_env_legacy_file "$env")
    [[ -f $legacy ]] && req_warn "$(req_abs_path "$legacy") is no longer read: put its variables as key=value lines in $(req_abs_path "$(req_env_file "${id:-<project>}" "$env")")"
    [[ -n $id ]] || return 0
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }

    local -a files=("$(req_vars_file "$id")" "$(req_env_file "$id" "$env")")
    local status=0
    for file in "${files[@]}"; do req_kv_check "$file" || status=1; done
    (( status )) && return 1

    local -A seen=()
    for file in "${files[@]}"; do
        seen=()
        while IFS= read -r line; do
            req_kv_parse_line "$line" || continue
            [[ -n ${seen[$REQ_KV_KEY]+x} ]] && continue     # the first line of a key wins
            seen[$REQ_KV_KEY]=1
            loaded[$REQ_KV_KEY]=$REQ_KV_VALUE
        done < <(req_kv_list "$file")
    done
    local k
    for k in "${!loaded[@]}"; do REQ_SECRETS[$k]=${loaded[$k]}; done
    return 0
}

# req_env_var_name <env> <key> - the name of the process variable that overrides a key in
# an environment: both in capitals, hyphens of the environment turned into underscores
# ("dev" and "url" give DEV_URL, "pre-prod" and "token" give PRE_PROD_TOKEN).
req_env_var_name() {
    local env=${1^^} key=${2^^}
    printf '%s_%s' "${env//-/_}" "$key"
}

# req_resolve_key <env> <key> - prints the value of a key for an environment and succeeds,
# or fails (printing nothing) when nothing defines it. Precedence: the process variable
# <ENV>_<KEY> (req_env_var_name), then the environment file, then the project variables;
# the last two come from REQ_SECRETS, so req_secrets_load <env> must have run for that
# environment. A set but empty process variable counts as a value.
req_resolve_key() {
    local env=$1 key=$2 name
    req_kv_valid_key "$key" || return 1
    name=$(req_env_var_name "$env" "$key")
    if [[ -n ${!name+x} ]]; then
        printf '%s\n' "${!name}"
    elif [[ -n ${REQ_SECRETS[$key]+x} ]]; then
        printf '%s\n' "${REQ_SECRETS[$key]}"
    else
        return 1
    fi
}
