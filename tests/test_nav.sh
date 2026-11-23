#!/usr/bin/env bash
# The libraries are linted on their own. Following all ten of them from here takes too
# much time and memory, so they are not followed, and the REQ_* settings that the tests
# set for them look unused. SC2030 and SC2031: the signal test sets state in a subshell on purpose.
# shellcheck disable=SC2034,SC2030,SC2031
# Tests for lib/nav.sh. Outside a terminal there are no colors and nothing is erased.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/store.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/home.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/env.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/log.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/http.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/nav.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/notification.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/wizard.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cmd.sh"

# shellcheck disable=SC2031  # lib/store.sh sets LC_ALL in a subshell on purpose
export LC_ALL=C COLUMNS=60 LINES=24
# The root notice (a persistent bar) must not depend on who runs the tests: nobody is root here,
# except in the one test that says otherwise.
# shellcheck disable=SC2317  # called by the library, not from this file
req_notification_is_root() { return 1; }
TMP=$(mktemp -d)
export REQ_CONFIG_DIR=$TMP/cfg      # never touch the real ~/.req
SERVER_PID=""
cleanup() { [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# screen <list|detail> - builds the current screen in the current shell; the text ends up in $OUT.
screen() {
    if [[ $1 == detail ]]; then req_nav_build_detail; else req_nav_build_list; fi
    OUT=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
}

# keys <keys...> - feeds keys (up down enter esc or raw text), pausing after esc.
keys() {
    local k
    for k in "$@"; do
        case $k in
            up)    printf '\033[A' ;;
            down)  printf '\033[B' ;;
            enter) printf '\n' ;;
            esc)   printf '\033'; sleep 0.2 ;;
            clear) printf '\f' ;;
            *)     printf '%s' "$k" ;;
        esac
    done
}

make_project() {
    local p=$TMP/proj
    rm -rf "$p"
    mkdir -p "$p/api/v2" "$p/auth"
    printf 'api\nauth\n' >"$p/.req"
    req_request_write "$p/api" list-users GET http://x/users \
        '{"description":"lists everyone","headers":{"Accept":"application/json"},"query":{"page":1}}' >/dev/null
    req_request_write "$p/api" create POST http://x/users \
        '{"parameters":{"user":"ann"}}' >/dev/null
    req_request_write "$p/api" remove DELETE http://x/users \
        '{"parameters":{"id":1}}' >/dev/null
    req_request_write "$p/api/v2" ping DELETE http://x/ping >/dev/null
    printf '{"name":"broken","method":"GET","url":"http://x","retries":5}\n' >"$p/api/broken.get.json"
    PROJ=$p
}

test_keys() {
    echo "nav: reading keys"
    local out
    out=$({ keys up down enter esc x; } | { while req_read_key; do printf '%s,' "$REQ_KEY"; done; })
    assert_eq "up,down,enter,esc,x," "$out" "arrows, Enter, bare Esc and a character"
    out=$(printf '\033OA\033[C' | { while req_read_key; do printf '%s,' "$REQ_KEY"; done; })
    assert_eq "up,other," "$out" "arrow in application mode and an ignored key"
    out=$(printf '\177\b' | { while req_read_key; do printf '%s,' "$REQ_KEY"; done; })
    assert_eq "backspace,backspace," "$out" "DEL and ^H are backspace"
    out=$(printf '\r' | { req_read_key; printf '%s' "$REQ_KEY"; })
    assert_eq "enter" "$out" "carriage return counts as Enter"
    req_read_key </dev/null; assert_eq "1" "$?" "end of input returns status 1"
}

test_navigation() {
    echo "nav: navigation"
    make_project
    req_nav_init "$PROJ/.req"
    assert_eq "api auth" "${REQ_ITEM_LABEL[*]}" "root lists the directories of the .req"
    assert_eq "d d" "${REQ_ITEM_KIND[*]}" "root items are directories"

    req_nav_handle up;   assert_eq "1" "$REQ_SEL" "up on the first item wraps around"
    req_nav_handle down; assert_eq "0" "$REQ_SEL" "down on the last item wraps around"
    req_nav_handle esc;  assert_eq "" "$REQ_CUR_DIR" "Esc at the root does nothing"
    assert_eq "list" "$REQ_VIEW" "Esc at the root keeps the list"

    req_nav_handle enter
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "Enter enters the directory"
    assert_eq "v2 broken create list-users remove" "${REQ_ITEM_LABEL[*]}" "directories before requests, in order"
    assert_eq "d r r r r" "${REQ_ITEM_KIND[*]}" "distinct kinds for directories and requests"
    assert_eq " GET POST GET DELETE" "${REQ_ITEM_METHOD[*]}" "methods loaded (empty for a directory)"

    req_nav_handle down; req_nav_handle down
    req_nav_handle esc
    assert_eq "" "$REQ_CUR_DIR" "Esc goes back to the root"
    assert_eq "0" "$REQ_SEL" "previous selection is restored"

    req_nav_handle down; req_nav_handle enter
    assert_eq "$PROJ/auth" "$REQ_CUR_DIR" "enters the selected directory"
    screen list; assert_contains "(empty)" "$OUT" "an empty directory is indicated"
    req_nav_handle enter; assert_eq "$PROJ/auth" "$REQ_CUR_DIR" "Enter in an empty directory does nothing"
    req_nav_handle esc
    assert_eq "1" "$REQ_SEL" "selection of auth restored"
    req_nav_handle up

    req_nav_handle enter                  # api
    req_nav_handle enter                  # v2
    assert_eq "$PROJ/api/v2" "$REQ_CUR_DIR" "enters a subdirectory"
    screen list; assert_contains "/api/v2" "$OUT" "header shows the path"
    req_nav_handle esc; req_nav_handle esc
    assert_eq "" "$REQ_CUR_DIR" "repeated Esc reaches the root"
}

test_key_q() {
    echo "nav: q goes back like Esc"
    make_project
    req_nav_init "$PROJ/.req"
    local i
    req_nav_handle esc
    assert_eq "0" "$REQ_QUIT" "Esc at the root does not quit"
    req_nav_handle enter; req_nav_handle enter                  # api, then v2
    assert_eq "$PROJ/api/v2" "$REQ_CUR_DIR" "two directories down"
    req_nav_handle q
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "q goes up one directory, like Esc"
    assert_eq "0" "$REQ_QUIT" "without quitting"
    req_nav_handle q
    assert_eq "" "$REQ_CUR_DIR" "q again reaches the root"
    assert_eq "0" "$REQ_QUIT" "still without quitting"
    req_nav_handle q
    assert_eq "1" "$REQ_QUIT" "q at the root quits, as :q does"
    assert_eq "" "$REQ_CUR_DIR" "from where it was"

    req_nav_init "$PROJ/.req"; req_nav_handle enter             # api (req_nav_init clears REQ_QUIT)
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "a request is open"
    req_nav_handle q
    assert_eq "list" "$REQ_VIEW" "q on the details goes back to the list"
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "in the same directory"
    assert_eq "0" "$REQ_QUIT" "without quitting"
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "0" "$REQ_DETAIL_VALID" "an invalid request is open"
    req_nav_handle q
    assert_eq "list" "$REQ_VIEW" "q leaves its details too"

    unset REQ_ENV
    REQ_VIEW="env"; REQ_ENV_BACK=detail; REQ_ENV_CHOICES=(default dev); REQ_ENV_SEL=1
    req_nav_handle q
    assert_eq "detail" "$REQ_VIEW" "q leaves the environment menu for the view it came from"
    assert_eq "" "${REQ_ENV:-}" "changing nothing"
    REQ_VIEW=help; REQ_HELP_BACK=list
    req_nav_handle q
    assert_eq "list" "$REQ_VIEW" "q closes the help, as any key does"

    type_keys : q
    assert_eq "q" "$REQ_CMD_BUF" "in command mode q is a letter"
    assert_eq "0" "$REQ_QUIT" "and does not quit"
    req_nav_handle esc
    assert_eq "0" "$REQ_CMD_ACTIVE" "Esc leaves command mode"
}

test_list_screen() {
    echo "nav: list screen"
    make_project
    req_nav_init "$PROJ/.req"
    local out
    screen list; out=$OUT
    assert_contains "req /" "$out" "header at the root"
    assert_contains "(1/2)" "$out" "position in the list"
    assert_contains "(1/2)  proj @ default" "$out" "the header names the project and the default environment"
    REQ_ENV=prod screen list
    assert_contains "proj @ prod" "$OUT" "REQ_ENV chooses the environment shown"
    COLUMNS=20 screen list
    [[ $OUT != *"@"* ]]; assert_eq "0" "$?" "on a narrow terminal the project and environment are dropped"
    assert_contains "req /" "$OUT" "and the path stays"
    REQ_NAV_PROJECT=""; screen list
    [[ $OUT != *"@"* ]]; assert_eq "0" "$?" "without a project name there is nothing to show"
    req_nav_init "$PROJ/.req"; screen list; out=$OUT
    assert_contains "> dir    api/" "$out" "selected directory with a marker"
    assert_contains "  dir    auth/" "$out" "directory without a marker"
    assert_eq "3" "${#REQ_SCREEN_LINES[@]}" "the header and the two directories: no hint line under them"
    assert_not_contains "Enter open" "$out" "and no word about keys"

    req_nav_handle enter
    screen list; out=$OUT
    assert_not_contains "Esc back" "$out" "no Esc hint away from the root either"
    assert_contains "> dir    v2/" "$out" "subdirectory highlighted"
    assert_contains "  POST   create" "$out" "request with a method"
    assert_contains "  GET    list-users" "$out" "request GET"
    assert_contains "  DELETE remove" "$out" "request DELETE"
    assert_eq "6" "${#REQ_SCREEN_LINES[@]}" "lines: the header and 5 items"
}

test_selection_highlight() {
    echo "nav: selection highlight"
    make_project
    req_nav_init "$PROJ/.req"; req_nav_handle enter
    local sel=$'\033[1;92m' reset=$'\033[0m' line i
    REQ_COLORS=1
    req_nav_build_list
    # Items: v2 (dir, selected), broken, create, list-users, remove
    assert_eq "${sel}> dir    v2/${reset}" "${REQ_SCREEN_LINES[1]}" "selected directory row is bold bright green"
    local highlighted=0
    for line in "${REQ_SCREEN_LINES[@]}"; do [[ $line == *"$sel"* ]] && highlighted=$((highlighted + 1)); done
    assert_eq "1" "$highlighted" "exactly one row is highlighted"

    req_nav_handle down; req_nav_handle down   # create (POST)
    req_nav_build_list
    assert_eq "${sel}> POST   create${reset}" "${REQ_SCREEN_LINES[3]}" "selected request row is highlighted as a whole"
    assert_eq $'  \033[32mGET   \033[0m broken' "${REQ_SCREEN_LINES[2]}" "other rows keep their method color"
    [[ ${REQ_SCREEN_LINES[1]} != *"$sel"* ]]; assert_eq "0" "$?" "the previously selected row loses the highlight"
    REQ_COLORS=0
}

test_detail_screen() {
    echo "nav: details screen"
    make_project
    req_nav_init "$PROJ/.req"
    req_nav_handle enter                    # api
    local i
    for i in "${!REQ_ITEM_LABEL[@]}"; do
        [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i
    done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "Enter on a request opens the details"
    local out; screen detail; out=$OUT
    assert_eq "1" "$REQ_DETAIL_VALID" "valid request"
    assert_contains "GET    list-users" "$out" "method and name"
    assert_contains "url  http://x/users" "$out" "url"
    assert_contains "desc lists everyone" "$out" "description"
    assert_contains "Accept: application/json" "$out" "headers"
    assert_contains "page=1" "$out" "query"
    assert_not_contains "Enter run" "$out" "no hint line under the details"

    req_nav_handle esc
    assert_eq "list" "$REQ_VIEW" "Esc goes back to the list"
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "in the same directory"
}

test_detail_params() {
    echo "nav: parameters per method"
    make_project
    req_nav_init "$PROJ/.req"; req_nav_handle enter
    local i out
    for i in "${!REQ_ITEM_LABEL[@]}"; do
        [[ ${REQ_ITEM_LABEL[i]} == create ]] && REQ_SEL=$i
    done
    req_nav_handle enter; screen detail; out=$OUT
    assert_contains "  Parameters" "$out" "POST shows parameters"
    assert_contains "user=ann" "$out" "parameter value"
    [[ $out != *"not sent"* ]]; assert_eq "0" "$?" "POST sends the parameters"
    req_nav_handle esc
    for i in "${!REQ_ITEM_LABEL[@]}"; do
        [[ ${REQ_ITEM_LABEL[i]} == remove ]] && REQ_SEL=$i
    done
    req_nav_handle enter; screen detail; out=$OUT
    assert_contains "not sent with DELETE" "$out" "DELETE warns that it sends no body"
}

test_detail_raw_data() {
    echo "nav: raw_data on the details"
    local p=$TMP/raw out f big i
    mkdir -p "$p/d"; printf 'd\n' >"$p/.req"
    req_nav_init "$p/.req"
    show() { REQ_DETAIL_FILE=$1; screen detail; out=$OUT; }

    f=$(req_request_write "$p/d" js POST http://x '{"raw_data":{"a":1,"b":[true,"x"]},"parameters":{"k":"v"}}')
    show "$f"
    assert_contains "  Raw data" "$out" "a raw_data section is shown"
    assert_contains '    {' "$out" "JSON is indented (opening line)"
    assert_contains '      "a": 1,' "$out" "JSON is indented (a field)"
    assert_contains "Parameters (not sent: raw data takes precedence)" "$out" "parameters are flagged when raw_data wins"
    assert_contains "k=v" "$out" "and still listed"

    f=$(req_request_write "$p/d" tx PUT http://x $'{"raw_data":"line one\\nline two"}')
    show "$f"
    assert_contains "    line one" "$out" "text is shown as it is (first line)"
    assert_contains "    line two" "$out" "text is shown as it is (second line)"
    [[ $out != *"not sent"* ]]; assert_eq "0" "$?" "no warning without parameters"

    f=$(req_request_write "$p/d" em POST http://x '{"raw_data":"","parameters":{"k":"v"}}')
    show "$f"
    [[ $out != *"Raw data"* ]]; assert_eq "0" "$?" "an empty raw_data shows no section"
    [[ $out != *"not sent"* ]]; assert_eq "0" "$?" "and parameters are sent"

    f=$(req_request_write "$p/d" gt GET http://x '{"raw_data":{"a":1}}')
    show "$f"
    assert_contains "Raw data (not sent with GET)" "$out" "GET warns that raw_data is not sent"

    big="["; for i in $(seq 1 40); do big+="$i,"; done; big+="0]"
    f=$(req_request_write "$p/d" bg POST http://x "{\"raw_data\":$big}")
    show "$f"
    assert_contains "... (28 more lines)" "$out" "a long raw_data is capped"
    assert_eq "1" "$(( $(wc -l <<<"$out") <= REQ_RAW_MAX_LINES + 12 ))" "and the screen stays short"
    unset -f show
}

test_detail_invalid() {
    echo "nav: invalid request"
    make_project
    req_nav_init "$PROJ/.req"; req_nav_handle enter
    local i out
    for i in "${!REQ_ITEM_LABEL[@]}"; do
        [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i
    done
    req_nav_handle enter; screen detail; out=$OUT
    assert_eq "0" "$REQ_DETAIL_VALID" "an invalid request is flagged"
    assert_contains "Invalid request" "$out" "shows the problem"
    assert_contains 'unknown field "retries"' "$out" "shows the reason"
    assert_eq "$PROJ/api/broken.get.json" "${REQ_SCREEN_LINES[2]}" "the absolute path is on its own line, ready to copy"
    assert_eq "0" "$REQ_SCREEN_EXTRA" "a path that fits adds no extra rows"
    assert_contains '! invalid request: unknown field "retries"' "${REQ_SCREEN_LINES[0]}" "the first problem is pinned at the top, in a bar"
    assert_eq "1" "$(( ${#REQ_SCREEN_LINES[0]} <= 59 ))" "cut to fit the terminal"
    assert_eq "" "$(req_nav_handle enter 2>&1)" "Enter does not run an invalid request"
    assert_eq "detail" "$REQ_VIEW" "stays on the details"
    req_nav_handle esc; assert_eq "list" "$REQ_VIEW" "Esc goes back"
}

test_detail_bad_address() {
    echo "nav: a request with a broken address"
    make_project
    local f out
    req_request_write "$PROJ/api" badaddr GET "http://exa mple.com" >/dev/null
    f=$PROJ/api/badaddr.get.json
    req_nav_init "$PROJ/.req"
    REQ_DETAIL_FILE=$f
    COLUMNS=80 screen detail; out=$OUT
    assert_eq "1" "$REQ_DETAIL_VALID" "the request itself is valid"
    assert_eq "! invalid address in the url: it contains whitespace" "${REQ_SCREEN_LINES[0]}" "the problem is pinned at the top"
    assert_contains "GET    badaddr" "${REQ_SCREEN_LINES[1]}" "and the details follow it"

    # shellcheck disable=SC2016  # a ${key} placeholder, literal text
    req_request_write "$PROJ/api" goodaddr GET 'http://example.com/${path}' >/dev/null
    REQ_DETAIL_FILE=$PROJ/api/goodaddr.get.json
    COLUMNS=80 screen detail
    assert_contains "GET    goodaddr" "${REQ_SCREEN_LINES[0]}" "a good address, placeholders included, has no bar"
}

test_invalid_many_problems() {
    echo "nav: an invalid request with many problems"
    make_project
    local f=$PROJ/api/lots.get.json i fields="" out
    for i in $(seq 1 12); do fields+=",\"field_made_up_$i\":1"; done
    printf '{"name":"lots","method":"GET","url":"http://example.com"%s}\n' "$fields" >"$f"
    req_nav_init "$PROJ/.req"
    REQ_DETAIL_FILE=$f
    COLUMNS=100 screen detail; out=$OUT
    assert_contains '! invalid request: unknown field "field_made_up_1"' "${REQ_SCREEN_LINES[0]}" "the bar starts with the first problem"
    assert_eq " (+11 more)" "${REQ_SCREEN_LINES[0]: -11}" "and ends with the count of the others, never cut"
    assert_eq "1" "$(( ${#REQ_SCREEN_LINES[0]} <= 99 ))" "inside the terminal width"
    assert_eq "$f" "${REQ_SCREEN_LINES[2]}" "the path stays whole"
    assert_eq "$(( REQ_PROBLEMS_MAX_LINES ))" "$(grep -c '^  unknown field' <<<"$out")" "only the first problems are listed"
    assert_contains "  ... (2 more)" "$out" "and the rest is counted"
    assert_eq "1" "$(( ${#REQ_SCREEN_LINES[@]} <= REQ_PROBLEMS_MAX_LINES + 5 ))" "so the screen stays short"
}

test_invalid_long_path() {
    echo "nav: invalid request with a long path"
    make_project
    req_nav_init "$PROJ/.req"; req_nav_handle enter
    local i path len
    for i in "${!REQ_ITEM_LABEL[@]}"; do
        [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i
    done
    req_nav_handle enter
    COLUMNS=20 screen detail
    path=$PROJ/api/broken.get.json; len=${#path}
    assert_eq "$path" "${REQ_SCREEN_LINES[2]}" "the path is never truncated, even on a narrow terminal"
    assert_eq "$(( (len - 1) / 20 ))" "$REQ_SCREEN_EXTRA" "the rows its wrapping takes are counted for the redraw"
    assert_eq "1" "$(( REQ_SCREEN_EXTRA > 0 ))" "and a long path does wrap here"
    # The redraw count covers lines plus wrapped rows (only tracked on a terminal).
    COLUMNS=20 req_nav_build_list
    assert_eq "0" "$REQ_SCREEN_EXTRA" "other screens reset the extra rows"
}

test_truncate_scroll() {
    echo "nav: truncation and scrolling"
    local p=$TMP/big i out line max
    mkdir -p "$p/d"; printf 'd\n' >"$p/.req"
    for i in $(seq -w 1 30); do
        req_request_write "$p/d" "a-request-with-a-rather-long-name-number-$i" GET "http://example.com/$i" >/dev/null
    done
    req_nav_init "$p/.req"; req_nav_handle enter

    COLUMNS=30 screen list; out=$OUT; max=0
    while IFS= read -r line; do (( ${#line} > max )) && max=${#line}; done <<<"$out"
    assert_eq "1" "$(( max <= 30 ))" "no line exceeds the terminal width"
    assert_contains "~" "$out" "truncated text is marked"

    LINES=10 screen list; out=$OUT
    assert_eq "1" "$(( $(wc -l <<<"$out") <= 10 ))" "the list fits the terminal height"
    for i in $(seq 1 20); do req_nav_handle down; done
    LINES=10 screen list; out=$OUT
    assert_eq "20" "$REQ_SEL" "selection moved down 20 items"
    assert_contains "> GET    a-request-with-a-rather-long-name-number-21" "$out" "selected item stays visible"
    assert_contains "(21/30)" "$out" "position updated"
    req_nav_handle up; req_nav_handle up
    assert_eq "18" "$REQ_SEL" "going up moves the selection back"
    LINES=10 screen list
    assert_contains "> GET    a-request-with-a-rather-long-name-number-19" "$OUT" "window follows the way up"
}

test_empty_project() {
    echo "nav: empty project"
    local p=$TMP/blank
    mkdir -p "$p"; : >"$p/.req"
    req_nav_init "$p/.req"
    screen list; assert_contains "(empty)" "$OUT" "an empty .req is indicated"
    req_nav_handle enter; req_nav_handle esc
    assert_eq "list" "$REQ_VIEW" "keys are harmless without items"
    req_nav_init "$p/missing" 2>/dev/null; assert_eq "1" "$?" "a missing .req fails"
}

# A producer made up for the tests: one bar above every screen (the real ones come later).
nav_test_producer_bar() { REQ_NOTIFICATION_LINES+=("$(req_notification_bar "a bar made up for the test")"); }
# A persistent notification made up for the tests, registered the way a feature will do it.
nav_test_check_notice() { REQ_NOTIFICATION_TEXT="a persistent notice made up for the test"; }

test_notification_bars() {
    echo "nav: notification bars"
    local p=$TMP/bars out first="! a bar made up for the test" nl=$'\n'
    local saved=("${REQ_NOTIFICATION_PRODUCERS[@]}")
    mkdir -p "$p"; : >"$p/.req"
    req_request_write "$p" ping GET "http://127.0.0.1:1/x" >/dev/null

    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "{>} Req" "$(head -n 1 <<<"$out")" "the first row of the screen is the logo"
    assert_eq "req" "$(sed -n 2p <<<"$out" | cut -c1-3)" "with no producer defined the header comes right under it"

    REQ_NOTIFICATION_PRODUCERS=(nav_test_producer_bar)
    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "$first" "$(sed -n 2p <<<"$out")" "a bar is the line under the logo"
    assert_contains "${first}${nl}req " "$out" "the list header comes right below it"
    assert_contains "${first}${nl}GET    ping" "$out" "the details screen has the bar too"
    assert_eq "2" "$(grep -c -F "$first" <<<"$out")" "one bar per draw: the list and the details"

    out=$(keys : h enter | req_nav_run "$p/.req" 2>&1)
    assert_contains "${first}${nl}req help" "$out" "the help screen has the bar too"
    REQ_NOTIFICATION_PRODUCERS=("${saved[@]}")

    local warn="! a warning made up for the test"
    req_notification_warn "a warning made up for the test"
    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "$warn" "$(sed -n 2p <<<"$out")" "a warning waiting when the menu opens is the bar of the first draw, under the logo"
    assert_eq "1" "$(grep -c -F "$warn" <<<"$out")" "and it is printed once: the details drawn next have none"
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
}

test_root_notice() {
    echo "nav: the root user's notice"
    local p=$TMP/rootnote out notice="! running as root: files you create or edit may end up owned by root, not you"
    local original COLUMNS=100       # wide enough for the whole notice
    original=$(declare -f req_notification_is_root)
    mkdir -p "$p"; : >"$p/.req"
    req_request_write "$p" ping GET "http://127.0.0.1:1/x" >/dev/null

    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_not_contains "running as root" "$out" "another user sees no notice"

    # shellcheck disable=SC2317  # called by the library, not from this file
    req_notification_is_root() { return 0; }
    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "$notice" "$(sed -n 2p <<<"$out")" "root sees it right under the logo"
    assert_eq "2" "$(grep -c -F "$notice" <<<"$out")" "at every draw: the list and the details"
    out=$(keys : h enter | req_nav_run "$p/.req" 2>&1)
    assert_contains "${notice}"$'\n'"req help" "$out" "also on the help screen"
    eval "$original"
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=()
}

test_config_warnings_in_the_bar() {
    echo "nav: settings problems go to the bar"
    local dir=$TMP/cfg-bar errfile=$TMP/cfg-bar.err
    mkdir -p "$dir"
    printf 'this line is not a key and a value\nsetting_made_up_for_the_test=1\nlog=maybe\n' >"$dir/config"
    local old_dir=$REQ_CONFIG_DIR
    REQ_CONFIG_DIR=$dir
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0

    REQ_NOTIFICATION_ACTIVE=1
    req_config_load 2>"$errfile"
    assert_eq "" "$(<"$errfile")" "with the menu open the terminal gets nothing"
    assert_contains "expected key=value; line ignored" "$REQ_NOTIFICATION_WARN" "the first problem is the warning"
    assert_contains "$dir/config:1:" "$REQ_NOTIFICATION_WARN" "with the file and the line"
    assert_eq "2" "$REQ_NOTIFICATION_WARN_MORE" "and the others are counted: (+2 more)"
    req_notification_collect
    assert_contains "(+2 more)" "${REQ_NOTIFICATION_LINES[0]}" "one bar line says so"

    REQ_NOTIFICATION_ACTIVE=0
    req_config_load 2>"$errfile"
    assert_eq "3" "$(grep -c '^req: warning:' "$errfile")" "outside the menu each one is still a line on stderr"
    REQ_CONFIG_DIR=$old_dir
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
}

test_run_failures_in_the_bar() {
    echo "nav: failures when running go to the bar"
    local p=$TMP/runfail out rule after COLUMNS=140
    local REQ_PROJECT_ID=""          # no project state: the cursor is neither saved nor restored between runs
    rule=$(printf '=%.0s' {1..140})
    mkdir -p "$p"; : >"$p/.req"
    # nothing listens on port 1: curl fails at once, with its own message
    req_request_write "$p" refused GET "http://127.0.0.1:1/x" >/dev/null
    # shellcheck disable=SC2016  # a ${key} placeholder, literal text
    req_request_write "$p" nokey GET 'http://127.0.0.1:1/${key_made_up_for_the_test}' >/dev/null
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_NOTIFICATION_ACTIVE=1

    out=$(keys down enter enter | req_nav_run "$p/.req" 2>&1)        # refused is the second item
    after=${out#*"$rule"}
    assert_not_contains "req: error:" "$out" "the terminal is not filled with the error text"
    assert_contains "! " "$after" "a warning bar is drawn after the result"
    assert_contains "request failed (curl exit code 7)" "$after" "it says what failed"
    assert_contains "Failed to connect" "$after" "with the message of curl"
    assert_contains "$rule" "$out" "and the result block is still closed by its rule"

    out=$(keys enter enter | req_nav_run "$p/.req" 2>&1)             # nokey is the first item
    assert_not_contains "req: error:" "$out" "a missing key does not fill the terminal either"
    assert_contains "! no value for key_made_up_for_the_test in environment \"default\"" "$out" "the bar names the key"
    assert_contains "set the variable" "$out" "and the guidance follows, as far as it fits"

    REQ_NOTIFICATION_ACTIVE=0
    out=$(keys enter enter | req_nav_run "$p/.req" 2>&1)
    assert_contains "req: error: no value for key_made_up_for_the_test" "$out" "outside the menu flag the errors stay on stderr"
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
}

test_legacy_layout_in_the_bar() {
    echo "nav: the files of the previous layout are warned about in the top bar"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local statedir; statedir=$(req_project_state_dir "$REQ_PROJECT_ID")
    rm -rf "$statedir/env" "$statedir/vars"; mkdir -p "$statedir/env"
    printf 'k=1\n' >"$statedir/vars"; printf 'k=2\n' >"$statedir/env/dev"; : >"$statedir/env/default"
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0; REQ_NOTIFICATION_ACTIVE=1
    req_project_activate "$PROJ"
    REQ_NOTIFICATION_ACTIVE=0
    assert_contains "$statedir/vars is from the previous layout and is no longer read" "$REQ_NOTIFICATION_WARN" "the first file is the warning"
    assert_eq "2" "$REQ_NOTIFICATION_WARN_MORE" "and the other two are counted after it"
    req_notification_collect
    assert_contains "(+2 more)" "${REQ_NOTIFICATION_LINES[0]}" "the bar says so"
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "and it is shown once"
    rm -rf "$statedir/env" "$statedir/vars"; req_project_activate "$PROJ"; REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_PROJECT_ID=""
}

# logo_block - the block of the current view as the loop draws it: the view, the prompt, the bars, the logo.
logo_block() { req_nav_overlay; req_notification_overlay; req_nav_logo_overlay; }

test_logo_row() {
    echo "nav: the logo is the first row of every screen"
    make_project
    req_nav_init "$PROJ/.req"
    local p out i
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0; REQ_NOTIFICATION_LINES=()
    req_nav_build_list; logo_block
    assert_eq "{>} Req" "${REQ_SCREEN_LINES[0]}" "the logo is the first row of the list"
    assert_contains "req / (1/2)" "${REQ_SCREEN_LINES[1]}" "and the header comes right under it"

    REQ_NOTIFICATION_WARN="a warning made up for the test"
    req_notification_collect
    req_nav_build_list; logo_block
    assert_eq "{>} Req" "${REQ_SCREEN_LINES[0]}" "a bar does not take the first row from it"
    assert_eq "! a warning made up for the test" "${REQ_SCREEN_LINES[1]}" "the bar is under the logo"
    assert_contains "req / (1/2)" "${REQ_SCREEN_LINES[2]}" "and the header under the bar"
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_LINES=()

    req_nav_build_help; logo_block
    assert_eq "{>} Req" "${REQ_SCREEN_LINES[0]}" "the help starts with it"
    assert_contains "req" "${REQ_SCREEN_LINES[1]}" "and its own first line follows"
    req_nav_build_config; logo_block
    assert_eq "{>} Req" "${REQ_SCREEN_LINES[0]}" "so does the settings screen"
    assert_contains "settings" "${REQ_SCREEN_LINES[1]}" "and its own first line follows"

    # the environment menu needs the state of the project
    req_project_activate "$PROJ" || return
    unset REQ_ENV
    type_keys : e n v enter
    req_nav_build_env; logo_block
    assert_eq "{>} Req" "${REQ_SCREEN_LINES[0]}" "so does the environment menu"
    assert_contains "environments" "${REQ_SCREEN_LINES[1]}" "and its own first line follows"
    req_nav_handle esc
    REQ_PROJECT_ID=""

    # the real loop: the list and the details of a request, each draw with the logo above
    p=$TMP/logo-loop; rm -rf "$p"; mkdir -p "$p"; : >"$p/.req"
    req_request_write "$p" ping GET "http://127.0.0.1:1/x" >/dev/null
    out=$(keys enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "{>} Req" "$(head -n 1 <<<"$out")" "the loop draws it first"
    assert_eq "2" "$(grep -c '^{>} Req$' <<<"$out")" "once for the list and once for the details, never twice in one block"
    out=$(keys h | req_nav_run "$p/.req" 2>&1)
    assert_eq "2" "$(grep -c '^{>} Req$' <<<"$out")" "and once for the help"

    # the block still fits the terminal: the logo, two bars, the header, the list and the command prompt
    p=$TMP/logo-many; rm -rf "$p"; mkdir -p "$p"; : >"$p/.req"
    for i in $(seq -w 1 30); do : >"$p/r$i.get.json"; done
    req_nav_init "$p/.req"
    REQ_NOTIFICATION_LINES=("! one" "! two"); REQ_CMD_ACTIVE=1; REQ_CMD_BUF="n"
    LINES=12 req_nav_build_list; logo_block
    assert_eq "11" "${#REQ_SCREEN_LINES[@]}" "with many items and the command prompt open the block leaves one of the 12 rows spare"
    REQ_CMD_ACTIVE=0
    LINES=12 req_nav_build_list; logo_block
    assert_eq "10" "${#REQ_SCREEN_LINES[@]}" "and two rows spare without the prompt"
    REQ_CMD_BUF=""; REQ_NOTIFICATION_LINES=()
    REQ_VIEW=list
}

test_status_in_the_bar() {
    echo "nav: what a command says goes to the bar at the top"
    make_project
    req_nav_init "$PROJ/.req"
    local out line
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_STATUS="created x.get.json"
    req_notification_collect
    req_nav_build_list; req_nav_overlay; req_notification_overlay
    assert_eq "! created x.get.json" "${REQ_SCREEN_LINES[0]}" "the message of a command is the bar above the header"
    assert_not_contains "created x.get.json" "${REQ_SCREEN_LINES[*]:1}" "and nowhere under it"
    assert_eq "" "$REQ_STATUS" "it is spent: drawn once"
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "at the next draw it is gone"

    # in the main loop, with a real command: drawn once, and the bar is right above the header
    out=$({ keys : "v yes" enter; keys : q enter; } | req_nav_run "$PROJ/.req" 2>&1)
    assert_eq "1" "$(grep -c 'verbose on for this session' <<<"$out")" "the message of :v is drawn once"
    line=$(grep -n 'verbose on for this session' <<<"$out" | cut -d: -f1)
    assert_contains "! verbose on for this session" "$(sed -n "${line}p" <<<"$out")" "in the bar"
    assert_contains "req / (1/2)" "$(sed -n "$(( line + 1 ))p" <<<"$out")" "and the line under it is the header of the list"
}

test_end_to_end() {
    echo "nav: full flow (local mock)"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    python3 -I "$ROOT/tests/mock_server.py" >"$TMP/port" 2>/dev/null &
    SERVER_PID=$!
    local i port out p=$TMP/e2e
    for i in {1..50}; do [[ -s $TMP/port ]] && break; sleep 0.1; done
    [[ -s $TMP/port ]] || { echo "  skip the mock server did not start"; return; }
    port=$(<"$TMP/port")

    mkdir -p "$p/svc"; printf 'svc\n' >"$p/.req"
    req_request_write "$p/svc" ping GET "http://127.0.0.1:$port/text" '{"description":"checks the service"}' >/dev/null

    out=$(keys enter enter enter enter | req_nav_run "$p/.req" 2>&1)
    assert_contains "GET    ping" "$out" "list and details shown"
    assert_contains "desc checks the service" "$out" "description on the details"
    assert_contains "HTTP 200" "$out" "request runs when confirmed on the details"
    assert_contains "hello text" "$out" "result shown"
    assert_contains "============================================================" "$out" "separator after the result"
    assert_eq "2" "$(grep -c '^HTTP 200' <<<"$out")" "a second Enter on the details runs again"
    assert_eq "3" "$(grep -c '^GET    ping' <<<"$out")" "details redrawn after each result"

    local notice="! a persistent notice made up for the test" rule
    rule=$(printf '=%.0s' {1..60})
    req_notification_register nav-test nav_test_check_notice
    out=$(keys enter enter enter | req_nav_run "$p/.req" 2>&1)
    assert_eq "4" "$(grep -c -F "$notice" <<<"$out")" "a persistent notification is on every draw: root, directory, details and details after the run"
    assert_contains "$notice" "${out#*"$rule"}" "and it is reprinted below the result of a request"
    REQ_NOTIFICATION_IDS=(); REQ_NOTIFICATION_CHECKS=()
}

# type <chars...> - sends each character to the handler, as the main loop would.
# A draw happens between two commands in the real loop, and it spends the warning of the one
# before: so typing starts with none waiting.
type_keys() { local c; REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0; for c in "$@"; do req_nav_handle "$c"; done; }

test_command_mode() {
    echo "nav: command mode"
    local n
    make_project
    req_nav_init "$PROJ/.req"
    req_nav_handle ":"
    assert_eq "1" "$REQ_CMD_ACTIVE" ": enters command mode"
    type_keys n d
    assert_eq "nd" "$REQ_CMD_BUF" "typed characters build the command"
    assert_eq "0" "$REQ_NAV_DIRTY" "typing does not rebuild the screen"
    req_nav_handle backspace
    assert_eq "n" "$REQ_CMD_BUF" "Backspace deletes a character"
    req_nav_handle up; req_nav_handle other
    assert_eq "n" "$REQ_CMD_BUF" "arrows are ignored while typing"
    assert_eq "0" "$REQ_SEL" "the selection does not move while typing"
    req_nav_handle esc
    assert_eq "0" "$REQ_CMD_ACTIVE" "Esc leaves command mode"
    assert_eq "" "$REQ_CMD_BUF" "and clears what was typed"
    req_nav_handle ":"; req_nav_handle backspace
    assert_eq "0" "$REQ_CMD_ACTIVE" "Backspace on an empty line leaves command mode"

    req_nav_handle ":"
    REQ_CMD_BUF="x"; REQ_NAV_DIRTY=0
    req_nav_build_list; n=${#REQ_SCREEN_LINES[@]}; req_nav_overlay
    assert_eq ":x_" "${REQ_SCREEN_LINES[-1]}" "the prompt is the last line"
    assert_eq "$(( n + 1 ))" "${#REQ_SCREEN_LINES[@]}" "one line more: it hides no row of the list"
    req_nav_handle esc

    type_keys : z z enter
    assert_contains "unknown command :zz" "$REQ_NOTIFICATION_WARN" "an unknown command is reported"
    req_notification_collect
    assert_contains "unknown command :zz" "${REQ_NOTIFICATION_LINES[0]}" "it becomes a warning bar at the next draw"
    req_notification_collect
    assert_eq "0" "${#REQ_NOTIFICATION_LINES[@]}" "and the warning is shown once"
    type_keys : enter
    assert_eq "0" "$REQ_CMD_ACTIVE" "an empty command just leaves command mode"
    type_keys : q enter
    assert_eq "1" "$REQ_QUIT" ":q quits"
    REQ_QUIT=0

    type_keys : e enter
    assert_contains "select a request first" "$REQ_NOTIFICATION_WARN" ":e on a directory explains itself"
    type_keys : d enter
    assert_contains "select a request first" "$REQ_NOTIFICATION_WARN" ":d on a directory explains itself"
    req_nav_handle "$(printf ':')"; assert_eq "1" "$REQ_CMD_ACTIVE" "command mode works on the root"
    req_nav_handle esc
}

test_command_actions() {
    echo "nav: commands that change the project"
    make_project
    req_nav_init "$PROJ/.req"
    REQ_INPUT_FD=3
    local i out

    # :nd at the root creates a project directory and lists it in the .req.
    type_keys : n d
    req_nav_handle enter 3<<<"billing" >/dev/null
    assert_eq "$PROJ/billing" "$REQ_LAST_DIR" ":nd at the root creates the directory"
    [[ -d $PROJ/billing ]]; assert_eq "0" "$?" "and it is a plain directory"
    assert_eq $'api\nauth' "$(<"$PROJ/.req")" "the .req is not touched"
    assert_eq "api auth billing" "${REQ_ITEM_LABEL[*]}" "the root list is refreshed"
    assert_eq "2" "$REQ_SEL" "and the new directory is selected"
    assert_contains "created directory billing" "$REQ_STATUS" "status mentions it"

    req_nav_handle enter; req_nav_handle esc    # enter and leave billing
    REQ_SEL=0; req_nav_handle enter             # api
    # :nd inside a directory creates a real subdirectory
    type_keys :
    REQ_CMD_BUF="nd orders"
    req_nav_handle enter >/dev/null
    [[ -d $PROJ/api/orders ]]; assert_eq "0" "$?" ":nd <name> creates a subdirectory without prompting"
    assert_eq "orders" "${REQ_ITEM_LABEL[REQ_SEL]}" "and selects it"

    # :n creates a request here
    type_keys : n
    req_nav_handle enter 3<<<$'fresh-one
PATCH
http://x/f
n
' >/dev/null
    [[ -f $PROJ/api/fresh-one.patch.json ]]; assert_eq "0" "$?" ":n creates a request in the current directory"
    assert_eq "fresh-one" "${REQ_ITEM_LABEL[REQ_SEL]}" "and selects it"
    assert_contains "created fresh-one.patch.json" "$REQ_STATUS" "status mentions it"
    assert_eq "list" "$REQ_VIEW" "back on the list"

    # :e renames the selected request
    type_keys : e
    req_nav_handle enter 3<<<$'1
renamed
s
' >/dev/null
    [[ -f $PROJ/api/renamed.patch.json && ! -e $PROJ/api/fresh-one.patch.json ]]
    assert_eq "0" "$?" ":e saves the edit (and renames the file)"
    assert_eq "renamed" "${REQ_ITEM_LABEL[REQ_SEL]}" "the list follows the rename"

    # :e from the details screen keeps showing the (renamed) request
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "opens the details"
    type_keys : e
    req_nav_handle enter 3<<<$'1
renamed-again
s
' >/dev/null
    assert_eq "$PROJ/api/renamed-again.patch.json" "$REQ_DETAIL_FILE" "the details screen follows the rename"
    req_nav_handle esc

    # :e cancelled leaves everything as it was
    type_keys : e
    req_nav_handle enter 3<<<$'q
' >/dev/null
    [[ -f $PROJ/api/renamed-again.patch.json ]]; assert_eq "0" "$?" "a cancelled edit changes nothing"

    # :d duplicates and edits the copy
    type_keys : d
    req_nav_handle enter 3<<<$'twin
s
' >/dev/null
    [[ -f $PROJ/api/twin.patch.json && -f $PROJ/api/renamed-again.patch.json ]]
    assert_eq "0" "$?" ":d creates the copy and keeps the original"
    assert_eq "twin" "${REQ_ITEM_LABEL[REQ_SEL]}" "the copy is selected"
    type_keys : d
    req_nav_handle enter 3<<<$'twin-2
q
' >/dev/null
    [[ -f $PROJ/api/twin-2.patch.json ]]; assert_eq "0" "$?" "cancelling the edit of a copy keeps the copy"
    assert_eq "twin-2" "${REQ_ITEM_LABEL[REQ_SEL]}" "and selects it"

    # an invalid request cannot be edited or duplicated
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i; done
    type_keys : e
    out=$(req_nav_handle enter 3<<<$'q
' 2>&1)
    assert_contains "fix the file first" "$out" ":e refuses an invalid request"
    REQ_INPUT_FD=0
}

test_clear_screen() {
    echo "nav: Ctrl-L clears the screen"
    make_project
    req_nav_init "$PROJ/.req"
    local ff=$'\f' i dir sel file out
    req_nav_handle enter                                        # api/
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    dir=$REQ_CUR_DIR; sel=$REQ_SEL
    REQ_SCREEN_DRAWN=9
    req_nav_handle "$ff"
    assert_eq "0" "$REQ_SCREEN_DRAWN" "the next draw has nothing to erase: the rows are gone"
    assert_eq "list" "$REQ_VIEW" "the list stays"
    assert_eq "$dir" "$REQ_CUR_DIR" "in the same directory"
    assert_eq "$sel" "$REQ_SEL" "with the same selection"
    assert_eq "1" "$REQ_NAV_DIRTY" "and the screen is built again"
    REQ_SCREEN_DRAWN=9; req_nav_clear_screen >"$TMP/clear_out"
    assert_eq "" "$(<"$TMP/clear_out")" "outside a terminal nothing is printed"
    assert_eq "0" "$REQ_SCREEN_DRAWN" "(the rows are forgotten all the same)"

    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "(a request is open)"
    file=$REQ_DETAIL_FILE
    req_nav_handle "$ff"
    assert_eq "detail" "$REQ_VIEW" "the details stay"
    assert_eq "$file" "$REQ_DETAIL_FILE" "with the same request"

    type_keys : a b
    req_nav_handle "$ff"
    assert_eq "1" "$REQ_CMD_ACTIVE" "command mode stays"
    assert_eq "ab" "$REQ_CMD_BUF" "with what was typed"
    type_keys esc

    type_keys : h enter
    req_nav_handle "$ff"
    assert_eq "help" "$REQ_VIEW" "the help stays open (any other key closes it)"
    req_nav_handle x
    assert_eq "detail" "$REQ_VIEW" "and a key closes it, back to the details"

    out=$(printf '%s\n' "${REQ_HELP_ROWS[@]}")
    assert_contains "Ctrl-L|clear the screen" "$out" "the help lists Ctrl-L"
    out=$(keys down clear enter | req_nav_run "$PROJ/.req" 2>&1)
    assert_eq "2" "$(grep -c '(2/2)' <<<"$out")" "in the loop, the key draws the list again with the same selection"
    assert_contains "req /auth" "$out" "and the Enter after it opens that selection"
}

test_view_key() {
    echo "nav: v shows the last response"
    make_project
    req_nav_init "$PROJ/.req"
    local stub=$TMP/view_stub old_path=$PATH i
    mkdir -p "$stub"
    # A less made up for the test: it keeps what it was given and does not wait for a key.
    cat >"$stub/less" <<'EOF'
#!/bin/sh
cat >"$REQ_TEST_PAGER_IN"
EOF
    chmod +x "$stub/less"
    export REQ_TEST_PAGER_IN=$TMP/view_in
    unset PAGER
    PATH=$stub:$PATH
    REQ_NOTIFICATION_ACTIVE=1; REQ_COLORS=0

    REQ_RESULT=""; REQ_NOTIFICATION_WARN=""; REQ_SCREEN_DRAWN=5; rm -f "$REQ_TEST_PAGER_IN"
    req_nav_handle v
    assert_contains "run a request first" "$REQ_NOTIFICATION_WARN" "nothing to view yet: a warning in the bar"
    [[ ! -e $REQ_TEST_PAGER_IN ]]; assert_eq "0" "$?" "and no pager"
    assert_eq "5" "$REQ_SCREEN_DRAWN" "the menu is not erased for nothing"

    REQ_RESULT=ok; REQ_RESP_CTYPE=application/json; REQ_RESP_BODY='{"shown_by_the_test":1}'
    req_nav_handle v
    assert_contains '"shown_by_the_test": 1' "$(<"$REQ_TEST_PAGER_IN")" "on the list, v hands the response to the pager"
    assert_eq "0" "$REQ_SCREEN_DRAWN" "and the menu is drawn again after it"
    assert_eq "list" "$REQ_VIEW" "in the same view"

    req_nav_handle enter                                        # api/
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "(a request is open)"
    rm -f "$REQ_TEST_PAGER_IN"
    req_nav_handle v
    [[ -s $REQ_TEST_PAGER_IN ]]; assert_eq "0" "$?" "on the details too"
    assert_eq "detail" "$REQ_VIEW" "which stay open"

    rm -f "$REQ_TEST_PAGER_IN"
    type_keys : v
    assert_eq "v" "$REQ_CMD_BUF" "in command mode v is a letter of the command"
    type_keys esc
    type_keys : h enter
    req_nav_handle v
    [[ ! -e $REQ_TEST_PAGER_IN ]]; assert_eq "0" "$?" "on the help any key closes it: no pager"
    assert_eq "detail" "$REQ_VIEW" "back to the details"

    # a response adds nothing to the screens: v is in the help, not in a hint line
    REQ_VIEW=list; COLUMNS=100 req_nav_build_list
    assert_not_contains "v response" "${REQ_SCREEN_LINES[*]}" "the list has no hint about v when there is a response"
    REQ_VIEW=detail; req_nav_build_detail
    assert_not_contains "v response" "${REQ_SCREEN_LINES[*]}" "nor have the details"
    assert_contains "v|show the last response" "$(printf '%s\n' "${REQ_HELP_ROWS[@]}")" "the help lists v"

    PATH=$old_path; REQ_NOTIFICATION_ACTIVE=0; REQ_NOTIFICATION_WARN=""; REQ_RESP_CTYPE=""; REQ_RESP_BODY=""; REQ_VIEW=list
}

test_help() {
    echo "nav: help screen"
    make_project
    req_nav_init "$PROJ/.req"
    local out row i
    type_keys : h enter
    assert_eq "help" "$REQ_VIEW" ":h opens the help"
    REQ_NAV_DIRTY=1; req_nav_build_help; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "Enter  " "$out" "lists Enter"
    assert_contains "Esc / q" "$out" "lists Esc and q together"
    assert_contains "h  " "$out" "lists the key h"
    assert_contains "q leaves it (Esc does not)" "${REQ_HELP_ROWS[*]}" "the row of v says that q, not Esc, leaves the pager"
    assert_contains ":nd [name]" "$out" "lists a command with its argument"
    assert_contains "any key  closes" "$out" "says that any key closes it"
    assert_not_contains "Press any key" "$out" "and has no footer line about it"
    for row in ":n" ":nd" ":e" ":d" ":h" ":q"; do
        assert_contains "$row" "$out" "every command is listed: $row"
    done
    # The help is the only place that lists the keys: one row for each, and whole at 80 columns.
    for row in up/down Enter "Esc / q" h v Ctrl-L Ctrl-C : "any key"; do
        assert_contains " $row|" " ${REQ_HELP_ROWS[*]}" "the table has a row for the key: $row"
    done
    COLUMNS=80 req_nav_build_help; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    for row in "${REQ_HELP_ROWS[@]}"; do
        [[ $row == Commands ]] && break
        [[ $row == *'|'* ]] && assert_contains "${row#*|}" "$out" "at 80 columns the row of ${row%%|*} is not cut"
    done
    req_nav_handle x
    assert_eq "list" "$REQ_VIEW" "any key returns to the list"
    req_nav_handle enter                                        # api/
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "(a request is open)"
    type_keys : help enter; req_nav_handle up
    assert_eq "detail" "$REQ_VIEW" ":help returns to the details it was opened from"
    REQ_VIEW=list
    req_nav_build_list; assert_not_contains ":h help" "${REQ_SCREEN_LINES[*]}" "the list has no footer pointing to :h"
    REQ_VIEW=detail; req_nav_build_detail
    assert_not_contains ":h help" "${REQ_SCREEN_LINES[*]}" "nor have the details"
    REQ_VIEW=list
    type_keys : z enter
    assert_contains ":h" "$REQ_NOTIFICATION_WARN" "unknown command points to :h"
}

test_key_h() {
    echo "nav: the key h opens the help"
    make_project
    req_nav_init "$PROJ/.req"
    local i
    req_nav_handle h
    assert_eq "help" "$REQ_VIEW" "h opens the help on the list"
    assert_eq "list" "$REQ_HELP_BACK" "which goes back to the list"
    req_nav_handle x
    assert_eq "list" "$REQ_VIEW" "any key closes it"
    req_nav_handle h; req_nav_handle h
    assert_eq "list" "$REQ_VIEW" "and so does h itself"

    req_nav_handle enter                                        # api/
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "a request is open"
    req_nav_handle h
    assert_eq "help" "$REQ_VIEW" "h opens the help on the details"
    assert_eq "detail" "$REQ_HELP_BACK" "which goes back to the details"
    req_nav_handle q
    assert_eq "detail" "$REQ_VIEW" "any key (q here) closes it, back on the details"
    assert_eq "$PROJ/api/list-users.get.json" "$REQ_DETAIL_FILE" "of the same request"

    type_keys : h
    assert_eq "h" "$REQ_CMD_BUF" "in command mode h is a letter"
    assert_eq "detail" "$REQ_VIEW" "and opens nothing"
    req_nav_handle esc

    REQ_VIEW="env"; REQ_ENV_BACK=list; REQ_ENV_CHOICES=(default); REQ_ENV_SEL=0
    req_nav_handle h
    assert_eq "env" "$REQ_VIEW" "on the :env menu h is not a key"
    REQ_VIEW=list
}

test_command_rename_dir() {
    echo "nav: :ed"
    make_project
    req_nav_init "$PROJ/.req"
    REQ_INPUT_FD=3
    local out

    type_keys : e d
    req_nav_handle enter 3<<<"gateway" >/dev/null
    [[ -d $PROJ/gateway/v2 && ! -e $PROJ/api ]]; assert_eq "0" "$?" ":ed renames the directory under the cursor"
    assert_eq "auth gateway" "${REQ_ITEM_LABEL[*]}" "the root list is refreshed (sorted)"
    assert_eq "gateway" "${REQ_ITEM_LABEL[REQ_SEL]}" "the renamed directory stays selected"
    assert_contains "renamed to gateway" "$REQ_STATUS" "status mentions it"

    type_keys :
    REQ_CMD_BUF="ed identity"
    REQ_SEL=0; req_nav_handle enter >/dev/null
    [[ -d $PROJ/identity ]]; assert_eq "0" "$?" ":ed <name> skips the prompt"
    assert_eq "gateway identity" "${REQ_ITEM_LABEL[*]}" "the list shows the new name"

    REQ_SEL=0; req_nav_handle enter              # gateway
    type_keys : e d
    req_nav_handle enter 3<<<"v9" >/dev/null
    [[ -d $PROJ/gateway/v9 ]]; assert_eq "0" "$?" ":ed renames a subdirectory"
    assert_eq "v9" "${REQ_ITEM_LABEL[REQ_SEL]}" "and selects it"

    # On a request there is nothing to rename.
    REQ_SEL=2
    type_keys : e d; req_nav_handle enter >/dev/null
    assert_contains "edit a request with :e" "$REQ_NOTIFICATION_WARN" ":ed on a request points to :e"
    REQ_INPUT_FD=0
}

test_command_copy() {
    echo "nav: :cp"
    make_project
    req_nav_init "$PROJ/.req"
    REQ_INPUT_FD=3

    type_keys : c p
    req_nav_handle enter 3<<<"" >/dev/null
    [[ -f $PROJ/api-copy/list-users.get.json && -d $PROJ/api-copy/v2 ]]; assert_eq "0" "$?" ":cp copies the directory under the cursor"
    assert_eq "api api-copy auth" "${REQ_ITEM_LABEL[*]}" "the root list is refreshed (sorted)"
    assert_eq "api-copy" "${REQ_ITEM_LABEL[REQ_SEL]}" "and the copy is selected"
    assert_contains "copied to api-copy" "$REQ_STATUS" "status mentions it"

    type_keys :
    REQ_CMD_BUF="cp replica"
    REQ_SEL=2; req_nav_handle enter >/dev/null
    [[ -d $PROJ/replica ]]; assert_eq "0" "$?" ":cp <name> skips the prompt"

    REQ_SEL=0; req_nav_handle enter              # api
    REQ_SEL=0; type_keys : c p                   # v2
    req_nav_handle enter 3<<<"" >/dev/null
    [[ -d $PROJ/api/v2-copy ]]; assert_eq "0" "$?" ":cp copies a subdirectory"
    assert_eq "v2-copy" "${REQ_ITEM_LABEL[REQ_SEL]}" "and selects it"

    # A request is copied too: the new name is asked for and no edit menu follows.
    local i
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == create ]] && REQ_SEL=$i; done
    type_keys : c p
    req_nav_handle enter 3<<<"create-two" >"$TMP/cp.out" 2>&1
    [[ -f $PROJ/api/create-two.post.json && -f $PROJ/api/create.post.json ]]; assert_eq "0" "$?" ":cp copies a request"
    assert_eq "$(jq -c 'del(.name)' "$PROJ/api/create.post.json")" "$(jq -c 'del(.name)' "$PROJ/api/create-two.post.json")" "with the same fields"
    [[ $(<"$TMP/cp.out") != *"Editing"* ]]; assert_eq "0" "$?" "without opening the edit menu"
    assert_eq "create-two" "${REQ_ITEM_LABEL[REQ_SEL]}" "the copy is selected"
    assert_contains "copied to create-two.post.json" "$REQ_STATUS" "status mentions it"
    assert_eq "list" "$REQ_VIEW" "and the list is shown"

    # From the details screen the open request is copied.
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "opens the details"
    type_keys : c p
    req_nav_handle enter 3<<<"create-three" >/dev/null 2>&1
    [[ -f $PROJ/api/create-three.post.json ]]; assert_eq "0" "$?" ":cp on the details copies the open request"
    assert_eq "list" "$REQ_VIEW" "and returns to the list"

    # :c is gone; an invalid request cannot be copied; nothing selected.
    type_keys : c enter
    assert_contains "unknown command :c" "$REQ_NOTIFICATION_WARN" ":c no longer exists"
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i; done
    type_keys : c p
    req_nav_handle enter 3<<<"x" >/dev/null 2>&1
    [[ ! -e $PROJ/api/x.get.json ]]; assert_eq "0" "$?" "an invalid request is not copied"
    REQ_INPUT_FD=0
}

test_command_config() {
    echo "nav: :config"
    make_project
    req_nav_init "$PROJ/.req"
    local out f=$REQ_CONFIG_DIR/config
    rm -f "$f"

    type_keys : c o n f i g enter
    assert_eq "config" "$REQ_VIEW" ":config opens the settings screen"
    REQ_NAV_DIRTY=1; req_nav_build_config; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "time_stats" "$out" "lists a key"
    assert_contains "restore_cursor" "$out" "lists every known key"
    assert_contains "default yes" "$out" "with its default"
    assert_contains "$f" "$out" "and says which file it is"
    assert_contains "Change one with :config key=value" "$out" "and how to change one"
    assert_not_contains "Press any key" "$out" "with no line about how to go back"
    req_nav_handle x
    assert_eq "list" "$REQ_VIEW" "any key returns to the list"

    type_keys : c o n f i g ' ' - g ' ' t i m e _ s t a t s = n o enter
    assert_eq "list" "$REQ_VIEW" ":config -g key=value stays on the list"
    assert_contains "time_stats=no saved" "$REQ_STATUS" "and says it was saved"
    assert_eq "no" "$(req_kv_get "$f" time_stats)" "the value is written to the global file"
    assert_eq "no" "$(req_config_get time_stats)" "and is in effect"
    type_keys : c o n f i g enter
    REQ_NAV_DIRTY=1; req_nav_build_config; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "time_stats         no    default yes" "$out" "the screen shows the new value next to the default"
    req_nav_handle x

    REQ_CMD_BUF="config -g time_stats = yes"; type_keys :; REQ_CMD_BUF="config -g time_stats = yes"; req_nav_handle enter
    assert_eq "yes" "$(req_kv_get "$f" time_stats)" "spaces around the = are fine"

    REQ_STATUS=""; type_keys : c o n f i g ' ' - g ' ' c o l o r = r e d enter
    assert_contains 'unknown setting "color"' "$REQ_NOTIFICATION_WARN" "an unknown key is explained"
    assert_contains "time_stat_total" "$REQ_NOTIFICATION_WARN" "with the valid keys"
    type_keys : c o n f i g ' ' - g ' ' t i m e _ s t a t s = m a y b e enter
    assert_contains "time_stats must be yes or no" "$REQ_NOTIFICATION_WARN" "a wrong value says what is accepted"
    assert_eq "yes" "$(req_kv_get "$f" time_stats)" "and nothing is written"
    type_keys : c o n f i g ' ' - g ' ' t i m e _ s t a t s enter
    assert_contains "usage: :config" "$REQ_NOTIFICATION_WARN" "a key without a value shows the usage"
    [[ $(<"$f") != *color* ]]; assert_eq "0" "$?" "an invalid setting never reaches the file"

    out=$(printf '%s\n' "${REQ_HELP_ROWS[@]}")
    assert_contains ":config" "$out" "the help lists :config"

    echo "nav: :config (project by default)"
    local lf
    REQ_PROJECT_ID=""
    type_keys : c o n f i g ' ' l o g = y e s enter
    assert_contains "no project is open" "$REQ_NOTIFICATION_WARN" "without a project the setting is refused"
    assert_contains ":config -g" "$REQ_NOTIFICATION_WARN" "and -g is suggested"
    [[ ! -e $f ]] || [[ $(<"$f") != *log* ]]; assert_eq "0" "$?" "nothing is written"
    REQ_PROJECT_ID=$(req_project_create "$PROJ"); lf=$(req_config_local_file)
    mkdir -p "$(dirname "$lf")"
    type_keys : c o n f i g ' ' l o g = y e s enter
    assert_contains "log=yes saved in $lf" "$REQ_STATUS" "key=value says the project file was written"
    assert_eq "yes" "$(req_kv_get "$lf" log)" "the value is in the project file"
    [[ ! -e $f ]] || [[ $(<"$f") != *log* ]]; assert_eq "0" "$?" "and not in the global one"
    assert_eq "yes" "$(req_config_get log)" "and is in effect"
    type_keys : c o n f i g ' ' - g ' ' t i m e _ s t a t s = n o enter
    assert_contains "saved in $f" "$REQ_STATUS" "-g writes the global file"
    req_kv_set "$lf" time_stats yes; req_config_load
    assert_eq "yes" "$(req_config_get time_stats)" "the project value wins over the global one"
    type_keys : c o n f i g enter
    REQ_NAV_DIRTY=1; req_nav_build_config; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "$lf" "$out" "the screen names the project file"
    assert_contains "-g" "$out" "and the way to change the global one"
    assert_contains "log                yes   default no    project" "$out" "it marks a value that comes from the project"
    assert_contains "time_stats         yes   default yes   project" "$out" "even when it equals the default"
    [[ $out != *"restore_cursor     yes   default yes   project"* ]]; assert_eq "0" "$?" "a global or default value is not marked"
    req_nav_handle x
    type_keys : c o n f i g ' ' - g enter
    assert_contains "usage: :config [-g]" "$REQ_NOTIFICATION_WARN" "-g alone shows the usage"
    type_keys : c o n f i g ' ' l o g = m a y b e enter
    assert_contains "log must be yes or no" "$REQ_NOTIFICATION_WARN" "the value is checked for the project too"
    assert_eq "yes" "$(req_kv_get "$lf" log)" "and nothing is written"
    REQ_PROJECT_ID=""; rm -f "$f" "$lf"; req_config_load
}

# env_vars <env> <text> - makes the folder of an environment of the open project and writes its vars file.
env_vars() { local d; d=$(req_env_dir "$REQ_PROJECT_ID" "$1"); mkdir -p "$d"; printf '%s' "$2" >"$d/vars"; }

test_command_env() {
    echo "nav: :env"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local envdir
    envdir=$(req_project_state_dir "$REQ_PROJECT_ID" env)
    unset REQ_ENV
    REQ_INPUT_FD=3

    type_keys : e n v enter
    assert_eq "env" "$REQ_VIEW" ":env opens the environment menu"
    assert_eq "default" "${REQ_ENV_CHOICES[*]}" "which lists default, made when the project was opened"
    req_nav_handle esc

    env_vars dev $'url=http://dev\n'; env_vars prod $'url=http://prod\n'
    type_keys : e n v enter
    assert_eq "default dev prod" "${REQ_ENV_CHOICES[*]}" "the menu lists the environments of the project"
    req_nav_handle esc

    type_keys : e n v ' ' d e v
    req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "dev" "$REQ_ENV" ":env <name> switches the session, with no question for an environment that exists"
    assert_contains "environment: dev" "$REQ_STATUS" "and says so"
    req_nav_build_list; assert_contains "proj @ dev" "${REQ_SCREEN_LINES[0]}" "the header follows"
    type_keys : e n v enter
    assert_eq "1" "$REQ_ENV_SEL" "and the menu opens on the new one"
    req_nav_handle esc

    # An environment that does not exist is offered for creation.
    type_keys : e n v ' ' s t a g i n g
    req_nav_handle enter 3<<<"n" >"$TMP/env-question.txt"
    assert_contains 'Create environment "staging"? [Y/n]' "$(<"$TMP/env-question.txt")" "an unknown environment asks before it is created"
    assert_eq "dev" "$REQ_ENV" "answering n changes nothing"
    [[ ! -e $envdir/staging ]]; assert_eq "0" "$?" "and creates nothing"
    assert_contains 'environment "staging" not created (in use: dev)' "$REQ_STATUS" "and says so"
    type_keys : e n v ' ' s t a g i n g; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "dev" "$REQ_ENV" "end of input counts as no"
    [[ ! -e $envdir/staging ]]; assert_eq "0" "$?" "and creates nothing"

    type_keys : e n v ' ' s t a g i n g; req_nav_handle enter 3<<<"" >/dev/null
    assert_eq "staging" "$REQ_ENV" "Enter creates it and switches to it"
    [[ -f $envdir/staging/vars ]]; assert_eq "0" "$?" "the vars file is in a folder of the environment, in the project's env folder"
    assert_eq "600" "$(stat -c %a "$envdir/staging/vars")" "private"
    assert_eq "700" "$(stat -c %a "$envdir/staging")" "in a private folder"
    assert_eq "$(req_vars_template staging)" "$(<"$envdir/staging/vars")" "starting with the template"
    assert_contains "environment: staging, created in $envdir/staging/vars" "$REQ_STATUS" "the status says where the file is"
    req_nav_build_list; assert_contains "proj @ staging" "${REQ_SCREEN_LINES[0]}" "the header follows"
    type_keys : e n v enter
    assert_eq "default dev prod staging" "${REQ_ENV_CHOICES[*]}" "and the menu lists it"
    req_nav_handle esc

    type_keys : e n v ' ' q a; req_nav_handle enter 3<<<"yes" >/dev/null
    assert_eq "qa" "$REQ_ENV" "yes creates it too"
    [[ -f $envdir/qa/vars ]]; assert_eq "0" "$?" "with its file"
    printf 'k=kept-by-the-test\n' >"$envdir/qa/vars"
    type_keys : e n v ' ' d e v; req_nav_handle enter 3<<<"" >/dev/null
    type_keys : e n v ' ' q a; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "k=kept-by-the-test" "$(<"$envdir/qa/vars")" "an environment that exists is never touched"

    req_env_use direct-test-env now 3</dev/null
    assert_eq "direct-test-env" "$REQ_ENV" "req_env_use ... now creates with no question"
    [[ -f $envdir/direct-test-env/vars ]]; assert_eq "0" "$?" "and makes the file"

    type_keys : e n v ' ' B a d; req_nav_handle enter 3<<<"y" >/dev/null
    assert_eq "direct-test-env" "$REQ_ENV" "a name that is not a slug changes nothing"
    assert_contains "invalid environment name" "$REQ_NOTIFICATION_WARN" "and is refused"
    [[ ! -e $envdir/Bad ]]; assert_eq "0" "$?" "nothing is created for it"

    rm -rf "$envdir/default"
    type_keys : e n v ' ' d e f a u l t; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "default" "$REQ_ENV" "default can always be chosen, even if its folder is gone"
    [[ ! -e $envdir/default ]]; assert_eq "0" "$?" "and choosing it makes nothing"

    if (( EUID != 0 )); then       # root ignores the permissions
        chmod 500 "$envdir"
        type_keys : e n v ' ' l o c k e d; req_nav_handle enter 3<<<"y" >/dev/null
        chmod 700 "$envdir"
        assert_eq "default" "$REQ_ENV" "an environment that cannot be made changes nothing"
        assert_contains "cannot create $envdir/locked" "$REQ_NOTIFICATION_WARN" "and the warning names it with the absolute path"
    fi

    REQ_PROJECT_ID=""; type_keys : e n v ' ' p r o d enter
    assert_eq "default" "$REQ_ENV" "without a saved project state only default is allowed"
    assert_contains "not available" "$REQ_NOTIFICATION_WARN" "and the reason is given"
    type_keys : e n v ' ' n e w; req_nav_handle enter 3<<<"y" >/dev/null
    assert_eq "default" "$REQ_ENV" "and nothing is asked or created for another one"
    assert_contains "unknown environment \"new\"" "$REQ_NOTIFICATION_WARN" "which is unknown"
    type_keys : e n v enter
    assert_eq "list" "$REQ_VIEW" "with no project state there is no menu"
    assert_contains "only the default environment can be used (in use: default)" "$REQ_NOTIFICATION_WARN" "a warning says why"
    assert_contains ":env" "$(printf '%s\n' "${REQ_HELP_ROWS[@]}")" "the help lists :env"
    REQ_INPUT_FD=0
    unset REQ_ENV
}

test_env_menu() {
    echo "nav: the environment menu"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local envdir out i
    envdir=$(req_project_state_dir "$REQ_PROJECT_ID" env)
    unset REQ_ENV
    rm -rf "$envdir"; req_env_create default          # the central directory is shared with the other tests
    env_vars dev $'url=http://dev\ntoken=dev-token\n'
    env_vars prod $'url=http://prod\n'

    type_keys : e n v enter
    assert_eq "env" "$REQ_VIEW" ":env opens the menu"
    assert_eq "list" "$REQ_ENV_BACK" "which goes back to the list"
    assert_eq "default dev prod" "${REQ_ENV_CHOICES[*]}" "with default first, then the others in order"
    assert_eq "0" "$REQ_ENV_SEL" "the selection starts on the environment in use"
    req_nav_build_env; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "req environments  proj  (in use: default)" "${REQ_SCREEN_LINES[0]}" "the header names the project and the environment in use"
    assert_contains "> default (in use)" "$out" "the selected row is marked, and so is the one in use"
    assert_contains "  dev" "$out" "the others are listed below it"
    assert_not_contains "dev (in use)" "$out" "only the one in use is marked"
    assert_not_contains "Enter choose" "$out" "the menu has no hint line about the keys"
    assert_not_contains "Esc cancel" "$out" "nor about how to leave"
    assert_eq "5" "${#REQ_SCREEN_LINES[@]}" "just the header, three environments and the new one"
    assert_eq "  + new environment" "${REQ_SCREEN_LINES[4]}" "the last row is + new environment"

    req_nav_handle down; assert_eq "1" "$REQ_ENV_SEL" "down moves the selection"
    req_nav_handle down; req_nav_handle down
    assert_eq "3" "$REQ_ENV_SEL" "down reaches + new environment, after the last one"
    req_nav_build_env; assert_eq "> + new environment" "${REQ_SCREEN_LINES[4]}" "which is highlighted like the others"
    req_nav_handle down; assert_eq "0" "$REQ_ENV_SEL" "and wraps around at the end"
    req_nav_handle up; assert_eq "3" "$REQ_ENV_SEL" "up wraps around at the start, to + new environment"
    req_nav_handle up; assert_eq "2" "$REQ_ENV_SEL" "and goes on up from there"
    for k in v : x n h; do req_nav_handle "$k"; done
    assert_eq "env" "$REQ_VIEW" "other keys do nothing: the menu stays"
    assert_eq "0" "$REQ_CMD_ACTIVE" "and : does not open command mode"
    assert_eq "2" "$REQ_ENV_SEL" "or move the selection"
    req_nav_handle $'\f'
    assert_eq "env" "$REQ_VIEW" "Ctrl-L keeps the menu open"

    req_nav_handle esc
    assert_eq "list" "$REQ_VIEW" "Esc goes back to the list"
    assert_eq "" "${REQ_ENV:-}" "changing nothing"
    assert_eq "" "$REQ_STATUS" "and saying nothing"

    type_keys : e n v enter; req_nav_handle down
    req_nav_handle enter
    assert_eq "list" "$REQ_VIEW" "Enter goes back to the list"
    assert_eq "dev" "$REQ_ENV" "having switched to the row under the selection"
    assert_contains "environment: dev (2 variables)" "$REQ_STATUS" "and its variables are loaded"
    req_nav_build_list; assert_contains "proj @ dev" "${REQ_SCREEN_LINES[0]}" "the header follows"
    type_keys : e n v enter
    assert_eq "1" "$REQ_ENV_SEL" "the menu opens on the environment in use"
    req_nav_build_env; assert_contains "> dev (in use)" "$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")" "which is the marked one"
    req_nav_handle enter
    assert_contains "environment: dev (2 variables)" "$REQ_STATUS" "choosing the one in use loads it again"

    # Opened from the details of a request: back to the details, which stay as they were.
    req_nav_handle enter                         # api
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "a request is open"
    type_keys : e n v enter
    assert_eq "detail" "$REQ_ENV_BACK" "the menu remembers where it came from"
    req_nav_handle esc
    assert_eq "detail" "$REQ_VIEW" "Esc returns to the details"
    type_keys : e n v enter; req_nav_handle up
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "so does choosing"
    assert_eq "default" "$REQ_ENV" "after switching (up from dev is default)"
    assert_contains "list-users.get.json" "$REQ_DETAIL_FILE" "and the request is still the open one"

    # Many environments: a window, like the list's, that follows the selection.
    for i in $(seq -w 1 30); do mkdir "$envdir/many-test-env-$i"; done
    REQ_VIEW=list; type_keys : e n v enter
    LINES=10 req_nav_build_env
    assert_eq "1" "$(( ${#REQ_SCREEN_LINES[@]} <= 10 ))" "the menu fits the terminal height"
    for i in $(seq 1 20); do req_nav_handle down; done
    LINES=10 req_nav_build_env; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "> many-test-env-" "$out" "the selected row stays in the window"
    assert_eq "20" "$REQ_ENV_SEL" "after moving down 20 rows"
    COLUMNS=24 req_nav_build_env; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}"); local max=0 line
    while IFS= read -r line; do (( ${#line} > max )) && max=${#line}; done <<<"$out"
    assert_eq "1" "$(( max <= 24 ))" "no line is wider than the terminal"
    req_nav_handle esc

    # The main loop draws the view and takes its keys.
    out=$(keys : e n v enter down enter | req_nav_run "$PROJ/.req" 2>&1)
    assert_contains "req environments" "$out" "the loop draws the menu"
    assert_contains "environment: dev" "$out" "and the choice is made through it"
    REQ_VIEW=list; unset REQ_ENV
}

# env_menu_new_row - opens the environment menu and moves down to its last row, + new environment,
# wherever the selection starts (it starts on the environment in use).
env_menu_new_row() {
    type_keys : e n v enter
    while (( REQ_ENV_SEL < ${#REQ_ENV_CHOICES[@]} )); do req_nav_handle down; done
}

test_env_new() {
    echo "nav: + new environment"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local envdir statedir i before out
    statedir=$(req_project_state_dir "$REQ_PROJECT_ID"); envdir=$statedir/env
    rm -rf "$envdir" "$statedir/vars"; req_env_create default       # the central directory is shared with the other tests
    env_vars dev $'k=kept-by-the-test\n'
    unset REQ_ENV
    REQ_INPUT_FD=3

    type_keys : e n v enter; req_nav_handle up
    assert_eq "2" "$REQ_ENV_SEL" "up from the top selects + new environment"
    req_nav_handle enter 3<<<"new-test-env" >"$TMP/env-new-prompt.txt"
    assert_contains "Environment name (a slug, e.g. staging) - empty to cancel:" "$(<"$TMP/env-new-prompt.txt")" "Enter on it asks for the name, with an example"
    [[ -f $envdir/new-test-env/vars ]]; assert_eq "0" "$?" "the environment is created"
    assert_eq "600" "$(stat -c %a "$envdir/new-test-env/vars")" "private"
    assert_eq "new-test-env" "$REQ_ENV" "and switched to"
    assert_eq "list" "$REQ_VIEW" "going back to the list"
    assert_contains "environment: new-test-env, created in $envdir/new-test-env/vars (no variables)" "$REQ_STATUS" "the status says where the file is and that it is empty"
    type_keys : e n v enter
    assert_eq "default dev new-test-env" "${REQ_ENV_CHOICES[*]}" "the menu lists it now"
    assert_eq "2" "$REQ_ENV_SEL" "and opens on it"
    req_nav_handle esc

    # A name that exists is only switched to.
    env_menu_new_row
    assert_eq "3" "$REQ_ENV_SEL" "(the new row, with one more environment now)"
    req_nav_handle enter 3<<<"dev" >/dev/null
    assert_eq "dev" "$REQ_ENV" "the name of an existing environment switches to it"
    assert_eq "k=kept-by-the-test" "$(<"$envdir/dev/vars")" "leaving it as it is"
    assert_not_contains "created" "$REQ_STATUS" "and saying nothing about creating"
    assert_contains "environment: dev (1 variable)" "$REQ_STATUS" "with its variables loaded"
    env_menu_new_row
    req_nav_handle enter 3<<<"default" >"$TMP/env-new-prompt.txt"
    assert_contains "Environment name" "$(<"$TMP/env-new-prompt.txt")" "so does default, typed at the prompt"
    assert_eq "default" "$REQ_ENV" "which is switched to"
    assert_eq "list" "$REQ_VIEW" "going back to the list"

    # Cancelling: an empty name or the end of the input leave everything as it was.
    before=$(find "$envdir" -type f | wc -l | tr -d ' ')
    env_menu_new_row
    req_nav_handle enter 3<<<"" >"$TMP/env-new-prompt.txt"
    assert_eq "env" "$REQ_VIEW" "an empty name cancels and the menu stays"
    assert_contains "Cancelled." "$(<"$TMP/env-new-prompt.txt")" "saying so"
    assert_eq "default" "$REQ_ENV" "no environment changes"
    req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "env" "$REQ_VIEW" "so does the end of the input"
    assert_eq "$before" "$(find "$envdir" -type f | wc -l | tr -d ' ')" "and nothing is created"
    req_nav_handle esc

    # An invalid name is asked again.
    env_menu_new_row
    req_nav_handle enter 3<<<$'Not A Slug\nvalid-after-invalid-test' >"$TMP/env-new-prompt.txt" 2>&1
    assert_contains "invalid name" "$(<"$TMP/env-new-prompt.txt")" "a name that is not a slug is refused with the reason"
    assert_eq "valid-after-invalid-test" "$REQ_ENV" "and asked again until it is one"
    [[ ! -e $envdir/Not\ A\ Slug ]]; assert_eq "0" "$?" "nothing is created for the invalid one"

    # From the details of a request: back to the details.
    req_nav_handle enter                         # api
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "a request is open"
    env_menu_new_row
    req_nav_handle enter 3<<<"from-details-test" >/dev/null
    assert_eq "detail" "$REQ_VIEW" "creating from the menu goes back to the details"
    assert_eq "from-details-test" "$REQ_ENV" "with the new environment in use"
    req_nav_handle esc

    if (( EUID != 0 )); then       # root ignores the permissions
        env_menu_new_row
        chmod 500 "$envdir"
        req_nav_handle enter 3<<<"locked-test-env" >/dev/null
        chmod 700 "$envdir"
        assert_eq "from-details-test" "$REQ_ENV" "an environment that cannot be made changes nothing"
        assert_contains "cannot create $envdir/locked-test-env" "$REQ_NOTIFICATION_WARN" "and the warning names it with the absolute path"
    fi

    # The loop shows the new row and takes the name through the prompt: keys and answer are one stream.
    REQ_INPUT_FD=0; unset REQ_ENV
    out=$({ keys : e n v enter up enter; printf 'loop-test-env\n'; } | req_nav_run "$PROJ/.req" 2>&1)
    assert_contains "+ new environment" "$out" "the loop draws + new environment"
    assert_contains "Environment name (a slug, e.g. staging)" "$out" "and asks for the name"
    [[ -f $envdir/loop-test-env/vars ]]; assert_eq "0" "$?" "which creates the environment"
    assert_contains "proj @ loop-test-env" "$out" "and the header shows it"
    REQ_VIEW=list; unset REQ_ENV
}

test_command_env_load() {
    echo "nav: :env loads the whole set of variables"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local envdir statedir
    statedir=$(req_project_state_dir "$REQ_PROJECT_ID"); envdir=$statedir/env
    unset REQ_ENV
    REQ_INPUT_FD=3
    printf 'region=eu\ntoken=shared\n' >"$statedir/vars"      # the vars file of the previous layout: nothing reads it
    env_vars dev $'url=http://dev\ntoken=dev-token\n'
    env_vars prod $'url=http://prod\nextra=only-in-prod\n'

    type_keys : e n v ' ' d e v; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "dev" "$REQ_ENV" "switching to dev"
    assert_eq "2" "${#REQ_VARS[@]}" "loads the variables of the environment"
    assert_eq "dev-token" "${REQ_VARS[token]}" "with its own values"
    assert_eq "" "${REQ_VARS[region]-}" "and nothing from a vars file of the project"
    assert_contains "environment: dev (2 variables)" "$REQ_STATUS" "the status says how many were loaded"
    assert_eq "" "$REQ_NOTIFICATION_WARN" "with no warning"

    type_keys : e n v ' ' p r o d; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "2" "${#REQ_VARS[@]}" "another environment is another set: its own count"
    assert_eq "http://prod" "${REQ_VARS[url]}" "with its own values"
    assert_eq "" "${REQ_VARS[token]-}" "and none of the previous environment's"
    assert_contains "environment: prod (2 variables)" "$REQ_STATUS" "the status follows"
    type_keys : e n v ' ' d e v; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "" "${REQ_VARS[extra]-}" "switching back leaves nothing of prod"
    assert_eq "2" "${#REQ_VARS[@]}" "exactly the set of dev"

    rm -rf "$statedir/vars" "$envdir/prod"; env_vars default $'only=one\n'
    type_keys : e n v ' ' d e f a u l t; req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "environment: default (1 variable)" "$REQ_STATUS" "one variable is not plural"
    : >"$envdir/default/vars"
    type_keys : e n v ' ' d e f a u l t; req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "environment: default (no variables)" "$REQ_STATUS" "an environment with none says so"

    printf 'region=eu\n' >"$statedir/vars"
    type_keys : e n v ' ' f r e s h - t e s t; req_nav_handle enter 3<<<"" >/dev/null
    assert_contains "environment: fresh-test, created in $envdir/fresh-test/vars (no variables)" "$REQ_STATUS" "a new environment starts with none, whatever a vars file of the project has"

    # A broken file: reported when switching, the switch stands, nothing is changed.
    env_vars broken-test-env $'url=http://x\nthis line is not a pair\n'
    type_keys : e n v ' ' b r o k e n - t e s t - e n v; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "broken-test-env" "$REQ_ENV" "a broken environment file does not stop the switch"
    assert_contains "$envdir/broken-test-env/vars:2: expected key=value" "$REQ_NOTIFICATION_WARN" "the warning has the absolute path and the line"
    assert_eq "0" "${#REQ_VARS[@]}" "and no variable is loaded"
    assert_contains "environment: broken-test-env (variables not loaded)" "$REQ_STATUS" "the status says so"
    assert_eq $'url=http://x\nthis line is not a pair' "$(<"$envdir/broken-test-env/vars")" "the file is never fixed or overwritten"
    env_vars broken-test-env $'url=http://x\n'
    type_keys : e n v ' ' b r o k e n - t e s t - e n v; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "" "$REQ_NOTIFICATION_WARN" "once the file is fixed the switch is clean"
    assert_contains "environment: broken-test-env (1 variable)" "$REQ_STATUS" "and loads it"

    # A broken vars file of the project (the previous layout) is not read, so there is nothing to report.
    printf 'bad line in vars\n' >"$statedir/vars"
    type_keys : e n v ' ' d e v; req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "" "$REQ_NOTIFICATION_WARN" "a broken vars file of the project is not read, and says nothing"
    assert_eq "dev" "$REQ_ENV" "the switch happens as usual"

    # The old secrets.json is still only a warning.
    printf 'region=eu\n' >"$statedir/vars"
    mkdir -p "$REQ_CONFIG_DIR/env/dev"; printf '{}' >"$REQ_CONFIG_DIR/env/dev/secrets.json"
    type_keys : e n v ' ' d e v; req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "no longer read" "$REQ_NOTIFICATION_WARN" "the old secrets.json is warned about when switching to its environment"
    assert_contains "environment: dev (" "$REQ_STATUS" "and the variables are loaded"
    rm -rf "$REQ_CONFIG_DIR/env"
    REQ_INPUT_FD=0
    unset REQ_ENV
}

# vars_fake <dir> <name> <sh commands> - an executable fake editor, which gets the file as $1.
vars_fake() { mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" >"$1/$2"; chmod +x "$1/$2"; }

# shellcheck disable=SC2016  # the text of the fake editors and the ${host} placeholders are single-quoted on purpose
test_command_vars() {
    echo "nav: :var and :vars edit the variables of the environment in use"
    make_project
    req_nav_init "$PROJ/.req"
    req_project_activate "$PROJ" || return
    local statedir file fakes=$TMP/vars-fakes tools=$TMP/vars-tools t oldpath=$PATH before
    statedir=$(req_project_state_dir "$REQ_PROJECT_ID"); file=$(req_env_file "$REQ_PROJECT_ID" default)
    unset REQ_ENV
    REQ_INPUT_FD=3
    mkdir -p "$tools"
    # A PATH with only what the command needs, so "there is no vim" can be said for real.
    for t in sh mktemp rm cat mkdir dirname; do ln -sf "$(command -v "$t")" "$tools/$t"; done
    vars_fake "$fakes" spy 'printf "%s" "$1" >"$0.path"; cat "$1" >"$0.seen"; echo "host=https://dev.example.com" >>"$1"'

    rm -rf "$statedir/vars" "$statedir/env/default"       # the config directory is shared with the tests before this one
    [[ ! -e $file ]]; assert_eq "0" "$?" "an environment of a project from before has no folder yet"
    type_keys : v a r s; VISUAL=$fakes/spy req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "$file" "$(<"$fakes/spy.path")" ":vars runs the editor on the vars file of the environment in use, not on a copy"
    assert_eq "$(req_vars_template default)" "$(<"$fakes/spy.seen")" "which the editor finds made, with the commented template"
    assert_eq "700" "$(stat -c %a "${file%/*}")" "in a private folder, made with it"
    assert_eq "600" "$(stat -c %a "$file")" "private"
    assert_eq "https://dev.example.com" "${REQ_VARS[host]-}" "what the editor wrote is loaded when it closes"
    assert_eq "1" "${#REQ_VARS[@]}" "the comment lines of the template are not variables"
    assert_contains "environment: default (1 variable)" "$REQ_STATUS" "the status says how many variables there are"
    assert_eq "" "$REQ_NOTIFICATION_WARN" "with no warning"
    req_subst '${host}/users' default; assert_eq "https://dev.example.com/users" "$REQ_SUBST_OUT" "and a request uses it"

    # The alias, and a file that already has content: the editor sees it as it is.
    printf 'token=abc\n' >"$file"
    type_keys : v a r; VISUAL=$fakes/spy req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "token=abc" "$(<"$fakes/spy.seen")" ":var is the same command, and a file with content is not touched before the editor"
    assert_eq "2" "${#REQ_VARS[@]}" "its variables are loaded with the new one"
    # Another environment in use: :vars opens the file of that one and leaves the first alone.
    env_vars dev $'only=env-file\nsecond=2\n'
    before=$(<"$file")
    REQ_ENV=dev
    type_keys : v a r s; VISUAL=$fakes/spy req_nav_handle enter 3</dev/null >/dev/null
    assert_eq "$(req_env_file "$REQ_PROJECT_ID" dev)" "$(<"$fakes/spy.path")" "with another environment in use :vars opens that environment's file"
    assert_eq $'only=env-file\nsecond=2' "$(<"$fakes/spy.seen")" "which the editor finds as it is"
    assert_eq "$before" "$(<"$file")" "and the file of the first environment is left alone"
    assert_contains "environment: dev (3 variables)" "$REQ_STATUS" "the variables loaded are those of the environment in use (its two plus the line the editor added)"
    unset REQ_ENV

    # The order of the editors: $VISUAL, $EDITOR, vim, nano, then the message.
    vars_fake "$tools" vim 'echo "from-vim" >>"$1"'
    vars_fake "$tools" nano 'echo "from-nano" >>"$1"'
    : >"$file"
    PATH=$tools; type_keys : v a r s; VISUAL='' EDITOR='' req_nav_handle enter 3</dev/null >/dev/null; PATH=$oldpath
    assert_eq "from-vim" "$(<"$file")" "with no VISUAL or EDITOR vim is used, and wins over nano"
    rm -f "$tools/vim"; : >"$file"
    PATH=$tools; type_keys : v a r s; VISUAL='' EDITOR='' req_nav_handle enter 3</dev/null >/dev/null; PATH=$oldpath
    assert_eq "from-nano" "$(<"$file")" "nano is used when there is no vim"
    vars_fake "$tools" vim 'echo "from-vim" >>"$1"'; : >"$file"
    vars_fake "$fakes" mine 'echo "from-my-editor" >>"$1"'
    PATH=$tools; type_keys : v a r s; VISUAL='' EDITOR=$fakes/mine req_nav_handle enter 3</dev/null >/dev/null; PATH=$oldpath
    assert_eq "from-my-editor" "$(<"$file")" "the editor of the user (EDITOR) wins over vim and nano"
    PATH=$tools; type_keys : v a r s; VISUAL=$fakes/spy EDITOR=$fakes/mine req_nav_handle enter 3</dev/null >/dev/null; PATH=$oldpath
    assert_eq "$file" "$(<"$fakes/spy.path")" "and VISUAL wins over EDITOR"

    # No editor at all: the file is made anyway and a message says where it is and how to write it.
    rm -f "$tools/vim" "$tools/nano" "$file"; REQ_STATUS=""
    PATH=$tools; type_keys : v a r s; VISUAL='' EDITOR='' req_nav_handle enter 3<<<"" >"$TMP/vars-howto.txt"; PATH=$oldpath
    assert_contains "No editor found (tried \$VISUAL, \$EDITOR, vim and nano)." "$(<"$TMP/vars-howto.txt")" "with no editor it says so"
    assert_contains "The variables of environment default are in:" "$(<"$TMP/vars-howto.txt")" "names the environment the file belongs to"
    assert_contains $'\n  '"$file"$'\n' "$(<"$TMP/vars-howto.txt")" "gives the whole path on a line of its own"
    assert_contains $'\n  host=https://api.example.com\n' "$(<"$TMP/vars-howto.txt")" "shows how a variable is written"
    assert_contains 'use it in a request as ${host}' "$(<"$TMP/vars-howto.txt")" "and used"
    assert_contains "Press Enter to go back" "$(<"$TMP/vars-howto.txt")" "and waits for Enter"
    [[ -f $file ]]; assert_eq "0" "$?" "the file exists, ready for the user's lines"
    assert_eq "600" "$(stat -c %a "$file")" "private"
    assert_eq "" "$REQ_STATUS" "nothing is loaded again, since nothing was edited"
    assert_eq "" "$REQ_NOTIFICATION_WARN" "and it is no warning"

    # A bad line is reported at once, with its path and line, and never fixed.
    vars_fake "$fakes" breaker 'printf "ok=1\nthis line is not a pair\n" >"$1"'
    type_keys : v a r s; VISUAL=$fakes/breaker req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "$file:2: expected key=value" "$REQ_NOTIFICATION_WARN" "a bad line is a warning with the absolute path and the line"
    assert_contains "environment: default (variables not loaded)" "$REQ_STATUS" "and the status says nothing was loaded"
    assert_eq $'ok=1\nthis line is not a pair' "$(<"$file")" "the file is left as the user wrote it"

    # An editor that fails.
    vars_fake "$fakes" failer 'exit 3'
    REQ_STATUS=""
    type_keys : v a r s; VISUAL=$fakes/failer req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "the editor failed; $file is as the editor left it" "$REQ_NOTIFICATION_WARN" "an editor that fails is a warning with the path"
    assert_eq "" "$REQ_STATUS" "and the variables are not reported again"

    # Wrong use.
    rm -f "$fakes/spy.path"
    type_keys : v a r s ' ' d e v; VISUAL=$fakes/spy req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "usage: :vars" "$REQ_NOTIFICATION_WARN" "an argument is a usage warning"
    assert_contains "the environment in use" "$REQ_NOTIFICATION_WARN" "that says which variables it opens"
    [[ ! -e $fakes/spy.path ]]; assert_eq "0" "$?" "and no editor is run"
    REQ_PROJECT_ID=""
    type_keys : v a r s; VISUAL=$fakes/spy req_nav_handle enter 3</dev/null >/dev/null
    assert_contains "is not available, so there are no variables to edit" "$REQ_NOTIFICATION_WARN" "with no project state there is nothing to edit"
    [[ ! -e $fakes/spy.path ]]; assert_eq "0" "$?" "and no editor is run"
    assert_contains ":vars" "$(printf '%s\n' "${REQ_HELP_ROWS[@]}")" "the help lists :vars"
    assert_contains "alias :var" "$(printf '%s\n' "${REQ_HELP_ROWS[@]}")" "and its alias"
    REQ_INPUT_FD=0
    unset REQ_ENV
}

test_command_log_verbose() {
    echo "nav: :log and :v"
    make_project
    req_nav_init "$PROJ/.req"
    local out lf
    REQ_PROJECT_ID=""; REQ_LOG_SESSION=""; REQ_CONFIG=(); REQ_VERBOSE=0

    type_keys : l o g enter
    assert_contains "no project is open" "$REQ_NOTIFICATION_WARN" ":log without a project says why"
    assert_eq "" "$REQ_LOG_SESSION" "and changes nothing"
    req_project_activate "$PROJ" || return
    lf=$(req_log_file)
    type_keys : l o g enter
    assert_eq "yes" "$REQ_LOG_SESSION" ":log turns the log on when the setting is off"
    assert_contains "log on for this session: $lf" "$REQ_STATUS" "and names the file"
    req_log_enabled; assert_eq "0" "$?" "the log is in effect"
    type_keys : l o g enter
    assert_eq "no" "$REQ_LOG_SESSION" "the next :log turns it off"
    assert_contains "log off for this session" "$REQ_STATUS" "and says so"
    req_log_enabled; assert_eq "1" "$?" "the log is off"
    type_keys : l o g ' ' y e s enter
    assert_eq "yes" "$REQ_LOG_SESSION" ":log yes sets it on"
    type_keys : l o g ' ' y e s enter
    assert_eq "yes" "$REQ_LOG_SESSION" "even when it already is"
    type_keys : l o g ' ' o f f enter
    assert_eq "no" "$REQ_LOG_SESSION" "off is accepted as no"
    type_keys : l o g ' ' m a y b e enter
    assert_contains "usage: :log [yes|no]" "$REQ_NOTIFICATION_WARN" "another argument shows the usage"
    assert_eq "no" "$REQ_LOG_SESSION" "without a change"
    REQ_CONFIG=([log]=yes); REQ_LOG_SESSION=""
    type_keys : l o g enter
    assert_eq "no" "$REQ_LOG_SESSION" "with log=yes in the setting the toggle turns it off"
    req_config_load 2>/dev/null; req_log_enabled; assert_eq "1" "$?" "and a reload of the settings keeps the session's choice"
    assert_eq "" "$(req_kv_get "$(req_config_file)" log)" "the setting itself is never written"

    type_keys : v enter
    assert_eq "1" "$REQ_VERBOSE" ":v turns the verbose mode on"
    assert_contains "verbose on for this session" "$REQ_STATUS" "and says so"
    type_keys : v enter
    assert_eq "0" "$REQ_VERBOSE" "the next :v turns it off"
    type_keys : v ' ' n o enter
    assert_eq "0" "$REQ_VERBOSE" ":v no keeps it off"
    type_keys : v ' ' o n enter
    assert_eq "1" "$REQ_VERBOSE" ":v on turns it on"
    type_keys : v e r b o s e enter
    assert_eq "0" "$REQ_VERBOSE" ":verbose is an alias"
    type_keys : v ' ' x enter
    assert_contains "usage: :v [yes|no]" "$REQ_NOTIFICATION_WARN" "a wrong argument shows the usage"
    out=$(printf '%s\n' "${REQ_HELP_ROWS[@]}")
    assert_contains ":log" "$out" "the help lists :log"
    assert_contains ":v [yes|no]" "$out" "and :v"
    assert_contains "req log|follow the project's log" "$out" "the help lists req log, outside the menu"
    REQ_PROJECT_ID=""; REQ_LOG_SESSION=""; REQ_CONFIG=(); REQ_VERBOSE=0
}

test_command_remove() {
    echo "nav: :rm on a request"
    make_project
    req_nav_init "$PROJ/.req"
    REQ_INPUT_FD=3
    local i out

    req_nav_handle enter                         # api
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == create ]] && REQ_SEL=$i; done
    type_keys : r m
    req_nav_handle enter 3<<<"n" >/dev/null
    [[ -f $PROJ/api/create.post.json ]]; assert_eq "0" "$?" "answering n keeps the request"
    assert_eq "create" "${REQ_ITEM_LABEL[REQ_SEL]}" "and the selection stays"

    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    [[ ! -e $PROJ/api/create.post.json ]]; assert_eq "0" "$?" ":rm removes the selected request after y"
    assert_contains "removed create.post.json" "$REQ_STATUS" "status mentions it"
    assert_eq "list-users" "${REQ_ITEM_LABEL[REQ_SEL]}" "the selection moves to the neighbour"
    assert_eq "list" "$REQ_VIEW" "back on the list"

    # From the details screen, and for an invalid request.
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == list-users ]] && REQ_SEL=$i; done
    req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "opens the details"
    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    [[ ! -e $PROJ/api/list-users.get.json ]]; assert_eq "0" "$?" ":rm works on the details screen"
    assert_eq "list" "$REQ_VIEW" "and returns to the list"

    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i; done
    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    [[ ! -e $PROJ/api/broken.get.json ]]; assert_eq "0" "$?" ":rm removes an invalid request"

    # The last item: the selection falls back to the previous one.
    REQ_SEL=$(( ${#REQ_ITEM_KIND[@]} - 1 ))
    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    assert_eq "$(( ${#REQ_ITEM_KIND[@]} - 1 ))" "$REQ_SEL" "removing the last item selects the new last one"

    # In an empty directory there is nothing to remove.
    mkdir -p "$PROJ/auth/empty"
    REQ_INPUT_FD=0
    req_nav_handle esc; REQ_SEL=1; req_nav_handle enter       # auth (no requests)
    REQ_INPUT_FD=3
    REQ_SEL=0; req_nav_handle enter                           # auth/empty
    type_keys : r m; req_nav_handle enter >/dev/null
    assert_contains "select a request or a directory" "$REQ_NOTIFICATION_WARN" ":rm with nothing selected explains itself"
    REQ_INPUT_FD=0
}

test_command_remove_dir() {
    echo "nav: :rm on a directory"
    make_project
    req_nav_init "$PROJ/.req"
    REQ_INPUT_FD=3

    REQ_SEL=0
    type_keys : r m
    req_nav_handle enter 3<<<"n" >/dev/null
    [[ -d $PROJ/api/v2 ]]; assert_eq "0" "$?" "answering n keeps the directory"

    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    [[ ! -e $PROJ/api ]]; assert_eq "0" "$?" ":rm removes the directory under the cursor after y"
    assert_eq "auth" "${REQ_ITEM_LABEL[*]}" "the root list is refreshed"
    assert_eq "0" "$REQ_SEL" "with a valid selection"
    assert_contains "removed api" "$REQ_STATUS" "status mentions it"

    type_keys : r m
    req_nav_handle enter 3<<<"y" >/dev/null
    assert_eq "0" "${#REQ_ITEM_KIND[@]}" "the last directory can go too"
    [[ -f $PROJ/.req ]]; assert_eq "0" "$?" "and the project file stays"
    REQ_INPUT_FD=0
}

test_dynamic_root() {
    echo "nav: dynamic root (workspace)"
    local p=$TMP/dyn out
    rm -rf "$p"; mkdir -p "$p/zeta" "$p/alpha/inner" "$p/.hidden"
    printf 'old-entry\nzeta/\n' >"$p/.req"       # old one-directory-per-line entries
    req_request_write "$p" at-root GET http://x/r >/dev/null
    printf 'not a request' >"$p/notes.txt"

    req_nav_init "$p/.req"
    assert_eq "alpha zeta at-root" "${REQ_ITEM_LABEL[*]}" "the root lists every directory, then the requests"
    assert_eq "d d r" "${REQ_ITEM_KIND[*]}" "with their types"
    assert_eq "  GET" "${REQ_ITEM_METHOD[2]:+  }${REQ_ITEM_METHOD[2]}" "a request at the root has its method"
    assert_eq "$p" "$REQ_NAV_ROOT" "the root is the workspace (here the project folder)"
    screen list; assert_contains "req /" "$OUT" "the header shows the root"
    assert_contains "dir    alpha/" "$OUT" "directories show as dir"
    assert_contains "GET    at-root" "$OUT" "requests show their method"
    [[ $OUT != *notes* && $OUT != *hidden* && $OUT != *old-entry* ]]
    assert_eq "0" "$?" "other files, hidden directories and old .req entries do not show"
    assert_eq "alpha zeta at-root" "${REQ_ITEM_LABEL[*]}" "and the .req entries do not decide what is listed"

    # A directory created by hand shows up on the next load, without touching the .req.
    mkdir "$p/beta"
    req_nav_refresh "$p/beta"
    assert_eq "alpha beta zeta at-root" "${REQ_ITEM_LABEL[*]}" "a new directory appears after a refresh"
    assert_eq "beta" "${REQ_ITEM_LABEL[REQ_SEL]}" "and can be selected"
    assert_eq $'old-entry\nzeta/' "$(<"$p/.req")" "the .req is never rewritten"

    # Navigation stays relative to the root; Esc at the root stays there.
    REQ_SEL=0; req_nav_handle enter
    assert_eq "/alpha" "$(req_nav_crumb)" "the breadcrumb is relative to the root"
    req_nav_handle esc; req_nav_handle esc
    assert_eq "" "$REQ_CUR_DIR" "Esc goes back to the root and stops there"
    REQ_SEL=3; req_nav_handle enter
    assert_eq "detail" "$REQ_VIEW" "Enter on a request at the root opens its details"
    req_nav_handle esc

    # workspace points at a subdirectory: only that directory is seen.
    rm -rf "$p"; mkdir -p "$p/content/api" "$p/code/src"
    printf 'workspace=content\n' >"$p/.req"
    req_request_write "$p/content/api" ping GET http://x >/dev/null
    req_nav_init "$p/.req"
    assert_eq "api" "${REQ_ITEM_LABEL[*]}" "only the workspace is listed"
    assert_eq "$p/content" "$REQ_NAV_ROOT" "the root is the workspace"
    req_nav_handle enter
    assert_eq "/api" "$(req_nav_crumb)" "paths are relative to the workspace, not to the .req"
    assert_eq "ping" "${REQ_ITEM_LABEL[*]}" "and its requests are listed"
    req_nav_handle esc
    assert_eq "api" "${REQ_ITEM_LABEL[*]}" "back at the workspace root"

    # :nd at the root creates the directory inside the workspace, not next to the .req.
    REQ_INPUT_FD=3
    type_keys : n d
    req_nav_handle enter 3<<<"newdir" >/dev/null
    REQ_INPUT_FD=0
    [[ -d $p/content/newdir && ! -e $p/newdir ]]; assert_eq "0" "$?" ":nd at the root creates inside the workspace"
    assert_eq "api newdir" "${REQ_ITEM_LABEL[*]}" "and it is listed"
    assert_eq "workspace=content" "$(<"$p/.req")" "without touching the .req"

    # :n at the root creates the request in the workspace and lists it.
    REQ_INPUT_FD=3
    type_keys : n
    req_nav_handle enter 3<<<$'root-req\nGET\nhttp://x/r\nn\n' >"$TMP/new.out" 2>&1
    out=$(<"$TMP/new.out")
    REQ_INPUT_FD=0
    assert_contains "New request in /" "$out" ":n at the root says where it creates the request"
    [[ -f $p/content/root-req.get.json && ! -e $p/root-req.get.json ]]; assert_eq "0" "$?" ":n at the root creates the request inside the workspace"
    assert_eq "api newdir root-req" "${REQ_ITEM_LABEL[*]}" "the request is listed after the directories"
    assert_eq "d d r" "${REQ_ITEM_KIND[*]}" "with its type"

    # An invalid workspace stops the menu with the reason.
    printf 'workspace=../elsewhere\n' >"$p/.req"
    out=$(req_nav_init "$p/.req" 2>&1); assert_eq "1" "$?" "an invalid workspace refuses to open"
    assert_contains "leaves the project folder" "$out" "and says why"
    printf 'workspace=nope\n' >"$p/.req"
    out=$(req_nav_run "$p/.req" </dev/null 2>&1); assert_eq "1" "$?" "the main loop refuses it too"
    assert_contains "does not exist" "$out" "with the reason"
}

test_command_flow() {
    echo "nav: command flow through the main loop"
    local p=$TMP/flow out
    mkdir -p "$p/svc"; printf 'svc\n' >"$p/.req"
    # Keys and the wizard's answers arrive on the same stream, as they do on a terminal.
    out=$({ keys enter; keys : n enter; printf 'ping\nGET\nhttp://x/p\nn\n'; keys : q enter; } | req_nav_run "$p/.req" 2>&1)
    assert_contains "Created $p/svc/ping.get.json" "$out" "the wizard ran inside the loop"
    assert_contains "created ping.get.json" "$out" "the status appeared on the next screen"
    [[ -f $p/svc/ping.get.json ]]; assert_eq "0" "$?" "the request exists"
    assert_eq "0" "$(req_request_check "$p/svc/ping.get.json" 2>/dev/null; echo $?)" "and is valid"
    out=$({ keys : q enter; keys enter; } | req_nav_run "$p/.req" 2>&1)
    [[ $out != *"req /svc"* ]]; assert_eq "0" "$?" ":q ends the loop (a later Enter is never handled)"
}

test_review_flow() {
    echo "nav: Review 1 commands through the main loop"
    local p=$TMP/rev out
    mkdir -p "$p/svc"; printf '# project\nsvc\n' >"$p/.req"
    req_request_write "$p/svc" ping GET http://x/ping >/dev/null
    # One stream of keys and answers, as on a terminal: help, rename, copy, remove the
    # copy, then create and remove a request inside the renamed directory, quit. No bare
    # Esc is used: it depends on timing and this test must not.
    out=$({
        keys : h enter; keys x
        keys : e d enter; printf 'gateway\n'
        keys : c p enter; printf '\n'
        keys : r m enter; printf 'y\n'
        keys enter; keys : n enter; printf 'extra\nGET\nhttp://x/e\nn\n'
        keys : r m enter; printf 'y\n'
        keys : q enter
    } | req_nav_run "$p/.req" 2>&1)
    assert_contains "any key  closes this help" "$out" ":h opened the help"
    assert_contains "renamed to gateway" "$out" ":ed ran inside the loop"
    assert_contains "copied to gateway-copy" "$out" ":cp ran inside the loop"
    assert_contains "removed extra.get.json" "$out" ":rm removed a request"
    assert_contains "removed gateway-copy" "$out" ":rm removed a directory"
    [[ -f $p/gateway/ping.get.json && ! -e $p/svc && ! -e $p/gateway-copy ]]
    assert_eq "0" "$?" "the filesystem ends as expected"
}

test_workspace_flow() {
    echo "nav: workspace flow through the main loop"
    local p=$TMP/ws out before
    mkdir -p "$p/requests" "$p/other"
    printf '# project\nworkspace=requests\n' >"$p/.req"
    printf 'keep\n' >"$p/other/notes.txt"; printf 'keep\n' >"$p/readme.txt"
    before=$(<"$p/.req")
    # One stream of keys and answers: create a directory and a request at the root,
    # rename the directory, copy and remove the copy, then work inside the directory:
    # create a request, copy it, remove the copy. Quit.
    out=$({
        keys : n d ' ' a p i enter
        keys : n enter; printf 'top\nGET\nhttp://x/t\nn\n'
        keys up; keys : e d ' ' g a t e w a y enter
        keys : c p enter; printf '\n'
        keys : r m enter; printf 'y\n'
        keys up; keys enter
        keys : n enter; printf 'inner\nGET\nhttp://x/i\nn\n'
        keys : c p ' ' i n n e r 2 enter
        keys : r m enter; printf 'y\n'
        keys : q enter
    } | req_nav_run "$p/.req" 2>&1)
    assert_contains "renamed to gateway" "$out" ":ed renamed the directory"
    assert_contains "copied to gateway-copy" "$out" ":cp copied the directory"
    assert_contains "removed gateway-copy" "$out" ":rm removed the copy"
    assert_contains "copied to inner2.get.json" "$out" ":cp copied a request"
    assert_contains "removed inner2.get.json" "$out" ":rm removed a request"
    [[ -f $p/requests/top.get.json && -f $p/requests/gateway/inner.get.json ]]
    assert_eq "0" "$?" "requests live in the workspace"
    [[ ! -e $p/requests/api && ! -e $p/requests/gateway-copy && ! -e $p/requests/gateway/inner2.get.json ]]
    assert_eq "0" "$?" "the renamed and removed items are gone"
    assert_eq "$before" "$(<"$p/.req")" "the .req was never rewritten"
    assert_eq "keep keep" "$(<"$p/other/notes.txt") $(<"$p/readme.txt")" "files outside the workspace are untouched"
    assert_eq "" "$(find "$p" -mindepth 1 -maxdepth 1 ! -name requests ! -name other ! -name readme.txt ! -name .req)" "nothing was created outside the workspace"
}

test_cursor_saved() {
    echo "nav: the cursor is saved on exit"
    local f out
    make_project
    req_project_activate "$PROJ" || return
    f=$(req_cursor_file "$REQ_PROJECT_ID")

    { keys enter; keys down; keys : q enter; } | req_nav_run "$PROJ/.req" >/dev/null 2>&1
    assert_eq $'dir=api\nitem=api/broken.get.json' "$(<"$f")" ":q saves the directory and the selected item"
    assert_eq "" "$REQ_EXIT_HOOK" "and the exit hook is cleared"

    rm -f "$f"
    { keys down; } | req_nav_run "$PROJ/.req" >/dev/null 2>&1
    assert_eq $'dir=\nitem=auth' "$(<"$f")" "the end of the input saves too (the root, second item)"

    rm -f "$f"
    { keys down q up; } | req_nav_run "$PROJ/.req" >/dev/null 2>&1
    assert_eq $'dir=\nitem=auth' "$(<"$f")" "q at the root ends the menu and saves the cursor (the key after it is not read)"

    rm -f "$f"
    ( req_setup_traps; req_nav_init "$PROJ/.req"; REQ_EXIT_HOOK=req_nav_save_cursor; REQ_SEL=1
      kill -TERM "$BASHPID" ) 2>/dev/null
    assert_eq $'dir=\nitem=auth' "$(<"$f")" "a signal saves it as well"

    rm -f "$f"; REQ_PROJECT_ID=""
    { keys : q enter; } | req_nav_run "$PROJ/.req" >/dev/null 2>&1
    [[ ! -e $f ]]; assert_eq "0" "$?" "without a registered project nothing is written"

    REQ_PROJECT_ID=ghost
    out=$({ keys : q enter; } | req_nav_run "$PROJ/.req" 2>&1); assert_eq "0" "$?" "a project folder that cannot be written does not stop the menu"
    REQ_PROJECT_ID=""
}

test_cursor_restore() {
    echo "nav: the cursor is restored on open"
    local f i
    make_project
    req_project_activate "$PROJ" || return
    f=$(req_cursor_file "$REQ_PROJECT_ID")
    mkdir -p "$PROJ/api/v2/deep"
    req_request_write "$PROJ/api/v2" ping GET http://x/p >/dev/null

    req_cursor_save "$REQ_PROJECT_ID" "api/v2" "api/v2/ping.get.json"
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "$PROJ/api/v2" "$REQ_CUR_DIR" "the directory is reopened"
    assert_eq "ping" "${REQ_ITEM_LABEL[REQ_SEL]}" "and the item is selected"
    assert_eq "list" "$REQ_VIEW" "on the list"
    assert_eq "2" "${#REQ_STACK_DIR[@]}" "the Esc stack has one level per directory"
    req_nav_back
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "Esc goes up to the parent"
    assert_eq "v2" "${REQ_ITEM_LABEL[REQ_SEL]}" "with the directory just left selected"
    req_nav_back
    assert_eq "" "$REQ_CUR_DIR" "and up to the root"
    assert_eq "api" "${REQ_ITEM_LABEL[REQ_SEL]}" "with its directory selected"

    req_cursor_save "$REQ_PROJECT_ID" "api/gone/deeper" "api/gone/deeper/x.get.json"
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "$PROJ/api" "$REQ_CUR_DIR" "a missing directory leads to its nearest existing ancestor"
    assert_eq "0" "$REQ_SEL" "with the first item selected"

    req_cursor_save "$REQ_PROJECT_ID" "api/v2" "api/v2/nope.get.json"
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "$PROJ/api/v2" "$REQ_CUR_DIR" "a missing item keeps the directory"
    assert_eq "0" "$REQ_SEL" "and selects the first item"

    req_cursor_save "$REQ_PROJECT_ID" "" "auth"
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "" "$REQ_CUR_DIR" "an empty directory is the root"
    assert_eq "auth" "${REQ_ITEM_LABEL[REQ_SEL]}" "with the saved item selected"

    rm -f "$f"
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor; assert_eq "0" "$?" "a missing file is not an error"
    assert_eq "" "$REQ_CUR_DIR" "and stays at the root"
    for bad in $'dir=../outside\nitem=' $'dir=/etc\nitem=' $'dir=api//v2\nitem=' $'dir=api/\nitem=' $'dir=./api\nitem=' $'item=../x' 'garbage' ''; do
        printf '%s\n' "$bad" >"$f"
        req_nav_init "$PROJ/.req"; req_nav_restore_cursor
        assert_eq "|0" "$REQ_CUR_DIR|$REQ_SEL" "an invalid file leaves the root: $(printf %q "$bad")"
    done

    rm -f "$f"; req_cursor_save "$REQ_PROJECT_ID" "api" "api/v2"
    REQ_CONFIG=([restore_cursor]=no)
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "" "$REQ_CUR_DIR" "restore_cursor=no keeps the root"
    REQ_CONFIG=()
    REQ_PROJECT_ID=""
    req_nav_init "$PROJ/.req"; req_nav_restore_cursor
    assert_eq "" "$REQ_CUR_DIR" "without a project nothing is restored"
    REQ_PROJECT_ID=$(req_project_find_id "$PROJ")

    # Through the main loop: reopen where it was left, then leave again at the same place.
    req_cursor_save "$REQ_PROJECT_ID" "api" "api/v2"
    { keys : q enter; } | req_nav_run "$PROJ/.req" >/dev/null 2>&1
    assert_eq $'dir=api\nitem=api/v2' "$(<"$f")" "the loop reopens at the cursor and saves the same place"
}

test_review2_flow() {
    echo "nav: Review 2 through the main loop"
    local p=$TMP/rev2 out id cfg=$REQ_CONFIG_DIR
    REQ_CONFIG_DIR=$TMP/rev2-cfg; REQ_CONFIG=()
    mkdir -p "$p/api/v2" "$p/auth"
    printf '# project\nworkspace=.\n' >"$p/.req"
    req_request_write "$p/api" ping GET http://x/ping >/dev/null
    req_request_write "$p/api" status GET http://x/status >/dev/null

    # Opening a project registers it in the central directory and makes it current.
    req_project_activate "$p"; id=$REQ_PROJECT_ID
    assert_eq "$id" "$(req_current_get)" "the opened project is the current one"
    assert_eq "$p" "$(req_kv_get "$(req_project_state_dir "$id" project)" path)" "and is registered with its path"

    # First session: go into api, select the second request, change a setting, quit.
    out=$({ keys enter; keys down down; keys : c o n f i g enter; keys x
            keys : c o n f i g ' ' - g ' ' t i m e _ s t a t s = n o enter; keys : q enter
          } | req_nav_run "$p/.req" 2>&1)
    assert_contains "time_stats" "$out" ":config listed the settings"
    assert_contains "time_stats=no saved" "$out" "and :config key=value saved one"
    assert_eq "no" "$(req_kv_get "$REQ_CONFIG_DIR/config" time_stats)" "in the global file"
    assert_eq $'dir=api\nitem=api/status.get.json' "$(<"$(req_cursor_file "$id")")" ":q saved the cursor"

    # Second session (a new start): the setting is read and the menu reopens in place.
    req_config_load; REQ_PROJECT_ID=""; req_project_activate "$p"
    assert_eq "$id" "$REQ_PROJECT_ID" "reopening finds the same project"
    assert_eq "no" "$(req_config_get time_stats)" "the setting is still in effect"
    out=$({ keys : q enter; } | req_nav_run "$p/.req" 2>&1)
    assert_contains "req /api" "$out" "the menu reopens in the saved directory"
    assert_contains "req /api (3/3)" "$out" "with the third item (the saved request) selected"
    assert_eq $'dir=api\nitem=api/status.get.json' "$(<"$(req_cursor_file "$id")")" "and leaving again keeps the place"

    REQ_CONFIG_DIR=$cfg; REQ_CONFIG=()
}

test_start_init() {
    echo "nav: init prompt"
    local d=$TMP/fresh out
    mkdir -p "$d"
    # req_nav_start needs a terminal; here we check the building blocks it uses.
    req_project_find "$d" >/dev/null; assert_eq "1" "$?" "a fresh directory has no .req"
    out=$(printf 'y\n' | req_confirm "Initialize a req project here?")
    assert_contains "Initialize a req project here? [Y/n]" "$out" "prompt text"
    req_project_init "$d" && req_nav_init "$d/.req"
    assert_eq "0" "${#REQ_ITEM_LABEL[@]}" "a freshly initialized project has nothing to list"
    screen list; assert_contains "(empty)" "$OUT" "so the root starts empty"
}

test_keys
test_navigation
test_key_q
test_list_screen
test_selection_highlight
test_detail_screen
test_detail_params
test_detail_raw_data
test_detail_invalid
test_detail_bad_address
test_invalid_many_problems
test_invalid_long_path
test_truncate_scroll
test_empty_project
test_command_mode
test_command_actions
test_help
test_key_h
test_clear_screen
test_view_key
test_dynamic_root
test_command_rename_dir
test_command_copy
test_command_config
test_command_env
test_env_menu
test_env_new
test_command_env_load
test_command_vars
test_command_log_verbose
test_command_remove
test_command_remove_dir
test_command_flow
test_review_flow
test_workspace_flow
test_cursor_saved
test_cursor_restore
test_review2_flow
test_start_init
test_notification_bars
test_root_notice
test_config_warnings_in_the_bar
test_run_failures_in_the_bar
test_legacy_layout_in_the_bar
test_status_in_the_bar
test_logo_row
test_end_to_end
test_summary
