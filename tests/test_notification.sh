#!/usr/bin/env bash
# shellcheck disable=SC2034  # REQ_* globals set here are read by the libraries
# Tests for lib/notification.sh: the bar line, the producers and the overlay. The libraries
# are linted on their own, so they are not followed from here.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/nav.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/notification.sh"

export LC_ALL=C COLUMNS=20 LINES=24

# strip_ansi - removes the color sequences, to measure what the terminal would show.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Producers made up for the tests: each one appends bar lines, like the real ones will.
notification_test_producer_top() { REQ_NOTIFICATION_LINES+=("top bar made up for the test"); }
notification_test_producer_low() { REQ_NOTIFICATION_LINES+=("low bar made up for the test"); }

test_color() {
    echo "notification: the color"
    local old=$REQ_COLORS
    REQ_COLORS=1
    assert_eq $'\033[38;5;16;48;5;208m' "$(req_color notification)" "black letters on the orange background"
    REQ_COLORS=0
    assert_eq "" "$(req_color notification)" "no color when colors are off"
    REQ_COLORS=$old
}

test_bar_with_colors() {
    echo "notification: a bar line with colors"
    local old=$REQ_COLORS line plain
    REQ_COLORS=1
    line=$(req_notification_bar "hello")
    plain=$(strip_ansi <<<"$line")
    assert_eq "$(req_color notification) hello$(printf '%13s' '')$(req_color reset)" "$line" "color, a space, the text, the padding and a reset"
    assert_eq "19" "${#plain}" "padded to one column short of the terminal width"
    assert_eq " hello$(printf '%13s' '')" "$plain" "the text sits after one space"

    line=$(req_notification_bar "a message much longer than the terminal")
    plain=$(strip_ansi <<<"$line")
    assert_eq "19" "${#plain}" "a long text is cut to the same width"
    assert_eq "~ " "${plain: -2}" "the cut is marked, with a space before the edge"
    assert_contains "a message much" "$plain" "and the start of the text is kept"

    line=$(req_notification_bar "")
    plain=$(strip_ansi <<<"$line")
    assert_eq "19" "${#plain}" "an empty text is still a full bar"
    line=$(COLUMNS=3 req_notification_bar "wider than the terminal")
    plain=$(strip_ansi <<<"$line")
    assert_eq "1" "$(( ${#plain} <= 3 ))" "a very narrow terminal does not break the bar"
    line=$(COLUMNS=60 req_notification_bar "wide")
    plain=$(strip_ansi <<<"$line")
    assert_eq "59" "${#plain}" "the bar follows the terminal width"
    REQ_COLORS=$old
}

test_bar_without_colors() {
    echo "notification: a bar line without colors"
    local old=$REQ_COLORS
    REQ_COLORS=0
    assert_eq "! hello" "$(req_notification_bar "hello")" "plain text starting with a mark"
    assert_eq "! a message m~" "$(COLUMNS=15 req_notification_bar "a message much longer")" "cut to one column short of the width"
    REQ_COLORS=$old
}

test_collect() {
    echo "notification: producers"
    REQ_NOTIFICATION_LINES=("left over from an earlier draw")
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "no producer defined, no bar (and the earlier draw is forgotten)"

    local saved=("${REQ_NOTIFICATION_PRODUCERS[@]}")
    REQ_NOTIFICATION_PRODUCERS=(notification_test_producer_top notification_test_producer_not_defined notification_test_producer_low)
    req_notification_collect
    assert_eq "2" "${#REQ_NOTIFICATION_LINES[@]}" "a producer that is not defined is skipped"
    assert_eq "top bar made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "the first producer is the top bar"
    assert_eq "low bar made up for the test" "${REQ_NOTIFICATION_LINES[1]}" "the next one comes below it"
    req_notification_collect
    assert_eq "2" "${#REQ_NOTIFICATION_LINES[@]}" "collecting again does not pile the bars up"
    REQ_NOTIFICATION_PRODUCERS=("${saved[@]}")
    REQ_NOTIFICATION_LINES=()
}

test_overlay() {
    echo "notification: the overlay"
    REQ_SCREEN_LINES=("header" "item" "hint")
    REQ_NOTIFICATION_LINES=()
    req_notification_overlay
    assert_eq "header|item|hint" "$(IFS='|'; echo "${REQ_SCREEN_LINES[*]}")" "with no bar the screen is untouched"

    REQ_NOTIFICATION_LINES=("bar one" "bar two")
    req_notification_overlay
    assert_eq "bar one|bar two|header|item|hint" "$(IFS='|'; echo "${REQ_SCREEN_LINES[*]}")" "the bars go above the screen, in order"
    assert_eq "5" "${#REQ_SCREEN_LINES[@]}" "and count as lines of the block, so the redraw erases them"
    REQ_NOTIFICATION_LINES=()
}

test_list_window() {
    echo "notification: the list leaves room for the bars"
    local i without with
    REQ_NAV_ROOT=/nowhere REQ_CUR_DIR="" REQ_NAV_PROJECT="" REQ_STACK_DIR=()
    REQ_ITEM_KIND=(); REQ_ITEM_LABEL=(); REQ_ITEM_METHOD=(); REQ_ITEM_PATH=()
    for i in $(seq 1 30); do
        REQ_ITEM_KIND+=(r); REQ_ITEM_LABEL+=("item-$i"); REQ_ITEM_METHOD+=(GET); REQ_ITEM_PATH+=("/nowhere/item-$i.get.json")
    done
    REQ_SEL=0 REQ_TOP=0
    LINES=12 req_nav_build_list
    without=${#REQ_SCREEN_LINES[@]}
    assert_eq "1" "$(( without <= 12 ))" "without bars the list fits the terminal height"

    REQ_SEL=0 REQ_TOP=0
    REQ_NOTIFICATION_LINES=("bar one" "bar two")
    LINES=12 req_nav_build_list
    with=${#REQ_SCREEN_LINES[@]}
    assert_eq "$(( without - 2 ))" "$with" "two bars take two rows from the list"
    req_notification_overlay
    assert_eq "$without" "${#REQ_SCREEN_LINES[@]}" "so the block with its bars is as tall as before"
    REQ_NOTIFICATION_LINES=()

    REQ_SEL=0 REQ_TOP=0
    REQ_NOTIFICATION_LINES=("a" "b" "c" "d" "e" "f" "g" "h")
    LINES=12 req_nav_build_list
    assert_eq "5" "${#REQ_SCREEN_LINES[@]}" "with many bars the list still keeps three rows (header, three items and the hint)"
    REQ_NOTIFICATION_LINES=()
}

# Checks made up for the tests: what a feature registers to raise a persistent notification.
notification_test_check_first() { REQ_NOTIFICATION_TEXT="first persistent notice made up for the test"; }
notification_test_check_second() { REQ_NOTIFICATION_TEXT="second persistent notice made up for the test"; }
notification_test_check_replacement() { REQ_NOTIFICATION_TEXT="replacement notice made up for the test"; }
notification_test_check_silent() { return 1; }
notification_test_check_empty() { return 0; }

test_persistent() {
    echo "notification: persistent notifications"
    local COLUMNS=100                  # wide enough for the whole text of every bar
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=()
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "nothing registered, no bar"

    req_notification_register test-first notification_test_check_first
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "a registered notification that is active adds a bar"
    assert_eq "! first persistent notice made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "with its text"
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "and it is there at the next draw too: nothing is spent"
    req_notification_collect
    assert_eq "! first persistent notice made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "and at the one after"

    req_notification_register test-silent notification_test_check_silent
    req_notification_register test-empty notification_test_check_empty
    req_notification_register test-missing notification_test_check_not_defined
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "an inactive check, one with no text and one not defined say nothing"

    req_notification_register test-second notification_test_check_second
    req_notification_collect
    assert_eq "2" "${#REQ_NOTIFICATION_LINES[@]}" "two active at once give two bars"
    assert_eq "! first persistent notice made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "in registration order: the first one on top"
    assert_eq "! second persistent notice made up for the test" "${REQ_NOTIFICATION_LINES[1]}" "and the next below it"

    req_notification_register test-first notification_test_check_replacement
    req_notification_collect
    assert_eq "2" "${#REQ_NOTIFICATION_LINES[@]}" "registering an id again does not add a bar"
    assert_eq "! replacement notice made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "it replaces the check, in the same place"
    assert_eq "5" "${#REQ_NOTIFICATION_IDS[@]}" "and the registry keeps one entry per id"

    req_notification_register "" notification_test_check_first
    assert_eq "1" "$?" "an empty id is refused"
    req_notification_register test-no-check ""
    assert_eq "1" "$?" "so is an empty check"
    assert_eq "5" "${#REQ_NOTIFICATION_IDS[@]}" "and neither is kept"

    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=(); REQ_NOTIFICATION_LINES=()
}

test_warning() {
    echo "notification: the warning, printed once"
    local COLUMNS=100 old=$REQ_COLORS
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=(); REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "no warning, no bar"

    req_notification_warn "a warning made up for the test"
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "a warning shows in a bar at the next draw"
    assert_eq "! a warning made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "with its text"
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "and only once: the draw after it has no bar"

    REQ_COLORS=1
    req_notification_warn "colored warning made up for the test"
    req_notification_collect
    local orange
    orange=$(req_color notification)
    assert_eq "$orange" "${REQ_NOTIFICATION_LINES[0]:0:${#orange}}" "it is orange with black letters"
    REQ_COLORS=$old

    req_notification_register test-first notification_test_check_first
    req_notification_warn "warning below the persistent bar, made up for the test"
    req_notification_collect
    assert_eq "2" "${#REQ_NOTIFICATION_LINES[@]}" "a persistent notification and a warning at the same time"
    assert_eq "! first persistent notice made up for the test" "${REQ_NOTIFICATION_LINES[0]}" "the persistent bar is on top"
    assert_eq "! warning below the persistent bar, made up for the test" "${REQ_NOTIFICATION_LINES[1]}" "and the warning right below it"
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "next draw: only the persistent one is left"
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=()

    req_notification_warn "first warning"
    req_notification_warn "second warning"
    req_notification_warn "third warning"
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "several warnings before a draw are still one line"
    assert_eq "! first warning (+2 more)" "${REQ_NOTIFICATION_LINES[0]}" "the first one, and how many came after it"
    req_notification_warn "next warning"
    req_notification_collect
    assert_eq "! next warning" "${REQ_NOTIFICATION_LINES[0]}" "the count starts again after a draw"

    req_notification_warn "a warning that is much too long for the narrow terminal"
    req_notification_warn "another"
    COLUMNS=30 req_notification_collect
    assert_eq "! a warning that i~ (+1 more)" "${REQ_NOTIFICATION_LINES[0]}" "a long message is cut, never the count after it"
    assert_eq "1" "$(( ${#REQ_NOTIFICATION_LINES[0]} <= 29 ))" "and the bar fits the terminal"

    req_notification_warn $'line one\nline two'
    req_notification_collect
    assert_eq "! line one line two" "${REQ_NOTIFICATION_LINES[0]}" "line breaks become spaces"
    req_notification_warn ""
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "an empty message is no warning"
    REQ_NOTIFICATION_LINES=()
}

test_root_notice() {
    echo "notification: the root user's notice"
    local COLUMNS=80 original
    original=$(declare -f req_notification_is_root)
    req_notification_is_root; local real=$?
    assert_eq "$(( $(id -u) == 0 ? 0 : 1 ))" "$real" "the real check follows the user id"

    # shellcheck disable=SC2317  # called by the library, not from this file
    req_notification_is_root() { return 1; }
    REQ_NOTIFICATION_TEXT=""
    req_notification_root_check
    assert_eq "1" "$?" "not root: nothing to say"
    assert_eq "" "$REQ_NOTIFICATION_TEXT" "and no text"

    # shellcheck disable=SC2317  # called by the library, not from this file
    req_notification_is_root() { return 0; }
    req_notification_root_check
    assert_eq "0" "$?" "root: there is something to say"
    assert_contains "running as root" "$REQ_NOTIFICATION_TEXT" "it says req runs as root"
    assert_contains "owned by root" "$REQ_NOTIFICATION_TEXT" "and that the files may end up owned by root"
    assert_eq "1" "$(( ${#REQ_NOTIFICATION_TEXT} <= 77 ))" "the text fits an 80-column bar"

    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=()
    req_notification_register root req_notification_root_check
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "registered, it is a persistent bar for root"
    assert_contains "running as root" "${REQ_NOTIFICATION_LINES[0]}" "with the notice"
    req_notification_collect
    assert_eq "1" "${#REQ_NOTIFICATION_LINES[@]}" "and it comes back at every draw"

    # shellcheck disable=SC2317  # called by the library, not from this file
    req_notification_is_root() { return 1; }
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "for another user it is no bar at all"

    eval "$original"
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=(); REQ_NOTIFICATION_LINES=()
}

test_warn_routing() {
    echo "notification: req_warn follows the menu"
    local errfile
    errfile=$(mktemp)
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0

    REQ_NOTIFICATION_ACTIVE=0
    req_warn "a plain warning made up for the test" 2>"$errfile"
    assert_eq "req: warning: a plain warning made up for the test" "$(<"$errfile")" "outside the menu a warning goes to stderr"
    assert_eq "" "$REQ_NOTIFICATION_WARN" "and the bar is not involved"

    REQ_NOTIFICATION_ACTIVE=1
    req_warn "a warning for the bar, made up for the test" 2>"$errfile"
    assert_eq "" "$(<"$errfile")" "while the menu is open nothing goes to stderr"
    assert_eq "a warning for the bar, made up for the test" "$REQ_NOTIFICATION_WARN" "the bar holds it for the next draw"
    req_warn "another one" 2>"$errfile"
    assert_eq "1" "$REQ_NOTIFICATION_WARN_MORE" "and a second one is counted after it"

    REQ_NOTIFICATION_ACTIVE=0
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    rm -f "$errfile"
}

test_more() {
    echo "notification: the text of a bar that is one of several"
    local COLUMNS=30
    assert_eq "a short text" "$(req_notification_more "a short text" 0)" "nothing is added when there are no others"
    assert_eq "a short text (+3 more)" "$(req_notification_more "a short text" 3)" "the count follows the text"
    assert_eq "a long text that~ (+3 more)" "$(req_notification_more "a long text that is cut because it does not fit" 3)" "a long text is cut, never the count"
    local cut
    cut=$(req_notification_more "a long text that is cut because it does not fit" 3)
    assert_eq "1" "$(( ${#cut} <= 27 ))" "and the whole fits a bar of 30 columns"
}

test_color
test_bar_with_colors
test_bar_without_colors
test_collect
test_persistent
test_warning
test_more
test_root_notice
test_warn_routing
test_overlay
test_list_window
test_summary
