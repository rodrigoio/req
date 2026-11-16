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
