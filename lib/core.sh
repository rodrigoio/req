#!/usr/bin/env bash
# core.sh - dependency checks, errors and terminal restoration.

REQ_VERSION="0.1.0"
REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

# req_err <message> - prints an error to stderr without exiting.
req_err() {
    printf 'req: error: %s\n' "$*" >&2
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

# req_check_deps - exits with instructions if any dependency is missing.
req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "missing dependencies: $(tr '\n' ' ' <<<"$missing")
install them with your package manager, for example:
  debian/ubuntu:  sudo apt-get install ${missing//$'\n'/ }
  centos/rhel:    sudo yum install ${missing//$'\n'/ }"
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
