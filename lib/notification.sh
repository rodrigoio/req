#!/usr/bin/env bash
# notification.sh - the notification bars at the top of the menu screen.
#
# Persistent notifications are reprinted at every draw while their condition holds; a warning is printed once. This
# module builds one bar line (req_notification_bar) and puts the bars of a draw on the screen (req_notification_collect,
# req_notification_overlay). What goes in the bars comes from producers: functions named in REQ_NOTIFICATION_PRODUCERS,
# in screen order from the top, each one appending bar lines to REQ_NOTIFICATION_LINES. A producer that is not defined
# is skipped, so a feature adds its own function and never edits that list. Only the interactive menu draws bars;
# `req run` never does.

REQ_NOTIFICATION_LINES=()      # the bar lines of the current draw, from the top of the screen
REQ_NOTIFICATION_IDS=()        # the persistent notifications, in registration order
REQ_NOTIFICATION_CHECKS=()     # their check functions, in the same order
REQ_NOTIFICATION_TEXT=""       # what a check that has something to say puts in its bar
# shellcheck disable=SC2034  # read by req_warn (core.sh), req_run_request (http.sh) and the menu (nav.sh)
REQ_NOTIFICATION_ACTIVE=0      # 1 while the menu is open: req_warn then goes through the warning bar
REQ_NOTIFICATION_WARN=""       # the warning that waits for the next draw ("" when there is none)
REQ_NOTIFICATION_WARN_MORE=0   # how many more came after it before that draw
REQ_NOTIFICATION_PRODUCERS=(req_notification_persistent_lines req_notification_warn_lines)

# req_notification_bar <text> - one bar line: black letters on orange, padded with spaces to one column
# short of the terminal width (like the hint lines, so no terminal wraps it) and truncated when longer.
# Without colors it is the plain text starting with "! ", so it is still told apart.
req_notification_bar() {
    local cols room text pad
    cols=$(req_term_cols)
    if ! req_colors_enabled; then
        req_trunc "! $1" $(( cols - 1 ))
        return 0
    fi
    room=$(( cols - 3 ))                        # a space on each side and the last column
    (( room < 1 )) && room=1
    text=$(req_trunc "$1" "$room")
    pad=$(( cols - 2 - ${#text} ))
    (( pad < 0 )) && pad=0                      # a negative width would pad on the other side
    printf '%s %s%*s%s' "$(req_color notification)" "$text" "$pad" '' "$(req_color reset)"
}

# req_notification_more <text> <n> - the text for a bar that is one of several: cut to the width, never the
# " (+N more)" that follows it (nothing is added when n is 0).
req_notification_more() {
    local suffix=""
    (( $2 > 0 )) && suffix=" (+$2 more)"
    printf '%s%s' "$(req_trunc "$1" $(( $(req_term_cols) - 3 - ${#suffix} )))" "$suffix"
}

# req_notification_collect - fills REQ_NOTIFICATION_LINES with the bars of this draw: every defined producer
# is called, in order. It runs once per draw, before the screen is built, so the list knows how many rows
# the bars take and a one-shot producer spends its message here.
req_notification_collect() {
    local producer
    REQ_NOTIFICATION_LINES=()
    for producer in "${REQ_NOTIFICATION_PRODUCERS[@]}"; do
        if declare -F "$producer" >/dev/null; then "$producer"; fi
    done
    return 0
}

req_notification_overlay() {
    (( ${#REQ_NOTIFICATION_LINES[@]} > 0 )) || return 0
    REQ_SCREEN_LINES=("${REQ_NOTIFICATION_LINES[@]}" "${REQ_SCREEN_LINES[@]}")
}

# --- persistent notifications --------------------------------------------------

# req_notification_register <id> <check function> - registers a persistent notification. At every draw the
# check runs: it succeeds and sets REQ_NOTIFICATION_TEXT when it has something to say. Registering an id
# again replaces its check, so the menu can register at every start.
req_notification_register() {
    local id=$1 check=$2 i
    [[ -n $id && -n $check ]] || return 1
    for i in "${!REQ_NOTIFICATION_IDS[@]}"; do
        if [[ ${REQ_NOTIFICATION_IDS[i]} == "$id" ]]; then
            REQ_NOTIFICATION_CHECKS[i]=$check
            return 0
        fi
    done
    REQ_NOTIFICATION_IDS+=("$id")
    REQ_NOTIFICATION_CHECKS+=("$check")
}

# req_notification_persistent_lines - the producer of the persistent notifications: runs every registered
# check, in order, and adds a bar line for each active one. Nothing is spent here: the bars come back at
# every draw while the condition holds, and cannot be dismissed.
req_notification_persistent_lines() {
    local check
    for check in "${REQ_NOTIFICATION_CHECKS[@]}"; do
        REQ_NOTIFICATION_TEXT=""
        declare -F "$check" >/dev/null || continue
        if "$check" && [[ -n $REQ_NOTIFICATION_TEXT ]]; then
            REQ_NOTIFICATION_LINES+=("$(req_notification_bar "$REQ_NOTIFICATION_TEXT")")
        fi
    done
    return 0
}

# --- the warning, printed once ---------------------------------------------------

# req_notification_warn <message> - holds a warning for the next draw, where it is shown once in a bar below
# the persistent ones. When several come before the same draw, the first is shown with "(+N more)". The
# message is one line: line breaks become spaces.
req_notification_warn() {
    local msg=$*
    msg=${msg//$'\n'/ }
    [[ -n $msg ]] || return 0
    if [[ -z $REQ_NOTIFICATION_WARN ]]; then
        REQ_NOTIFICATION_WARN=$msg
    else
        REQ_NOTIFICATION_WARN_MORE=$(( REQ_NOTIFICATION_WARN_MORE + 1 ))
    fi
    return 0
}

# req_notification_warn_file <file> - turns what a command wrote to stderr into one warning: each line
# without its "req: error: " or "req: warning: " mark and its indentation, joined with "; ". A file with no
# text is no warning.
req_notification_warn_file() {
    local line text=""
    [[ -s $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line#req: error: }; line=${line#req: warning: }
        line=${line#"${line%%[![:space:]]*}"}          # without the indentation
        [[ -n $line ]] || continue
        text+="${text:+; }$line"
    done <"$1"
    req_notification_warn "$text"
}

# req_notification_warn_lines - the producer of the warning: the held warning becomes a bar and is spent. A
# cut to the width falls on the message, never on the "(+N more)" that follows it.
req_notification_warn_lines() {
    local text
    [[ -n $REQ_NOTIFICATION_WARN ]] || return 0
    text=$(req_notification_more "$REQ_NOTIFICATION_WARN" "$REQ_NOTIFICATION_WARN_MORE")
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_NOTIFICATION_LINES+=("$(req_notification_bar "$text")")
    return 0
}

# --- the root user's notice -------------------------------------------------------

# req_notification_is_root - succeeds when req runs as root (the tests redefine it).
req_notification_is_root() {
    (( EUID == 0 ))
}

# req_notification_root_check - the persistent notice for root: files created or edited in the session can
# end up owned by root. Registered by req_nav_init; the text fits an 80-column bar.
req_notification_root_check() {
    req_notification_is_root || return 1
    REQ_NOTIFICATION_TEXT="running as root: files you create or edit may end up owned by root, not you"
}
