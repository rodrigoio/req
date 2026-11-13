#!/usr/bin/env bash
# Tests for lib/nav.sh. Outside a terminal there are no colors and nothing is erased.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"
source "$ROOT/lib/http.sh"
source "$ROOT/lib/nav.sh"
source "$ROOT/lib/wizard.sh"
source "$ROOT/lib/cmd.sh"

# shellcheck disable=SC2031  # lib/store.sh sets LC_ALL in a subshell on purpose
export LC_ALL=C COLUMNS=60 LINES=24
TMP=$(mktemp -d)
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
    printf '{"name":"broken","method":"GET","url":"http://x","timeout":5}\n' >"$p/api/broken.get.json"
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

test_list_screen() {
    echo "nav: list screen"
    make_project
    req_nav_init "$PROJ/.req"
    local out
    screen list; out=$OUT
    assert_contains "req /" "$out" "header at the root"
    assert_contains "(1/2)" "$out" "position in the list"
    assert_contains "> dir    api/" "$out" "selected directory with a marker"
    assert_contains "  dir    auth/" "$out" "directory without a marker"
    [[ $out != *"Esc back"* ]]; assert_eq "0" "$?" "no Esc hint at the root"

    req_nav_handle enter
    screen list; out=$OUT
    assert_contains "Esc back" "$out" "Esc hint away from the root"
    assert_contains "> dir    v2/" "$out" "subdirectory highlighted"
    assert_contains "  POST   create" "$out" "request with a method"
    assert_contains "  GET    list-users" "$out" "request GET"
    assert_contains "  DELETE remove" "$out" "request DELETE"
    assert_eq "7" "${#REQ_SCREEN_LINES[@]}" "lines: header, 5 items and footer"
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
    assert_contains "Enter run" "$out" "run hint"

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
    assert_contains 'unknown field "timeout"' "$out" "shows the reason"
    assert_eq "$PROJ/api/broken.get.json" "${REQ_SCREEN_LINES[1]}" "the absolute path is on its own line, ready to copy"
    assert_eq "0" "$REQ_SCREEN_EXTRA" "a path that fits adds no extra rows"
    assert_eq "" "$(req_nav_handle enter 2>&1)" "Enter does not run an invalid request"
    assert_eq "detail" "$REQ_VIEW" "stays on the details"
    req_nav_handle esc; assert_eq "list" "$REQ_VIEW" "Esc goes back"
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
    assert_eq "$path" "${REQ_SCREEN_LINES[1]}" "the path is never truncated, even on a narrow terminal"
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
    assert_eq "3" "$(grep -c '^Enter run' <<<"$out")" "details redrawn after each result"
}

# type <chars...> - sends each character to the handler, as the main loop would.
type_keys() { local c; for c in "$@"; do req_nav_handle "$c"; done; }

test_command_mode() {
    echo "nav: command mode"
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
    req_nav_build_list; req_nav_overlay
    assert_eq ":x_" "${REQ_SCREEN_LINES[-1]}" "the prompt replaces the hint line"
    req_nav_handle esc

    type_keys : z z enter
    assert_contains "unknown command :zz" "$REQ_STATUS" "an unknown command is reported"
    req_nav_overlay; assert_eq "" "$REQ_STATUS" "the status is shown once"
    type_keys : enter
    assert_eq "0" "$REQ_CMD_ACTIVE" "an empty command just leaves command mode"
    type_keys : q enter
    assert_eq "1" "$REQ_QUIT" ":q quits"
    REQ_QUIT=0

    type_keys : e enter
    assert_contains "select a request first" "$REQ_STATUS" ":e on a directory explains itself"
    type_keys : d enter
    assert_contains "select a request first" "$REQ_STATUS" ":d on a directory explains itself"
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

test_help() {
    echo "nav: help screen"
    make_project
    req_nav_init "$PROJ/.req"
    local out row i
    type_keys : h enter
    assert_eq "help" "$REQ_VIEW" ":h opens the help"
    REQ_NAV_DIRTY=1; req_nav_build_help; out=$(printf '%s\n' "${REQ_SCREEN_LINES[@]}")
    assert_contains "Enter  " "$out" "lists Enter"
    assert_contains ":nd [name]" "$out" "lists a command with its argument"
    assert_contains "Press any key" "$out" "says how to go back"
    for row in ":n" ":nd" ":e" ":d" ":h" ":q"; do
        assert_contains "$row" "$out" "every command is listed: $row"
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
    req_nav_build_list; assert_contains ":h help" "${REQ_SCREEN_LINES[-1]}" "list footer points to :h"
    REQ_VIEW=detail; req_nav_build_detail
    assert_contains ":h help" "${REQ_SCREEN_LINES[-1]}" "details footer points to :h"
    REQ_VIEW=list
    type_keys : z enter
    assert_contains ":h" "$REQ_STATUS" "unknown command points to :h"
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
    assert_contains "edit a request with :e" "$REQ_STATUS" ":ed on a request points to :e"
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
    assert_contains "unknown command :c" "$REQ_STATUS" ":c no longer exists"
    for i in "${!REQ_ITEM_LABEL[@]}"; do [[ ${REQ_ITEM_LABEL[i]} == broken ]] && REQ_SEL=$i; done
    type_keys : c p
    req_nav_handle enter 3<<<"x" >/dev/null 2>&1
    [[ ! -e $PROJ/api/x.get.json ]]; assert_eq "0" "$?" "an invalid request is not copied"
    REQ_INPUT_FD=0
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
    assert_contains "select a request or a directory" "$REQ_STATUS" ":rm with nothing selected explains itself"
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
    assert_contains "Press any key to go back" "$out" ":h opened the help"
    assert_contains "renamed to gateway" "$out" ":ed ran inside the loop"
    assert_contains "copied to gateway-copy" "$out" ":cp ran inside the loop"
    assert_contains "removed extra.get.json" "$out" ":rm removed a request"
    assert_contains "removed gateway-copy" "$out" ":rm removed a directory"
    [[ -f $p/gateway/ping.get.json && ! -e $p/svc && ! -e $p/gateway-copy ]]
    assert_eq "0" "$?" "the filesystem ends as expected"
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
test_list_screen
test_selection_highlight
test_detail_screen
test_detail_params
test_detail_raw_data
test_detail_invalid
test_invalid_long_path
test_truncate_scroll
test_empty_project
test_command_mode
test_command_actions
test_help
test_dynamic_root
test_command_rename_dir
test_command_copy
test_command_remove
test_command_remove_dir
test_command_flow
test_review_flow
test_start_init
test_end_to_end
test_summary
