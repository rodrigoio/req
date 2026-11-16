#!/usr/bin/env bash
# Tests for lib/config.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"
source "$ROOT/lib/config.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/cfg
mkdir -p "$REQ_CONFIG_DIR"

# cfg <text> - writes the global configuration file.
cfg() { printf '%s\n' "$1" >"$REQ_CONFIG_DIR/config"; }

test_table() {
    echo "config: the table of keys"
    local k v
    assert_eq "$TMP/cfg/config" "$(req_config_file)" "the file is config in the central directory"
    for k in "${REQ_CONFIG_KEYS[@]}"; do
        [[ -n ${REQ_CONFIG_TYPE[$k]-} && -n ${REQ_CONFIG_DEFAULT[$k]-} && -n ${REQ_CONFIG_DESC[$k]-} ]]
        assert_eq "0" "$?" "$k has a type, a default and a description"
        req_config_valid "$k" "${REQ_CONFIG_DEFAULT[$k]}"; assert_eq "0" "$?" "and its default is valid"
    done
    req_config_known time_stats; assert_eq "0" "$?" "a listed key is known"
    req_config_known nope; assert_eq "1" "$?" "another key is not"
    req_config_valid time_stats yes; assert_eq "0" "$?" "yes is a valid bool"
    req_config_valid time_stats no; assert_eq "0" "$?" "no is a valid bool"
    req_config_valid time_stats maybe; assert_eq "1" "$?" "anything else is not"
    req_config_valid time_stats Yes; assert_eq "1" "$?" "the case matters"
    req_config_valid nope yes; assert_eq "1" "$?" "an unknown key is never valid"
    assert_eq "yes or no" "$(req_config_expect time_stats)" "a bool says what it accepts"
    for v in 0 1 500 123456789; do
        req_config_valid log_request_limit "$v"; assert_eq "0" "$?" "an int accepts $v"
    done
    for v in "" -1 1.5 abc 1e3 " 5" yes 1234567890; do
        req_config_valid log_request_limit "$v"; assert_eq "1" "$?" "an int refuses \"$v\""
    done
    assert_eq "500" "$(req_config_get log_request_limit)" "log_request_limit is 500 by default"
    assert_eq "a whole number (0 or more)" "$(req_config_expect log_request_limit)" "an int says what it accepts"
}

test_load() {
    echo "config: reading"
    local out
    req_config_load; assert_eq "0" "$?" "a missing file is fine"
    assert_eq "yes" "$(req_config_get time_stats)" "and the default is used"
    cfg $'# presentation\ntime_stats = no\n\ntime_stat_total=yes'
    out=$(req_config_load 2>&1); assert_eq "0" "$?" "a valid file loads without warnings"
    assert_eq "" "$out" "silently"
    req_config_load
    assert_eq "no" "$(req_config_get time_stats)" "a value from the file wins over the default"
    assert_eq "yes" "$(req_config_get restore_cursor)" "a key left out keeps its default"
    req_config_get nope; assert_eq "1" "$?" "an unknown key cannot be read"

    cfg $'time_stats=no\ntime_stats=yes'
    req_config_load; assert_eq "no" "$(req_config_get time_stats)" "the first line of a repeated key wins"
    req_config_load_file "$TMP/other-file"; assert_eq "0" "$?" "another file can be loaded (and a missing one is fine)"
    assert_eq "yes" "$(req_config_get time_stats)" "loading again replaces the previous values"
}

test_problems() {
    echo "config: problems are warnings"
    local out f=$REQ_CONFIG_DIR/config
    cfg $'color=blue\ntime_stats=maybe\nnot a setting\nrestore_cursor=no'
    out=$(req_config_load 2>&1); assert_eq "1" "$?" "problems give status 1"
    assert_contains "$f:1: unknown setting \"color\"" "$out" "an unknown key is reported with path and line"
    assert_contains "known: time_stats time_stat_total restore_cursor log log_request_limit" "$out" "and the known keys are listed"
    assert_contains "$f:2: time_stats must be yes or no, not \"maybe\"" "$out" "a wrong value says what is accepted"
    assert_contains "$f:3: expected key=value" "$out" "a malformed line is reported"
    req_config_load 2>/dev/null
    assert_eq "no" "$(req_config_get restore_cursor)" "the valid lines still apply"
    assert_eq "yes" "$(req_config_get time_stats)" "an invalid value leaves the default"
    assert_eq "1" "${#REQ_CONFIG[@]}" "nothing else is loaded"
    assert_contains "color=blue" "$(<"$f")" "the file is never rewritten"
}

test_int_file() {
    echo "config: an int setting in a file"
    local out f=$REQ_CONFIG_DIR/config
    cfg 'log_request_limit=20'
    req_config_load; assert_eq "20" "$(req_config_get log_request_limit)" "the value is read"
    cfg 'log_request_limit=many'
    out=$(req_config_load 2>&1); assert_contains "$f:1: log_request_limit must be a whole number (0 or more), not \"many\"" "$out" "a wrong value is explained"
    req_config_load 2>/dev/null; assert_eq "500" "$(req_config_get log_request_limit)" "and the default stays"
    cfg 'log_request_limit=0'
    req_config_load; assert_eq "0" "$(req_config_get log_request_limit)" "0 is valid (no limit)"
}

test_local() {
    echo "config: the project's file"
    local out lf
    REQ_PROJECT_ID=shop; lf=$(req_config_local_file)
    assert_eq "$TMP/cfg/projects/shop/config" "$lf" "it is config in the project's directory"
    mkdir -p "$(dirname "$lf")"
    cfg $'time_stats=no\nrestore_cursor=no'
    printf 'time_stats=yes\nlog=yes\n' >"$lf"
    out=$(req_config_load 2>&1); assert_eq "0" "$?" "both files load without warnings"
    req_config_load
    assert_eq "yes" "$(req_config_get time_stats)" "the project's value wins over the global one"
    assert_eq "no" "$(req_config_get restore_cursor)" "a key it leaves out comes from the global file"
    assert_eq "yes" "$(req_config_get log)" "a key only it sets applies"
    assert_eq "2" "${#REQ_CONFIG_LOCAL[@]}" "the keys it set are listed"
    [[ -n ${REQ_CONFIG_LOCAL[log]+x} && -n ${REQ_CONFIG_LOCAL[time_stats]+x} ]]; assert_eq "0" "$?" "by name"
    printf 'log=maybe\ncolor=1\ntime_stats=no\n' >"$lf"
    out=$(req_config_load 2>&1); assert_eq "1" "$?" "a problem in the project's file gives status 1"
    assert_contains "$lf:1: log must be yes or no" "$out" "reported with its own path and line"
    assert_contains "$lf:2: unknown setting \"color\"" "$out" "an unknown key too"
    req_config_load 2>/dev/null
    assert_eq "no" "$(req_config_get time_stats)" "the valid lines still apply"
    assert_eq "no" "$(req_config_get log)" "an invalid value leaves the default"
    cfg $'time_stats=no'; rm -f "$lf"
    req_config_load; assert_eq "no" "$(req_config_get time_stats)" "a missing project file is fine"
    assert_eq "0" "${#REQ_CONFIG_LOCAL[@]}" "and marks nothing"
    printf 'log=yes\n' >"$lf"; REQ_PROJECT_ID=""
    req_config_load; assert_eq "no" "$(req_config_get log)" "without a project only the global file is read"
    REQ_PROJECT_ID=shop; req_config_load_local
    assert_eq "yes" "$(req_config_get log)" "req_config_load_local layers the project over what is loaded"
    assert_eq "no" "$(req_config_get time_stats)" "and keeps the rest"
    REQ_PROJECT_ID=""
}

test_table
test_load
test_problems
test_int_file
test_local
test_summary
