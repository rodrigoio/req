#!/usr/bin/env bash
# core.sh - dependency checks, errors and terminal restoration.

# shellcheck disable=SC2034  # read by bin/req
REQ_VERSION="0.1.0"
REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

# req_err <message> - prints an error to stderr without exiting.
req_err() {
    printf 'req: error: %s\n' "$*" >&2
}

# req_warn <message> - prints a warning to stderr without exiting.
req_warn() {
    printf 'req: warning: %s\n' "$*" >&2
}

# req_trim <text> - prints the text without leading and trailing whitespace.
req_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# req_abs_path <path> - prints the absolute (physical) path of a file or directory.
# The file itself does not need to exist; its directory does, otherwise the path
# is printed as given.
req_abs_path() {
    local p=$1 dir
    if [[ -d $p ]]; then
        (cd -P "$p" && pwd)
        return
    fi
    dir=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || { printf '%s' "$p"; return; }
    printf '%s/%s' "$dir" "${p##*/}"
}

# req_die <message> - prints an error to stderr and exits with status 1.
req_die() {
    req_err "$@"
    exit 1
}

# req_check_bash - requires bash >= REQ_REQUIRED_BASH_MAJOR.
req_check_bash() {
    if (( BASH_VERSINFO[0] < REQ_REQUIRED_BASH_MAJOR )); then
        req_die "bash ${REQ_REQUIRED_BASH_MAJOR}+ is required (found: ${BASH_VERSION})."
    fi
}

# req_missing_deps - lists, one per line, the dependencies missing from PATH.
req_missing_deps() {
    local cmd
    for cmd in "${REQ_REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
    done
}

# req_check_deps - exits with an error naming the missing dependencies (in orange),
# without install commands.
req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "missing dependencies: $(req_color orange)${missing//$'\n'/ }$(req_color reset)"
}

# req_editor - prints the external editor command, like git does: $VISUAL, then
# $EDITOR, then vim, then vi. Fails (status 1) when none is available. $VISUAL and
# $EDITOR may carry arguments (e.g. "code -w") and are not checked for existence.
req_editor() {
    local e
    if [[ -n ${VISUAL-} ]]; then printf '%s' "$VISUAL"; return 0; fi
    if [[ -n ${EDITOR-} ]]; then printf '%s' "$EDITOR"; return 0; fi
    for e in vim vi; do
        if command -v "$e" >/dev/null 2>&1; then printf '%s' "$e"; return 0; fi
    done
    return 1
}

REQ_EDIT_TEXT=""    # result of req_edit_text

# req_edit_text <text> [suffix] - opens the text in the external editor, in a temporary
# file named raw_data<suffix> (e.g. ".json", so the editor picks the syntax), and puts
# the edited text in REQ_EDIT_TEXT without trailing line breaks. The editor takes over
# the terminal; the caller hands it over first (req_nav_prompt_begin).
# Status: 0 edited, 1 the editor failed (REQ_EDIT_TEXT keeps the original text),
# 2 no editor available (the caller falls back to a prompt).
req_edit_text() {
    local editor dir file status
    editor=$(req_editor) || return 2
    dir=$(mktemp -d "${TMPDIR:-/tmp}/req-edit.XXXXXX") || return 1
    file=$dir/raw_data${2-}
    printf '%s\n' "$1" >"$file"
    # The shell lets $VISUAL and $EDITOR carry arguments, as git does.
    sh -c "$editor \"\$@\"" req-editor "$file"
    status=$?
    if (( status == 0 )) && [[ -f $file ]]; then
        REQ_EDIT_TEXT=$(<"$file")
    else
        REQ_EDIT_TEXT=$1
        status=1
    fi
    rm -rf "$dir"
    return "$status"
}

# req_restore_terminal - puts the terminal back to normal (cursor, echo, colors).
req_restore_terminal() {
    [[ -t 1 ]] || return 0
    printf '\033[0m\033[?25h'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

# req_setup_traps - restores the terminal on normal exit, error or signal.
req_setup_traps() {
    trap req_restore_terminal EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
