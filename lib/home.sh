#!/usr/bin/env bash
# home.sh - the user's central directory (~/.req): projects, configuration, cursor.
#
# This first part holds the "key=value" text files everything in there is made of
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
