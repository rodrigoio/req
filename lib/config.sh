#!/usr/bin/env bash
# config.sh - the global configuration ($REQ_CONFIG_DIR/config, default ~/.req/config).
#
# A "key=value" file (see home.sh for the format). The known keys, with their type,
# default and description, are listed once, in REQ_CONFIG_KEYS below; every other part
# of req (the :config command, the presentation code) goes through that table. Reading
# never blocks the menu: an unknown key, a value of the wrong type or a malformed line
# is reported as a warning with the absolute path and the line number, and ignored.

# Known keys, in the order they are listed. Types: bool (yes or no).
REQ_CONFIG_KEYS=(time_stats time_stat_total restore_cursor)
declare -gA REQ_CONFIG_TYPE=(
    [time_stats]=bool
    [time_stat_total]=bool
    [restore_cursor]=bool
)
declare -gA REQ_CONFIG_DEFAULT=(
    [time_stats]=yes
    [time_stat_total]=yes
    [restore_cursor]=yes
)
# shellcheck disable=SC2034  # read by :config (TR2.6)
declare -gA REQ_CONFIG_DESC=(
    [time_stats]="show the timing profile after a request runs"
    [time_stat_total]="show the total time line after a request runs"
    [restore_cursor]="reopen the menu where it was left"
)

declare -gA REQ_CONFIG=()       # values of the last loaded file (key -> value)

# req_config_file - path of the global configuration file.
req_config_file() {
    printf '%s/config' "$(req_config_dir)"
}

# req_config_known <key> - succeeds when the key is in the table.
req_config_known() {
    [[ -n ${REQ_CONFIG_TYPE[$1]+x} ]]
}

# req_config_valid <key> <value> - succeeds when the key is known and the value fits
# its type.
req_config_valid() {
    req_config_known "$1" || return 1
    case ${REQ_CONFIG_TYPE[$1]} in
        bool) [[ $2 == yes || $2 == no ]] ;;
        *)    return 1 ;;
    esac
}

# req_config_expect <key> - prints what the key accepts, for error messages.
req_config_expect() {
    case ${REQ_CONFIG_TYPE[$1]-} in
        bool) printf 'yes or no' ;;
    esac
}

# req_config_load [file] - fills REQ_CONFIG with the file's values (default: the global
# file). A missing file is fine. Problems are warnings; the status is 1 when there was
# any. The first line of a repeated key wins.
req_config_load() {
    local file=${1:-$(req_config_file)} line n=0 abs status=0
    REQ_CONFIG=()
    [[ -f $file ]] || return 0
    abs=$(req_abs_path "$file")
    while IFS= read -r line || [[ -n $line ]]; do
        n=$(( n + 1 ))
        if ! req_kv_parse_line "$line"; then
            line=${line%$'\r'}; line=${line#"${line%%[![:space:]]*}"}
            [[ -z $line || $line == \#* ]] && continue
            req_warn "$abs:$n: expected key=value; line ignored"
            status=1; continue
        fi
        if ! req_config_known "$REQ_KV_KEY"; then
            req_warn "$abs:$n: unknown setting \"$REQ_KV_KEY\" (known: ${REQ_CONFIG_KEYS[*]}); ignored"
            status=1; continue
        fi
        [[ -n ${REQ_CONFIG[$REQ_KV_KEY]+x} ]] && continue
        if ! req_config_valid "$REQ_KV_KEY" "$REQ_KV_VALUE"; then
            req_warn "$abs:$n: $REQ_KV_KEY must be $(req_config_expect "$REQ_KV_KEY"), not \"$REQ_KV_VALUE\"; ignored"
            status=1; continue
        fi
        REQ_CONFIG[$REQ_KV_KEY]=$REQ_KV_VALUE
    done <"$file"
    return "$status"
}

# req_config_get <key> - prints the loaded value of a key, or its default when the file
# does not set it. Fails for an unknown key.
req_config_get() {
    req_config_known "$1" || return 1
    printf '%s\n' "${REQ_CONFIG[$1]-${REQ_CONFIG_DEFAULT[$1]}}"
}
