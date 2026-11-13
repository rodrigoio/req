#!/usr/bin/env bash
# Tests for lib/core.sh and lib/ui.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"

test_missing_deps() {
    echo "core: dependencies"
    local out
    out=$(REQ_REQUIRED_CMDS=(bash req_cmd_missing_xyz); req_missing_deps)
    assert_eq "req_cmd_missing_xyz" "$out" "lists only the missing dependency"
    out=$(REQ_REQUIRED_CMDS=(bash); req_missing_deps)
    assert_eq "" "$out" "nothing missing when everything exists"
}

test_check_deps_message() {
    local out status
    out=$(REQ_REQUIRED_CMDS=(req_cmd_missing_xyz); req_check_deps 2>&1)
    status=$?
    assert_eq "1" "$status" "check_deps fails with a missing dependency"
    assert_contains "req: error: missing dependencies: req_cmd_missing_xyz" "$out" "message names the dependency"
    assert_contains "apt-get install" "$out" "message explains how to install"
}

test_bash_check() {
    local out status
    out=$(REQ_REQUIRED_BASH_MAJOR=99 req_check_bash 2>&1)
    status=$?
    assert_eq "1" "$status" "check_bash fails with an old version"
    assert_contains "bash 99+" "$out" "message names the required version"
    req_check_bash
    assert_eq "0" "$?" "current bash meets the minimum"
}

test_colors() {
    echo "ui: colors"
    assert_eq "0" "$REQ_COLORS" "colors are off when NO_COLOR is set"
    assert_eq "" "$(req_color get)" "no color when disabled"
    assert_eq "GET" "$(req_paint_method get)" "uppercase method without color"
    REQ_COLORS=1
    assert_eq $'\033[32m' "$(req_color get)" "GET green"
    assert_eq $'\033[34m' "$(req_color post)" "POST blue"
    assert_eq $'\033[38;5;208m' "$(req_color put)" "PUT orange"
    assert_eq $'\033[38;5;130m' "$(req_color patch)" "PATCH brown"
    assert_eq $'\033[31m' "$(req_color delete)" "DELETE red"
    assert_eq $'\033[1;92m' "$(req_color sel)" "selection is bold bright green"
    assert_eq "" "$(req_method_color head)" "unknown method has no color"
}

test_confirm() {
    echo "ui: confirmation prompt"
    local out
    for answer in "" y Y yes YES; do
        printf '%s\n' "$answer" | req_confirm "Go?" >/dev/null
        assert_eq "0" "$?" "\"$answer\" means yes"
    done
    for answer in n N no NO; do
        printf '%s\n' "$answer" | req_confirm "Go?" >/dev/null
        assert_eq "1" "$?" "\"$answer\" means no"
    done
    req_confirm "Go?" </dev/null >/dev/null
    assert_eq "1" "$?" "end of input means no"
    out=$(printf 'maybe\ny\n' | req_confirm "Go?")
    assert_eq "2" "$(grep -o 'Go? \[Y/n\]' <<<"$out" | wc -l)" "asks again on an unrecognized answer"
}

test_missing_deps
test_check_deps_message
test_bash_check
test_colors
test_confirm
test_summary
