#!/usr/bin/env bash
# env.sh - environments and variables.
#
# A project keeps its variables in the central directory (see home.sh):
#   $REQ_CONFIG_DIR/projects/<id>/vars        variables shared by every environment
#   $REQ_CONFIG_DIR/projects/<id>/env/<env>   variables of one environment
# Both are plain "key=value" files. The environment wins over the project variables.
# An invalid file is only reported, never fixed or overwritten. The old format
# ($REQ_CONFIG_DIR/env/<env>/secrets.json, T5.1) is not read and not migrated.

declare -gA REQ_VARS=()      # variables of the last loaded environment (key -> value)

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

# shellcheck disable=SC2034  # REQ_VARS is read by the callers
# req_vars_load <env> [project id] - loads the variables of the project (default: the
# one in REQ_PROJECT_ID) and then those of the environment into REQ_VARS, so the
# environment wins. A missing file is not an error. Without a project (its state could
# not be saved) nothing is loaded. If a file is invalid, every problem is reported with
# its absolute path, REQ_VARS stays empty and the status is 1. When the old
# secrets.json of the environment exists, a warning says where the variables live now.
req_vars_load() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file legacy line
    local -A loaded=()
    REQ_VARS=()
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
    for k in "${!loaded[@]}"; do REQ_VARS[$k]=${loaded[$k]}; done
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
# the environment file, then the project variables; the last two come from REQ_VARS,
# so req_vars_load <env> must have run for that environment. A set but empty process
# variable counts as a value.
req_resolve_key_var() {
    local env=$1 key=$2 name
    REQ_RESOLVED=""
    req_kv_valid_key "$key" || return 1
    name=$(req_env_var_name "$env" "$key")
    if [[ -n ${!name+x} ]]; then
        REQ_RESOLVED=${!name}
    elif [[ -n ${REQ_VARS[$key]+x} ]]; then
        REQ_RESOLVED=${REQ_VARS[$key]}
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

# req_subst_fail <env> <project id> <key>... - the error for keys that have no value: one
# line listing them and, for each, the process variable and the files of the project's
# environment that would define it (the files only when there is a project).
req_subst_fail() {
    local env=$1 id=$2 key list="" where=""
    shift 2
    for key in "$@"; do list+=", $key"; done
    req_err "no value for ${list#, } in environment \"$env\""
    if [[ -n $id ]] && req_valid_name "$id"; then
        where="$(req_abs_path "$(req_env_file "$id" "$env")") (or $(req_abs_path "$(req_vars_file "$id")") for every environment)"
    fi
    for key in "$@"; do
        printf '  %s: set the variable %s' "$key" "$(req_env_var_name "$env" "$key")" >&2
        [[ -z $where ]] || printf ', or add %s=... to %s' "$key" "$where" >&2
        printf '\n' >&2
    done
}

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst <text> <env> [project id] - replaces every ${key} (a valid key name between
# braces) in the text by its value in the environment (req_resolve_key_var) and puts the
# result in REQ_SUBST_OUT, so trailing line breaks survive. A value is never expanded
# again, and anything else that looks like ${...} is left as it is. When some keys have no
# value nothing is replaced: the status is 1, REQ_SUBST_OUT is empty and one error lists
# every missing key (once each, in order of appearance) and says how to define it: the
# process variable and the files of the project's environment.
req_subst() {
    local rest=$1 env=$2 id=${3-$REQ_PROJECT_ID} out="" token key
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
        req_subst_fail "$env" "$id" "${missing[@]}"
        return 1
    fi
    REQ_SUBST_OUT=$out$rest
}

# The executable fields of a request (the ones sent to curl), where req_subst_json works.
# Names of properties are never substituted, only values.
REQ_SUBST_FIELDS='["url","headers","query","parameters","raw_data"]'

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst_json <request json> <env> [project id] - like req_subst, for a request: every
# ${key} in the string values of url, headers, query, parameters and raw_data (also the
# strings inside a raw_data that is native JSON) is replaced, and the result, still valid
# JSON, goes to REQ_SUBST_OUT. Other fields (name, description) are left alone. The keys
# are resolved first: when some are missing, nothing is replaced, the status is 1 and
# req_subst_fail lists them all.
req_subst_json() {
    local json=$1 env=$2 id=${3-$REQ_PROJECT_ID} key map='{}'
    local -a missing=()
    local -A seen=()
    REQ_SUBST_OUT=$json
    while IFS= read -r key; do
        [[ -n $key && -z ${seen[$key]+x} ]] || continue
        seen[$key]=1
        if req_resolve_key_var "$env" "$key"; then
            map=$(jq -c --arg k "$key" --arg v "$REQ_RESOLVED" '. + {($k): $v}' <<<"$map")
        else
            missing+=("$key")
        fi
    done < <(jq -r --argjson f "$REQ_SUBST_FIELDS" '
        [to_entries[] | select(.key | IN($f[])) | .value | .. | strings
         | scan("\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}") | .[0]] | .[]' <<<"$json")
    if (( ${#missing[@]} > 0 )); then
        REQ_SUBST_OUT=""
        req_subst_fail "$env" "$id" "${missing[@]}"
        return 1
    fi
    (( ${#seen[@]} > 0 )) || return 0
    REQ_SUBST_OUT=$(jq -c --argjson m "$map" --argjson f "$REQ_SUBST_FIELDS" '
        def fill: walk(if type == "string"
                       then gsub("\\$\\{(?<k>[A-Za-z_][A-Za-z0-9_]*)\\}"; $m[.k]) else . end);
        with_entries(if (.key | IN($f[])) then .value |= fill else . end)' <<<"$json")
}

# req_env_list [project id] - prints the names of the project's environments (the files
# in projects/<id>/env/ whose name is a slug), one per line, sorted. Nothing without a
# project or a folder.
req_env_list() {
    local id=${1-$REQ_PROJECT_ID} dir f name
    [[ -n $id ]] || return 0
    dir=$(req_project_state_dir "$id" env)
    [[ -d $dir ]] || return 0
    for f in "$dir"/*; do
        [[ -f $f ]] || continue
        name=${f##*/}
        req_valid_name "$name" && printf '%s\n' "$name"
    done | LC_ALL=C sort
}

# req_env_exists <env> [project id] - succeeds when the environment can be used: it has a
# file in the project, or it is "default", which needs none.
req_env_exists() {
    local env=$1 id=${2-$REQ_PROJECT_ID}
    req_valid_name "$env" || return 1
    [[ $env == default ]] && return 0
    [[ -n $id && -f $(req_env_file "$id" "$env") ]]
}
