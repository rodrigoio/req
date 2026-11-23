#!/usr/bin/env bash
# env.sh - environments and variables.
#
# A project keeps the variables of each environment in the central directory (home.sh), as a "key=value" file
# in a folder of the environment: $REQ_CONFIG_DIR/projects/<id>/env/<env>/vars. Nothing is shared between
# environments.
# An invalid file is only reported, never fixed or overwritten. The old format ($REQ_CONFIG_DIR/env/<env>/secrets.json)
# is not read and not migrated.

declare -gA REQ_VARS=()      # variables of the last loaded environment (key -> value)

req_env_dir() {
    req_project_state_dir "$1" "env/$2"
}

req_env_file() {
    req_project_state_dir "$1" "env/$2/vars"
}

req_env_legacy_file() {
    printf '%s/env/%s/secrets.json' "$(req_config_dir)" "$1"
}

# shellcheck disable=SC2034  # REQ_VARS is read by the callers
# req_vars_load <env> [project id] - loads the variables of the environment (its `vars` file, in the project
# given, by default REQ_PROJECT_ID) into REQ_VARS; no other file is read. A missing file is fine; without a
# project nothing is loaded. An invalid file reports every problem with its absolute path, leaves REQ_VARS
# empty and returns 1. A leftover secrets.json gets a warning that says where the variables live now.
req_vars_load() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file legacy line
    local -A seen=()
    REQ_VARS=()
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    legacy=$(req_env_legacy_file "$env")
    [[ -f $legacy ]] && req_warn "$(req_abs_path "$legacy") is no longer read: put its variables as key=value lines in $(req_abs_path "$(req_env_file "${id:-<project>}" "$env")")"
    [[ -n $id ]] || return 0
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }

    file=$(req_env_file "$id" "$env")
    req_kv_check "$file" || return 1
    while IFS= read -r line; do
        req_kv_parse_line "$line" || continue
        [[ -n ${seen[$REQ_KV_KEY]+x} ]] && continue     # the first line of a key wins
        seen[$REQ_KV_KEY]=1
        REQ_VARS[$REQ_KV_KEY]=$REQ_KV_VALUE
    done < <(req_kv_list "$file")
    return 0
}

# req_env_var_name <env> <key> - the process variable that overrides a key in an environment: both in
# capitals, hyphens of the environment as underscores ("pre-prod" and "token" give PRE_PROD_TOKEN).
req_env_var_name() {
    local env=${1^^} key=${2^^}
    printf '%s_%s' "${env//-/_}" "$key"
}

REQ_RESOLVED=""        # the value found by req_resolve_key_var

# shellcheck disable=SC2034  # REQ_RESOLVED is read by req_resolve_key and req_subst
# req_resolve_key_var <env> <key> - the engine of req_resolve_key, with no subshell: the value goes in
# REQ_RESOLVED and the status is 0, or the status is 1 with it empty. Precedence: the process variable
# <ENV>_<KEY>, then the environment's variables (REQ_VARS, so req_vars_load <env> must have run). A set but empty process variable counts as a value.
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

req_resolve_key() {
    req_resolve_key_var "$1" "$2" || return 1
    printf '%s\n' "$REQ_RESOLVED"
}

REQ_SUBST_OUT=""        # the text produced by req_subst

# req_subst_fail <env> <project id> <key>... - the error for keys with no value: one line listing them and,
# for each, the process variable and the file of the environment that would define it.
req_subst_fail() {
    local env=$1 id=$2 key list="" where=""
    shift 2
    for key in "$@"; do list+=", $key"; done
    req_err "no value for ${list#, } in environment \"$env\""
    if [[ -n $id ]] && req_valid_name "$id"; then
        where=$(req_abs_path "$(req_env_file "$id" "$env")")
    fi
    for key in "$@"; do
        printf '  %s: set the variable %s' "$key" "$(req_env_var_name "$env" "$key")" >&2
        [[ -z $where ]] || printf ', or add %s=... to %s' "$key" "$where" >&2
        printf '\n' >&2
    done
}

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst <text> <env> [project id] - replaces every ${key} by its value (req_resolve_key_var) into
# REQ_SUBST_OUT, so trailing line breaks survive. A value is never expanded again and any other ${...} is
# left alone. With some keys missing nothing is replaced: the status is 1, REQ_SUBST_OUT is empty and one
# error lists each missing key once, in order, and how to define it.
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

# The fields of a request that go to curl, where req_subst_json works; property names are never substituted.
REQ_SUBST_FIELDS='["url","headers","query","parameters","raw_data","files"]'

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst_json <request json> <env> [project id] - req_subst for a request: every ${key} in the string
# values of REQ_SUBST_FIELDS (also inside a raw_data that is native JSON) is replaced and the result, still
# valid JSON, goes to REQ_SUBST_OUT; other fields are left alone. The keys are resolved first: with any
# missing, nothing is replaced, the status is 1 and req_subst_fail lists them all.
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

# req_env_list [project id] - the project's environments (the slug-named folders of projects/<id>/env/), one
# per line, sorted. Nothing without a project or a folder.
req_env_list() {
    local id=${1-$REQ_PROJECT_ID} dir f name
    [[ -n $id ]] || return 0
    dir=$(req_project_state_dir "$id" env)
    [[ -d $dir ]] || return 0
    for f in "$dir"/*; do
        [[ -d $f ]] || continue
        name=${f##*/}
        req_valid_name "$name" && printf '%s\n' "$name"
    done | LC_ALL=C sort
}

# req_env_exists <env> [project id] - the environment can be used: it has a folder in the project, or it is
# "default", which needs none.
req_env_exists() {
    local env=$1 id=${2-$REQ_PROJECT_ID}
    req_valid_name "$env" || return 1
    [[ $env == default ]] && return 0
    [[ -n $id && -d $(req_env_dir "$id" "$env") ]]
}

# req_env_ensure_dir [project id] - makes projects/<id>/env, private (0700); already there is fine. The
# error carries the absolute path.
req_env_ensure_dir() {
    local id=${1-$REQ_PROJECT_ID} dir
    [[ -n $id ]] || { req_err "no project is open, so there is no folder for its environments"; return 1; }
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }
    dir=$(req_project_state_dir "$id" env)
    [[ -d $dir ]] && return 0
    (umask 077; mkdir -p "$dir") 2>/dev/null || { req_err "cannot create $(req_abs_path "$dir")"; return 1; }
}

# req_env_create <env> [project id] - makes the environment's folder, private (0700), with a private (0600)
# `vars` file in it that starts with req_vars_template. An existing environment is left exactly as it is
# (status 0); something that is not a folder in its place is an error.
req_env_create() {
    local env=$1 id=${2-$REQ_PROJECT_ID} dir abs file
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    req_env_ensure_dir "$id" || return 1
    dir=$(req_env_dir "$id" "$env")
    abs=$(req_abs_path "$dir")
    [[ -d $dir ]] && return 0
    [[ ! -e $dir && ! -L $dir ]] || { req_err "$abs exists and is not a folder"; return 1; }
    (umask 077; mkdir "$dir") 2>/dev/null || { [[ -d $dir ]] && return 0; req_err "cannot create $abs"; return 1; }
    file=$(req_env_file "$id" "$env")
    (umask 077; req_vars_template "$env" >"$file") 2>/dev/null || { req_err "cannot create $(req_abs_path "$file")"; return 1; }
}

# shellcheck disable=SC2016  # the ${key} and ${host} in the quotes are text for the user, not expansions
# req_vars_template <env> - the text a new `vars` file starts with: comment lines that show the format (the
# loader ignores them, so a new file has no variables), ending with a blank line, because in vim `o` after a
# comment line continues the comment. Quoted strings and not a heredoc: the single-file build drops
# full-line comments, and a heredoc line that starts with # would look like one to the test of the built
# file.
req_vars_template() {
    printf '%s\n' \
        "# Variables of environment $1: they are loaded when it is the environment in use." \
        '# One per line, key=value: the key uses letters, digits and underscores; the value is the rest of the line.' \
        '# Lines that start with # are comments. A request uses a variable as ${key}, for example ${host}/users.' \
        '#' \
        '# host=https://api.example.com' \
        ''
}

# req_vars_create <env> [project id] - makes the environment's `vars` file when it is missing (with its folder,
# req_env_create, when that is missing too). An existing file is left as it is, even empty (noclobber);
# something that is not a regular file is an error. The error carries the absolute path.
req_vars_create() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file abs
    [[ -n $id ]] || { req_err "no project is open, so there are no variables to make"; return 1; }
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    file=$(req_env_file "$id" "$env")
    abs=$(req_abs_path "$file")
    [[ -f $file ]] && return 0
    [[ ! -e $file && ! -L $file ]] || { req_err "$abs exists and is not a file"; return 1; }
    req_env_create "$env" "$id" || return 1
    [[ -f $file ]] && return 0
    (umask 077; set -o noclobber; req_vars_template "$env" >"$file") 2>/dev/null ||
        { req_err "cannot create $abs"; return 1; }
}

declare -ga REQ_ENV_CHOICES=()      # the environments to choose from (req_env_choices)

# shellcheck disable=SC2034  # REQ_ENV_CHOICES is read by the environment menu
# req_env_choices [project id] - fills REQ_ENV_CHOICES with the environments one can switch to: "default"
# first, which is always there with or without a file, then req_env_list without repeats.
req_env_choices() {
    local id=${1-$REQ_PROJECT_ID} name
    REQ_ENV_CHOICES=(default)
    while IFS= read -r name; do
        [[ -z $name || $name == default ]] || REQ_ENV_CHOICES+=("$name")
    done < <(req_env_list "$id")
    return 0
}
