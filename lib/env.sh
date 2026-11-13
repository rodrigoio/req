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

REQ_RESOLVED=""        # the value found by req_resolve_key_var

# shellcheck disable=SC2034  # REQ_RESOLVED is read by req_resolve_key and req_subst
# req_resolve_key_var <env> <key> - the engine of req_resolve_key, with no subshell: puts
# the value in REQ_RESOLVED and succeeds, or fails (REQ_RESOLVED empty) when nothing
# defines the key. Precedence: the process variable <ENV>_<KEY> (req_env_var_name), then
# the environment file, then the project variables; the last two come from REQ_SECRETS,
# so req_secrets_load <env> must have run for that environment. A set but empty process
# variable counts as a value.
req_resolve_key_var() {
    local env=$1 key=$2 name
    REQ_RESOLVED=""
    req_kv_valid_key "$key" || return 1
    name=$(req_env_var_name "$env" "$key")
    if [[ -n ${!name+x} ]]; then
        REQ_RESOLVED=${!name}
    elif [[ -n ${REQ_SECRETS[$key]+x} ]]; then
        REQ_RESOLVED=${REQ_SECRETS[$key]}
    else
        return 1
    fi
}

# req_resolve_key <env> <key> - prints the value of a key (see req_resolve_key_var) and
# succeeds, or fails printing nothing.
req_resolve_key() {
    req_resolve_key_var "$1" "$2" || return 1
    printf '%s\n' "$REQ_RESOLVED"
}

REQ_SUBST_OUT=""        # the text produced by req_subst

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst <text> <env> [project id] - replaces every ${key} (a valid key name between
# braces) in the text by its value in the environment (req_resolve_key_var) and puts the
# result in REQ_SUBST_OUT, so trailing line breaks survive. A value is never expanded
# again, and anything else that looks like ${...} is left as it is. When some keys have no
# value nothing is replaced: the status is 1, REQ_SUBST_OUT is empty and one error lists
# every missing key (once each, in order of appearance) and says how to define it: the
# process variable and the files of the project's environment.
req_subst() {
    local rest=$1 env=$2 id=${3-$REQ_PROJECT_ID} out="" token key list="" where=""
    local -a missing=()
    local -A seen=()
    REQ_SUBST_OUT=""
    while [[ $rest =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        token=${BASH_REMATCH[0]}; key=${BASH_REMATCH[1]}
        out+=${rest%%"$token"*}
        if req_resolve_key_var "$env" "$key"; then
            out+=$REQ_RESOLVED
        else
            out+=$token
            [[ -n ${seen[$key]+x} ]] || { seen[$key]=1; missing+=("$key"); }
        fi
        rest=${rest#*"$token"}
    done
    if (( ${#missing[@]} > 0 )); then
        for key in "${missing[@]}"; do list+=", $key"; done
        req_err "no value for ${list#, } in environment \"$env\""
        if [[ -n $id ]] && req_valid_name "$id"; then
            where="$(req_abs_path "$(req_env_file "$id" "$env")") (or $(req_abs_path "$(req_vars_file "$id")") for every environment)"
        fi
        for key in "${missing[@]}"; do
            printf '  %s: set the variable %s' "$key" "$(req_env_var_name "$env" "$key")" >&2
            [[ -z $where ]] || printf ', or add %s=... to %s' "$key" "$where" >&2
            printf '\n' >&2
        done
        return 1
    fi
    REQ_SUBST_OUT=$out$rest
}
