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
    local k
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
    req_config_load "$TMP/other-file"; assert_eq "0" "$?" "another file can be given (and a missing one is fine)"
    assert_eq "yes" "$(req_config_get time_stats)" "loading again replaces the previous values"
}

test_problems() {
    echo "config: problems are warnings"
    local out f=$REQ_CONFIG_DIR/config
    cfg $'color=blue\ntime_stats=maybe\nnot a setting\nrestore_cursor=no'
    out=$(req_config_load 2>&1); assert_eq "1" "$?" "problems give status 1"
    assert_contains "$f:1: unknown setting \"color\"" "$out" "an unknown key is reported with path and line"
    assert_contains "known: time_stats time_stat_total restore_cursor" "$out" "and the known keys are listed"
    assert_contains "$f:2: time_stats must be yes or no, not \"maybe\"" "$out" "a wrong value says what is accepted"
    assert_contains "$f:3: expected key=value" "$out" "a malformed line is reported"
    req_config_load 2>/dev/null
    assert_eq "no" "$(req_config_get restore_cursor)" "the valid lines still apply"
    assert_eq "yes" "$(req_config_get time_stats)" "an invalid value leaves the default"
    assert_eq "1" "${#REQ_CONFIG[@]}" "nothing else is loaded"
    assert_contains "color=blue" "$(<"$f")" "the file is never rewritten"
}

test_table
test_load
test_problems
test_summary
