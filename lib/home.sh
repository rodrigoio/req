#!/usr/bin/env bash
# home.sh - the user's central directory (~/.req): projects, configuration, cursor.
#
# Layout (one directory per project; see TASKS.md, "Controle central de projetos"):
#   ~/.req/current                 project=<id>: the project in use
#   ~/.req/config                  global configuration
#   ~/.req/projects/<id>/project   name=<folder name> and path=<absolute path of the project>
#   ~/.req/projects/<id>/config    project configuration (wins over the global one)
#   ~/.req/projects/<id>/vars      project variables
#   ~/.req/projects/<id>/env/<e>   variables of environment <e>
#   ~/.req/projects/<id>/cursor    last position in the menu
# The directory is $REQ_CONFIG_DIR when set (tests use it), otherwise ~/.req.
#
# The first part below holds the "key=value" text files everything in there is made of
# (project settings, variables, environments, configuration, cursor). Format:
#   - one "key=value" per line; the key matches [A-Za-z_][A-Za-z0-9_]*;
#   - blank lines and lines starting with "#" are ignored;
#   - spaces around the key and around the value are not significant, the value is
#     everything after the first "=" (so it may contain "=") and has one line;
#   - no quotes or escapes: the value is the text as it is.
# When a key appears twice, the first line wins; req_kv_set keeps only that one.
# Writing keeps comments, blank lines and the order of the other lines, and the file
# is rewritten in place (mode and symlinks are kept). New files and directories are
# private (0600 and 0700), since they may hold secrets.

REQ_KV_KEY=""       # set by req_kv_parse_line
REQ_KV_VALUE=""

# req_kv_valid_key <key> - succeeds for a valid key name.
req_kv_valid_key() {
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# req_kv_parse_line <line> - puts the key and value of a line in REQ_KV_KEY and
# REQ_KV_VALUE. Fails for blank lines, comments and lines that are not "key=value".
req_kv_parse_line() {
    local line=${1%$'\r'} key value
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* || $line != *=* ]] && return 1
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    req_kv_valid_key "$key" || return 1
    REQ_KV_KEY=$key
    REQ_KV_VALUE=$value
}

# req_kv_get <file> <key> - prints the value of a key. Fails (status 1) when the
# file or the key does not exist.
req_kv_get() {
    local line
    [[ -f $1 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if req_kv_parse_line "$line" && [[ $REQ_KV_KEY == "$2" ]]; then
            printf '%s\n' "$REQ_KV_VALUE"
            return 0
        fi
    done <"$1"
    return 1
}

# req_kv_list <file> - prints every "key=value" in file order, normalized. A missing
# file lists nothing.
req_kv_list() {
    local line
    [[ -f $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        req_kv_parse_line "$line" && printf '%s=%s\n' "$REQ_KV_KEY" "$REQ_KV_VALUE"
    done <"$1"
    return 0
}

# req_kv_check <file> - reports, with the absolute path and the line number, every
# line that is neither blank, a comment nor a valid "key=value". Fails when there is
# any. A missing file is fine.
req_kv_check() {
    local file=$1 line n=0 abs status=0
    [[ -f $file ]] || return 0
    abs=$(req_abs_path "$file")
    while IFS= read -r line || [[ -n $line ]]; do
        n=$(( n + 1 ))
        req_kv_parse_line "$line" && continue
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == \#* ]] && continue
        req_err "$abs:$n: expected key=value (a key uses letters, digits and underscores)"
        status=1
    done <"$file"
    return "$status"
}

# req_kv_rewrite <file> <set|unset> <key> [value] - the engine of set and unset: the
# first line of the key is replaced (set) and the other lines of that key are dropped;
# unset drops them all. Fails with status 1 when unset finds nothing to remove.
req_kv_rewrite() {
    local file=$1 mode=$2 key=$3 value=${4-} tmp line found=0
    tmp=$(mktemp "${file}.XXXXXX") || { req_err "cannot write to $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if req_kv_parse_line "$line" && [[ $REQ_KV_KEY == "$key" ]]; then
            [[ $mode == set && $found == 0 ]] && printf '%s=%s\n' "$key" "$value"
            found=1
            continue
        fi
        printf '%s\n' "$line"
    done <"$file" >"$tmp"
    if (( ! found )); then
        if [[ $mode == unset ]]; then rm -f "$tmp"; return 1; fi
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    cat "$tmp" >"$file" || { rm -f "$tmp"; req_err "cannot write $file"; return 1; }
    rm -f "$tmp"
}

# req_kv_set <file> <key> <value> - sets a key, creating the file (and its directory)
# when needed. The key must be valid and the value must be a single line.
req_kv_set() {
    local file=$1 key=$2 value=$3
    req_kv_valid_key "$key" || {
        req_err "invalid key \"$key\" (use letters, digits and underscores)"; return 1; }
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || {
        req_err "the value of \"$key\" must be a single line"; return 1; }
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ ! -e $file ]]; then
        (umask 077; mkdir -p "$(dirname "$file")" && : >"$file") 2>/dev/null ||
            { req_err "cannot create $file"; return 1; }
    fi
    req_kv_rewrite "$file" set "$key" "$value"
}

# req_kv_unset <file> <key> - removes a key. Fails when the file or the key does not exist.
req_kv_unset() {
    [[ -f $1 ]] || return 1
    req_kv_rewrite "$1" unset "$2"
}

# --- central directory and projects --------------------------------------------

# req_config_dir - the central directory (default: ~/.req).
req_config_dir() {
    printf '%s' "${REQ_CONFIG_DIR:-$HOME/.req}"
}

# req_projects_dir - the directory holding one directory per project.
req_projects_dir() {
    printf '%s/projects' "$(req_config_dir)"
}

# req_project_state_dir <id> [subpath] - where a project keeps its files in ~/.req.
req_project_state_dir() {
    printf '%s/%s' "$(req_projects_dir)" "$1"
    [[ -z ${2-} ]] || printf '/%s' "$2"
}

# req_project_slug <folder> - a slug made from the folder's name (lowercase letters,
# digits and hyphens); "project" when nothing is left of it.
req_project_slug() {
    local name=${1%/} slug
    name=${name##*/}
    slug=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$name" | LC_ALL=C tr -cs 'a-z0-9' '-')
    slug=${slug#-}; slug=${slug%-}
    printf '%s' "${slug:-project}"
}

# req_project_find_id <project dir> - prints the id of the project registered for that
# directory (matched by the absolute path in its "project" file). Fails when none.
req_project_find_id() {
    local abs dir id
    abs=$(req_abs_path "$1")
    for dir in "$(req_projects_dir)"/*/; do
        [[ -f ${dir}project ]] || continue
        [[ $(req_kv_get "${dir}project" path) == "$abs" ]] || continue
        id=${dir%/}; printf '%s\n' "${id##*/}"
        return 0
    done
    return 1
}

# req_project_new_id <project dir> - prints a free id for a new project: the folder's
# slug, with -2, -3... added when another project already uses it.
req_project_new_id() {
    local slug id n=1
    slug=$(req_project_slug "$1")
    id=$slug
    while [[ -e $(req_project_state_dir "$id") ]]; do
        n=$(( n + 1 )); id=$slug-$n
    done
    printf '%s\n' "$id"
}

# req_project_create <project dir> - creates the control directory of a project and its
# "project" file (name and path), and prints the new id. Does not check whether the
# directory is already registered (req_project_find_id does).
req_project_create() {
    local abs id file
    [[ -d $1 ]] || { req_err "directory does not exist: $1"; return 1; }
    abs=$(req_abs_path "$1")
    [[ $abs != *$'\n'* ]] || { req_err "the project path must not contain line breaks: $abs"; return 1; }
    id=$(req_project_new_id "$abs")
    file=$(req_project_state_dir "$id" project)
    if ! { req_kv_set "$file" name "${abs##*/}" && req_kv_set "$file" path "$abs"; }; then
        req_err "cannot create the project control in $(req_project_state_dir "$id")"
        return 1
    fi
    printf '%s\n' "$id"
}

# req_current_get - prints the id of the project in use (from ~/.req/current). Fails
# when there is none or the project's directory is gone.
req_current_get() {
    local id
    id=$(req_kv_get "$(req_config_dir)/current" project) || return 1
    req_valid_name "$id" && [[ -d $(req_project_state_dir "$id") ]] || return 1
    printf '%s\n' "$id"
}

# req_current_set <id> - makes a registered project the one in use.
req_current_set() {
    if ! { req_valid_name "$1" && [[ -d $(req_project_state_dir "$1") ]]; }; then
        req_err "unknown project: $1"
        return 1
    fi
    req_kv_set "$(req_config_dir)/current" project "$1"
}
