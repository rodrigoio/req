#!/usr/bin/env bash
# notification.sh - the notification bars at the top of the menu screen.
#
# Two kinds of bar share the top of the screen: persistent notifications, reprinted at every
# draw for as long as their condition holds, and a warning, printed once. This module is the
# part they have in common: it builds one bar line (req_notification_bar) and puts the bars of a
# draw on the screen (req_notification_collect, req_notification_overlay).
#
# What goes in the bars comes from producers: functions named in REQ_NOTIFICATION_PRODUCERS, in
# screen order from the top, each one appending its bar lines to REQ_NOTIFICATION_LINES. A
# producer that is not defined (yet) is skipped, so a feature adds its own function and never
# edits this list. With no producer defined there is no bar and no line.
#
# Only the interactive menu draws bars; `req run` never does.

REQ_NOTIFICATION_LINES=()      # the bar lines of the current draw, from the top of the screen
REQ_NOTIFICATION_IDS=()        # the persistent notifications, in registration order
REQ_NOTIFICATION_CHECKS=()     # their check functions, in the same order
REQ_NOTIFICATION_TEXT=""       # what a check that has something to say puts in its bar
REQ_NOTIFICATION_WARN=""       # the warning that waits for the next draw ("" when there is none)
REQ_NOTIFICATION_WARN_MORE=0   # how many more came after it before that draw
REQ_NOTIFICATION_PRODUCERS=(req_notification_persistent_lines req_notification_warn_lines)

# req_notification_bar <text> - prints one bar line: black letters on an orange background,
# padded with spaces up to one column short of the terminal width (like the hint lines, so that
# no terminal wraps it) and truncated when it is longer. Without colors it is the plain text
# starting with "! ", so it is still told apart.
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

# req_notification_collect - fills REQ_NOTIFICATION_LINES with the bars of this draw: every
# producer that exists is called, in order. It runs once per draw, before the screen is built,
# so the list knows how many rows the bars take and a one-shot producer spends its message here.
req_notification_collect() {
    local producer
    REQ_NOTIFICATION_LINES=()
    for producer in "${REQ_NOTIFICATION_PRODUCERS[@]}"; do
        if declare -F "$producer" >/dev/null; then "$producer"; fi
    done
    return 0
}

# req_notification_overlay - puts the bars of this draw above the screen being drawn.
req_notification_overlay() {
    (( ${#REQ_NOTIFICATION_LINES[@]} > 0 )) || return 0
    REQ_SCREEN_LINES=("${REQ_NOTIFICATION_LINES[@]}" "${REQ_SCREEN_LINES[@]}")
}

# --- persistent notifications --------------------------------------------------

# req_notification_register <id> <check function> - registers a persistent notification. At every
# draw the check is called: it succeeds and sets REQ_NOTIFICATION_TEXT when it has something to
# say, and fails when it has not. Registering an id again replaces its check (so the menu can
# register at every start), and a feature added later only registers its own.
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

# req_notification_persistent_lines - the producer of the persistent notifications (named in
# REQ_NOTIFICATION_PRODUCERS): runs every registered check, in order, and adds one bar line for
# each one that is active. Nothing is spent here: the bars come back at every draw, for as long
# as the condition holds, and there is no way to dismiss them. A check that is not defined
# is skipped, and one that succeeds with no text says nothing.
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

# req_notification_warn <message> - holds a warning for the next draw, where it is shown once in a
# bar below the persistent ones (an incorrect command, a notice of warning severity). When several
# come before the same draw, the first one is shown with "(+N more)". The message is one line:
# line breaks become spaces.
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

# req_notification_warn_lines - the producer of the warning (named in REQ_NOTIFICATION_PRODUCERS,
# after the persistent one): the held warning becomes a bar and is spent, so the next draw has
# none. A cut to the width falls on the message, never on the "(+N more)" that follows it.
req_notification_warn_lines() {
    local text suffix="" room
    [[ -n $REQ_NOTIFICATION_WARN ]] || return 0
    (( REQ_NOTIFICATION_WARN_MORE > 0 )) && suffix=" (+$REQ_NOTIFICATION_WARN_MORE more)"
    room=$(( $(req_term_cols) - 3 - ${#suffix} ))     # what a bar leaves for the text, with or without colors
    text="$(req_trunc "$REQ_NOTIFICATION_WARN" "$room")$suffix"
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_NOTIFICATION_LINES+=("$(req_notification_bar "$text")")
    return 0
}

# --- the root user's notice -------------------------------------------------------

# req_notification_is_root - succeeds when req runs as root (the tests redefine it, so they do not
# depend on who runs them).
req_notification_is_root() {
    (( EUID == 0 ))
}

# req_notification_root_check - the check of the persistent notice for the root user: files created
# or edited in the session can end up owned by root, which upsets the owner and the permissions of
# the project's files. Registered by req_nav_init; the text fits an 80-column bar.
req_notification_root_check() {
    req_notification_is_root || return 1
    REQ_NOTIFICATION_TEXT="running as root: files you create or edit may end up owned by root, not you"
}
