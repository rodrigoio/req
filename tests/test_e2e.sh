#!/usr/bin/env bash
# End-to-end test (T7.6): the real bin/req, a project, a request made through the menu,
# variables and environments, the log and the verbose mode, and `req run`. The only fake
# part is the server (tests/mock_server.py, needs python3). Keys and the wizard's answers
# go through stdin, as they do on a terminal.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"

TMP=$(mktemp -d)
SERVER_PID=""
trap '[[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/central
unset REQ_ENV REQ_VERBOSE
REQ="bash $ROOT/bin/req"

# menu <chunk...> - runs the menu in a pseudo-terminal (tests/pty_run.py: the real
# bin/req refuses anything but a terminal), typing one chunk at a time. Enter is \r.
menu() { python3 -I "$ROOT/tests/pty_run.py" "$@" -- bash "$ROOT/bin/req" 2>&1; }

# cmd <text> - a command: ":" then the text, then Enter.
cmd() { printf ':%s\r' "$*"; }
ENTER=$'\r'

test_flow() {
    echo "e2e: project, request, variables, environments, log and verbose"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    python3 -I "$ROOT/tests/mock_server.py" >"$TMP/port" 2>/dev/null &
    SERVER_PID=$!
    local port out work=$TMP/work id state
    for _ in {1..50}; do [[ -s $TMP/port ]] && break; sleep 0.1; done
    [[ -s $TMP/port ]] || { echo "  skip the mock server did not start"; return; }
    port=$(<"$TMP/port")

    # 1. init
    mkdir -p "$work" && cd "$work" || return
    out=$($REQ init 2>&1); assert_eq "0" "$?" "req init works"
    assert_contains "Initialized req project" "$out" "and says so"
    assert_contains "workspace=." "$(<"$work/.req")" "the .req holds the workspace"
    id=$(basename "$(dirname "$(grep -l "path=$work" "$REQ_CONFIG_DIR"/projects/*/project)")")
    assert_eq "work" "$id" "the project is registered in the central directory"
    state=$REQ_CONFIG_DIR/projects/$id

    # 2. create a request through the menu (name, method, url, no editor), then quit
    out=$(menu "$(cmd n)" "login"$'\r' "POST"$'\r' "http://127.0.0.1:$port/echo"$'\r' "n"$'\r' "$(cmd q)")
    assert_contains "created login.post.json" "$out" "the menu created the request"
    [[ -f $work/login.post.json ]]; assert_eq "0" "$?" "in the workspace"

    # 3. the request gets placeholders (what :e would do in an editor)
    # shellcheck disable=SC2016  # the placeholders are jq strings on purpose
    jq '.url="${base}/echo" | .headers={"X-Test":"${tok}"} | .raw_data={"user":"${tok}"}' \
        "$work/login.post.json" >"$work/login.tmp" && mv "$work/login.tmp" "$work/login.post.json"
    printf 'base=http://127.0.0.1:%s\ntok=from-vars\n' "$port" >"$state/vars"
    mkdir -p "$state/env"; printf 'tok=from-dev\n' >"$state/env/dev"

    # 4. run from the menu in the default environment: variables from vars
    out=$(menu "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "POST http://127.0.0.1:$port/echo" "$out" "the menu shows the substituted url"
    assert_contains "HTTP 200" "$out" "and runs the request"
    assert_contains '"x_test": "from-vars"' "$out" "the header came from the project variables"
    assert_contains 'from-vars' "$(grep -o 'body.*' <<<"$out" | head -n 1)" "and so did the body"

    # 5. :env dev switches the environment: the file wins over vars
    out=$(menu "$(cmd env dev)" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "work @ dev" "$out" "the header shows the environment"
    assert_contains '"x_test": "from-dev"' "$out" "the environment file wins over the project variables"

    # 6. a process variable wins over both; REQ_ENV chooses the environment from outside
    out=$(DEV_TOK=from-process REQ_ENV=dev $REQ run "$work/login.post.json" 2>&1)
    assert_eq "0" "$?" "req run works"
    assert_contains '"x_test": "from-process"' "$out" "the process variable DEV_TOK wins"

    # 7. a missing key stops the request with a friendly error
    printf 'base=http://127.0.0.1:%s\n' "$port" >"$state/vars"
    out=$($REQ run "$work/login.post.json" 2>&1); assert_eq "1" "$?" "a missing key fails req run"
    assert_contains 'no value for tok in environment "default"' "$out" "naming the key and the environment"
    assert_contains "DEFAULT_TOK" "$out" "and how to define it"
    printf 'base=http://127.0.0.1:%s\ntok=from-vars\n' "$port" >"$state/vars"

    # 8. log and verbose: off by default, on with :log and :v, in one session
    out=$($REQ run "$work/login.post.json" 2>&1)
    [[ $out != *'>>'* && ! -e $state/req.log ]]; assert_eq "0" "$?" "by default no verbose lines and no log"
    out=$(menu "$(cmd v)" "$(cmd log)" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains '>> {"user":"from-vars"}' "$out" ":v shows the data sent"
    assert_contains "<< HTTP/" "$out" "and the response headers"
    assert_eq "2" "$(wc -l <"$state/req.log" | tr -d ' ')" ":log wrote the request and the response"
    assert_contains "REQUEST file=login.post.json env=default POST http://127.0.0.1:$port/echo" "$(sed -n 1p "$state/req.log")" "the first line is the request"
    assert_contains "RESPONSE status=200" "$(sed -n 2p "$state/req.log")" "the second is the response"

    # 9. the setting: :config log=yes for the project makes req run log too
    out=$(menu "$(cmd config log=yes)" "$(cmd q)")
    assert_eq "yes" "$(req_kv_get_line "$state/config" log)" ":config wrote the project's file"
    $REQ run "$work/login.post.json" >/dev/null 2>&1
    assert_eq "4" "$(wc -l <"$state/req.log" | tr -d ' ')" "and req run now logs"

    # 10. the cursor is saved and the project state survives
    assert_contains "dir=" "$(<"$state/cursor")" "the menu saved the cursor on exit"
    cd "$ROOT" || return
}

# req_kv_get_line <file> <key> - the value of key=value in a file (no library needed here).
req_kv_get_line() { sed -n "s/^$2=//p" "$1" | head -n 1; }

test_flow
test_summary
