#!/usr/bin/env bash
# core.sh - dependency checks, errors and terminal restoration.

# shellcheck disable=SC2034  # REQ_* globals are read by the other modules
REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

req_err() {
    printf 'req: error: %s\n' "$*" >&2
}

# req_warn <message> - a warning on stderr; while the menu is open (REQ_NOTIFICATION_ACTIVE=1) it goes to
# the warning bar instead (notification.sh), so a configuration problem does not fill the terminal.
req_warn() {
    if [[ ${REQ_NOTIFICATION_ACTIVE-0} == 1 ]]; then
        req_notification_warn "$*"
    else
        printf 'req: warning: %s\n' "$*" >&2
    fi
}

req_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# req_abs_path <path> - the absolute (physical) path of a file or directory. The file need not exist, its
# directory must; otherwise the path is printed as given.
req_abs_path() {
    local p=$1 dir
    if [[ -d $p ]]; then
        (cd -P "$p" && pwd)
        return
    fi
    dir=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || { printf '%s' "$p"; return; }
    printf '%s/%s' "$dir" "${p##*/}"
}

req_die() {
    req_err "$@"
    exit 1
}

req_check_bash() {
    if (( BASH_VERSINFO[0] < REQ_REQUIRED_BASH_MAJOR )); then
        req_die "bash ${REQ_REQUIRED_BASH_MAJOR}+ is required (found: ${BASH_VERSION})."
    fi
}

req_missing_deps() {
    local cmd
    for cmd in "${REQ_REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
    done
}

# req_check_deps - dies naming the missing dependencies (in orange), never with install commands.
req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "missing dependencies: $(req_color orange)${missing//$'\n'/ }$(req_color reset)"
}

# req_editor [candidate...] - the external editor command, like git: $VISUAL, then $EDITOR, then the first
# candidate found in PATH (vim, then vi, when none is given). Status 1 when none. $VISUAL and $EDITOR may
# carry arguments ("code -w") and are not checked for existence.
req_editor() {
    local e
    local -a candidates=("$@")
    (( $# )) || candidates=(vim vi)
    if [[ -n ${VISUAL-} ]]; then printf '%s' "$VISUAL"; return 0; fi
    if [[ -n ${EDITOR-} ]]; then printf '%s' "$EDITOR"; return 0; fi
    for e in "${candidates[@]}"; do
        if command -v "$e" >/dev/null 2>&1; then printf '%s' "$e"; return 0; fi
    done
    return 1
}

# req_edit_file <file> [candidate...] - edits the file itself (not a copy) in req_editor and waits. Status:
# 0 the editor ended well, 1 it failed, 2 no editor (the same codes as req_edit_text). The caller hands the
# terminal over first (req_nav_prompt_begin).
req_edit_file() {
    local file=$1 editor
    shift
    editor=$(req_editor "$@") || return 2
    sh -c "$editor \"\$@\"" req-editor "$file" || return 1
}

REQ_EDIT_TEXT=""    # result of req_edit_text

# req_edit_text <text> [suffix] - edits the text in a temporary file named raw_data<suffix> (".json" makes
# the editor pick the syntax) and leaves the result in REQ_EDIT_TEXT without trailing line breaks. Status: 0
# edited, 1 the editor failed (REQ_EDIT_TEXT keeps the original), 2 no editor (the caller falls back to a
# prompt).
req_edit_text() {
    local editor dir file status
    editor=$(req_editor) || return 2
    dir=$(mktemp -d "${TMPDIR:-/tmp}/req-edit.XXXXXX") || return 1
    file=$dir/raw_data${2-}
    printf '%s\n' "$1" >"$file"
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

req_restore_terminal() {
    [[ -t 1 ]] || return 0
    printf '\033[0m\033[?25h'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

REQ_EXIT_HOOK=""        # function to run first when the process exits (the menu saves its cursor)

req_on_exit() {
    [[ -z $REQ_EXIT_HOOK ]] || "$REQ_EXIT_HOOK"
    req_restore_terminal
}

# req_trap_int_exit - Ctrl-C ends req (status 130). A child that owns the terminal for a while (the pager)
# puts a no-op in its place and calls this to get it back.
req_trap_int_exit() {
    trap 'exit 130' INT
}

req_setup_traps() {
    trap req_on_exit EXIT
    req_trap_int_exit
    trap 'exit 143' TERM
}
