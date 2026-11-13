#!/usr/bin/env bash
# Tests for lib/nav.sh. Outside a terminal there are no colors and nothing is erased.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"
source "$ROOT/lib/store.sh"
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
    mkdir -p "$p/api/v2" "$p/auth"
    printf 'api\nauth\n' >"$p/.req"
    req_request_write "$p/api" list-users GET http://x/users \
        '{"description":"lists everyone","headers":{"Accept":"application/json"},"query":{"page":1}}' >/dev/null
    req_request_write "$p/api" create POST http://x/users \
        '{"data_parameter":{"user":"ann"}}' >/dev/null
    req_request_write "$p/api" remove DELETE http://x/users \
        '{"data_parameter":{"id":1}}' >/dev/null
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

    type_keys : n enter
    assert_contains "open a directory first" "$REQ_STATUS" ":n at the root explains itself"
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
    assert_contains "billing" "$(<"$PROJ/.req")" "and lists it in the .req"
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

test_start_init() {
    echo "nav: init prompt"
    local d=$TMP/fresh out
    mkdir -p "$d"
    # req_nav_start needs a terminal; here we check the building blocks it uses.
    req_project_find "$d" >/dev/null; assert_eq "1" "$?" "a fresh directory has no .req"
    out=$(printf 'y\n' | req_confirm "Initialize a req project here?")
    assert_contains "Initialize a req project here? [Y/n]" "$out" "prompt text"
    req_project_init "$d" && req_nav_init "$d/.req"
    assert_eq "requests" "${REQ_ITEM_LABEL[*]}" "the initialized project opens at its default directory"
    req_nav_handle enter
    screen list; assert_contains "(empty)" "$OUT" "the default directory starts empty"
}

test_keys
test_navigation
test_list_screen
test_selection_highlight
test_detail_screen
test_detail_params
test_detail_invalid
test_invalid_long_path
test_truncate_scroll
test_empty_project
test_command_mode
test_command_actions
test_command_flow
test_start_init
test_end_to_end
test_summary
