#!/usr/bin/env bash
# Tests for lib/core.sh and lib/ui.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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
    assert_eq "req: error: missing dependencies: req_cmd_missing_xyz" "$out" "message is a single line naming the package"
    out=$(REQ_REQUIRED_CMDS=(req_cmd_missing_xyz curl_missing_abc); req_check_deps 2>&1)
    assert_contains "req_cmd_missing_xyz curl_missing_abc" "$out" "lists every missing package on the same line"
    assert_not_contains "sudo" "$out" "message has no sudo"
    assert_not_contains "install" "$out" "message has no install command"
    REQ_COLORS=1
    out=$(REQ_REQUIRED_CMDS=(req_cmd_missing_xyz); req_check_deps 2>&1)
    REQ_COLORS=0
    assert_contains $'\033[38;5;208mreq_cmd_missing_xyz\033[0m' "$out" "package names are orange"
}

# fake_editor <path> <sh commands> - writes an executable "editor" script.
fake_editor() { printf '#!/bin/sh\n%s\n' "$2" >"$1"; chmod +x "$1"; }

test_editor() {
    echo "core: external editor"
    local bin=$TMP/edbin out status
    mkdir -p "$bin"
    assert_eq "myvisual" "$(VISUAL=myvisual EDITOR=myeditor req_editor)" "VISUAL comes first"
    assert_eq "myeditor" "$(VISUAL='' EDITOR=myeditor req_editor)" "then EDITOR"
    assert_eq "code -w" "$(VISUAL="code -w" req_editor)" "arguments are kept"
    printf '#!/bin/sh\n' >"$bin/vi"; chmod +x "$bin/vi"
    assert_eq "vi" "$(VISUAL='' EDITOR='' PATH=$bin req_editor)" "then vi when there is no vim"
    printf '#!/bin/sh\n' >"$bin/vim"; chmod +x "$bin/vim"
    assert_eq "vim" "$(VISUAL='' EDITOR='' PATH=$bin req_editor)" "vim wins over vi"
    mkdir -p "$TMP/empty"
    VISUAL='' EDITOR='' PATH=$TMP/empty req_editor >/dev/null; assert_eq "1" "$?" "fails when there is no editor"

    # A fake editor that appends a line, as a user would type.
    # shellcheck disable=SC2016  # the script text is meant to be expanded by sh, not here
    fake_editor "$bin/appender" 'echo more >>"$1"'
    VISUAL=$bin/appender req_edit_text $'first\nsecond' .json; status=$?
    assert_eq "0" "$status" "an edit succeeds"
    assert_eq $'first\nsecond\nmore' "$REQ_EDIT_TEXT" "the edited text comes back without trailing breaks"
    fake_editor "$bin/spy" "printf '%s' \"\${1##*/}\" >'$TMP/name'; cat \"\$1\" >'$TMP/seen'"
    mkdir -p "$TMP/ed-tmp"
    TMPDIR=$TMP/ed-tmp VISUAL="$bin/spy" req_edit_text '{"a":1}' .json
    assert_eq "raw_data.json" "$(<"$TMP/name")" "the temporary file carries the suffix"
    assert_eq '{"a":1}' "$(<"$TMP/seen")" "the editor sees the initial text"
    assert_eq "0" "$(find "$TMP/ed-tmp" -mindepth 1 | wc -l)" "the temporary files are removed"
    VISUAL="env REQ_X=1 $bin/spy" req_edit_text 'x'
    assert_eq "0" "$?" "an editor command with arguments works"
    VISUAL="$bin/spy" req_edit_text ''
    assert_eq "" "$REQ_EDIT_TEXT" "an emptied text comes back empty"

    # shellcheck disable=SC2016  # idem
    fake_editor "$bin/failer" 'echo changed >"$1"; exit 3'
    VISUAL=$bin/failer req_edit_text 'keep'; status=$?
    assert_eq "1" "$status" "an editor that fails is reported"
    assert_eq "keep" "$REQ_EDIT_TEXT" "and the original text is kept"
    VISUAL='' EDITOR='' PATH=$TMP/empty req_edit_text 'x'; assert_eq "2" "$?" "no editor gives status 2"
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

test_trim_prompt() {
    echo "core: trim"
    assert_eq "a b" "$(req_trim "   a b  ")" "trims both ends"
    assert_eq "" "$(req_trim "   ")" "only whitespace"
    assert_eq "x" "$(req_trim "x")" "nothing to trim"
    echo "ui: prompt and confirm defaults"
    local out
    REQ_INPUT_FD=3 req_prompt "Name" "def" 3<<<"typed" >/dev/null
    assert_eq "typed" "$REQ_REPLY" "an answer replaces the default"
    REQ_INPUT_FD=3 req_prompt "Name" "def" 3<<<"" >/dev/null
    assert_eq "def" "$REQ_REPLY" "Enter picks the default"
    out=$(REQ_INPUT_FD=3 req_prompt "Name" "def" 3<<<"" )
    assert_eq "Name [def]: " "$out" "the prompt shows the default"
    REQ_INPUT_FD=3 req_prompt "Name" "" 3</dev/null >/dev/null; assert_eq "1" "$?" "end of input fails"
    REQ_INPUT_FD=3 req_confirm "Go?" n 3<<<"" >/dev/null; assert_eq "1" "$?" "Enter means no when the default is n"
    REQ_INPUT_FD=3 req_confirm "Go?" n 3<<<"y" >/dev/null; assert_eq "0" "$?" "y means yes when the default is n"
    out=$(REQ_INPUT_FD=3 req_confirm "Go?" n 3<<<"n"); assert_contains "[y/N]" "$out" "the hint shows the default"
}

test_abs_path() {
    echo "core: absolute paths"
    local d
    d=$(mktemp -d); mkdir -p "$d/sub"; : >"$d/sub/f.json"; ln -s "$d/sub" "$d/link"
    assert_eq "$d/sub/f.json" "$(req_abs_path "$d/sub/f.json")" "an absolute path stays"
    assert_eq "$d/sub/f.json" "$(cd "$d/sub" && req_abs_path f.json)" "a bare file name is resolved against the cwd"
    assert_eq "$d/sub/f.json" "$(cd "$d" && req_abs_path ./sub/../sub/f.json)" "dots are normalized"
    assert_eq "$d/sub/f.json" "$(req_abs_path "$d/link/f.json")" "directory symlinks are resolved"
    assert_eq "$d/sub/new.json" "$(req_abs_path "$d/sub/new.json")" "the file does not need to exist"
    assert_eq "$d/sub" "$(req_abs_path "$d/link")" "works for directories"
    assert_eq "/nope/x.json" "$(req_abs_path /nope/x.json)" "a missing directory leaves the path as given"
    rm -rf "$d"
}

test_missing_deps
test_check_deps_message
test_editor
test_bash_check
test_colors
test_confirm
test_trim_prompt
test_abs_path
test_summary
