#!/usr/bin/env bash
# home.sh - the user's central directory (~/.req, or $REQ_CONFIG_DIR when set; the tests use it): projects, config, cursor.
#
# Layout (one directory per project):
#   ~/.req/current                 project=<id>: the project in use
#   ~/.req/config                  global configuration
#   ~/.req/projects/<id>/project   name=<folder name> and path=<absolute path of the project>
#   ~/.req/projects/<id>/config    project configuration (wins over the global one)
#   ~/.req/projects/<id>/env/<e>/vars   variables of environment <e>
#   ~/.req/projects/<id>/cursor    last position in the menu
#
# Everything in there is a "key=value" text file, handled by the first part below:
#   - one "key=value" per line; the key matches [A-Za-z_][A-Za-z0-9_]*;
#   - blank lines and lines starting with "#" are ignored;
#   - spaces around the key and the value are not significant; the value is everything after the first "=" (so it
#     may contain "=") and has one line; no quotes or escapes;
#   - when a key appears twice the first line wins; req_kv_set keeps only that one.
# Writing keeps comments, blank lines and the order of the other lines, and rewrites the file in place (mode and
# symlinks are kept). New files and directories are private (0600 and 0700), since they may hold credentials.

REQ_KV_KEY=""       # set by req_kv_parse_line
REQ_KV_VALUE=""

req_kv_valid_key() {
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# req_kv_parse_line <line> - puts the key and value in REQ_KV_KEY and REQ_KV_VALUE; fails for blank lines,
# comments and anything that is not "key=value".
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

# req_kv_get <file> <key> - prints the value; status 1 when the file or the key is missing.
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

# req_kv_list <file> - prints every "key=value" in file order, trimmed; a missing file lists nothing.
req_kv_list() {
    local line
    [[ -f $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        req_kv_parse_line "$line" && printf '%s=%s\n' "$REQ_KV_KEY" "$REQ_KV_VALUE"
    done <"$1"
    return 0
}

# req_kv_check <file> - reports, with the absolute path and the line number, every line that is not blank, a
# comment or a valid "key=value"; fails when there is any. A missing file is fine.
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

# req_kv_rewrite <file> <set|unset> <key> [value] - the engine of set and unset: the first line of the key
# is replaced (set) and its other lines dropped; unset drops them all and fails (1) when there is none.
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

# req_kv_set <file> <key> <value> - sets a key, creating the file and its directory when needed; the key
# must be valid and the value one line.
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

req_kv_unset() {
    [[ -f $1 ]] || return 1
    req_kv_rewrite "$1" unset "$2"
}

# --- central directory and projects --------------------------------------------

req_config_dir() {
    printf '%s' "${REQ_CONFIG_DIR:-$HOME/.req}"
}

req_projects_dir() {
    printf '%s/projects' "$(req_config_dir)"
}

req_project_state_dir() {
    printf '%s/%s' "$(req_projects_dir)" "$1"
    [[ -z ${2-} ]] || printf '/%s' "$2"
}

# req_project_slug <folder> - a slug made from the folder's name; "project" when nothing is left of it.
req_project_slug() {
    local name=${1%/} slug
    name=${name##*/}
    slug=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$name" | LC_ALL=C tr -cs 'a-z0-9' '-')
    slug=${slug#-}; slug=${slug%-}
    printf '%s' "${slug:-project}"
}

# req_project_find_id <project dir> - the id of the project registered for that directory (matched by the
# path in its "project" file); fails when none.
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

# req_project_new_id <project dir> - a free id: the folder's slug, with -2, -3... when another project has
# it.
req_project_new_id() {
    local slug id n=1
    slug=$(req_project_slug "$1")
    id=$slug
    while [[ -e $(req_project_state_dir "$id") ]]; do
        n=$(( n + 1 )); id=$slug-$n
    done
    printf '%s\n' "$id"
}

# req_project_create <project dir> - makes the control directory and the "project" file (name and path) and
# prints the new id. Does not check for an existing registration (req_project_find_id does).
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

# req_current_get - the id of the project in use (~/.req/current); fails when there is none or its directory
# is gone.
req_current_get() {
    local id
    id=$(req_kv_get "$(req_config_dir)/current" project) || return 1
    req_valid_name "$id" && [[ -d $(req_project_state_dir "$id") ]] || return 1
    printf '%s\n' "$id"
}

req_current_set() {
    if ! { req_valid_name "$1" && [[ -d $(req_project_state_dir "$1") ]]; }; then
        req_err "unknown project: $1"
        return 1
    fi
    req_kv_set "$(req_config_dir)/current" project "$1"
}

REQ_PROJECT_ID=""       # id of the project opened by req_project_activate

# shellcheck disable=SC2034  # REQ_PROJECT_ID is read by the environment and cursor code
# req_project_activate <project dir> - registers the project in ~/.req when new, makes it the one in use and
# sets REQ_PROJECT_ID. It also makes sure the project has its env folder and the "default" environment
# (req_env_create), at every opening, so projects of older versions get them too. When ~/.req cannot be
# written it is one warning, REQ_PROJECT_ID stays empty and the status is 1; the menu still works, without
# saved state.
req_project_activate() {
    local dir=$1 id problem
    REQ_PROJECT_ID=""
    if ! id=$(req_project_find_id "$dir"); then
        id=$(req_project_create "$dir" 2>&1) || { problem=$id; id=""; }
    fi
    if [[ -n $id ]]; then
        problem=$(req_current_set "$id" 2>&1) || id=""
    fi
    if [[ -z $id ]]; then
        req_warn "the project state in $(req_config_dir) cannot be saved; continuing without it"
        problem=${problem%%$'\n'*}
        printf '  %s\n' "${problem#req: error: }" >&2
        return 1
    fi
    REQ_PROJECT_ID=$id
    problem=$(req_env_create default "$id" 2>&1) || req_warn "${problem#req: error: }"
    return 0
}

req_cursor_file() {
    req_project_state_dir "$1" cursor
}

# req_cursor_save <id> <dir> <item> - writes the menu position: the directory shown and the item selected in
# it, both relative to the workspace ("" is the workspace itself, or no item). Fails when the file cannot be
# written.
req_cursor_save() {
    local file
    file=$(req_cursor_file "$1")
    req_kv_set "$file" dir "$2" && req_kv_set "$file" item "$3"
}

# --- the .req file: workspace ---------------------------------------------------

# req_project_workspace <.req file> - the absolute path of the project's workspace, the only directory req
# looks at: the "workspace" key of the .req (default "."), relative to the folder of the .req. It must
# exist, be a real directory inside the project folder and have no symbolic link in it; every component is
# checked in order, even those a later ".." cancels, so "link/../x" is refused. Other lines of the .req (old
# formats) are ignored. On a problem it prints the reason with the absolute path of the .req and fails.
req_project_workspace() {
    local pfile=$1 base abs value comp cur
    local -a parts
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    abs=$(req_abs_path "$pfile")
    base=$(cd -P "$(dirname "$pfile")" && pwd) || { req_err "$abs: cannot enter the project folder"; return 1; }
    value=$(req_kv_get "$pfile" workspace) || value=.
    if [[ -z $value ]]; then
        req_err "$abs: workspace is empty (use . for the project folder)"; return 1
    fi
    if [[ $value == /* ]]; then
        req_err "$abs: workspace \"$value\" must be a relative path"; return 1
    fi

    cur=$base
    IFS=/ read -r -a parts <<<"$value"
    for comp in "${parts[@]}"; do
        case $comp in
            ''|.) continue ;;
            ..)
                cur=${cur%/*}
                if [[ $cur != "$base" && $cur != "$base"/* ]]; then
                    req_err "$abs: workspace \"$value\" leaves the project folder"; return 1
                fi
                continue ;;
        esac
        cur=$cur/$comp
        if [[ -L $cur ]]; then
            req_err "$abs: workspace \"$value\" goes through a symbolic link ($comp); links are not accepted"; return 1
        fi
        if [[ ! -e $cur ]]; then
            req_err "$abs: workspace \"$value\" does not exist"; return 1
        fi
        if [[ ! -d $cur ]]; then
            req_err "$abs: workspace \"$value\" is not a directory ($comp)"; return 1
        fi
    done
    printf '%s\n' "$cur"
}
