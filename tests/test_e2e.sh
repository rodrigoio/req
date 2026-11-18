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

test_notifications() {
    echo "e2e: notification bars at the top"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    local work=$TMP/notes out down=$'\033[B'
    mkdir -p "$work" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    printf 'restore_cursor=no\n' >"$REQ_CONFIG_DIR/projects/notes/config"      # every run opens at the top
    printf '{"name":"bad-address","method":"GET","url":"http://exa mple.com"}\n' >bad-address.get.json
    printf '{"name":"broken-one","method":"GET","url":"http://example.com","field_made_up_for_the_test":3}\n' >broken-one.get.json
    # shellcheck disable=SC2016  # a placeholder, literal text
    printf '{"name":"no-key","method":"GET","url":"http://127.0.0.1:1/${key_made_up_for_the_test}"}\n' >no-key.get.json

    out=$(menu "$(cmd zz)" "$(cmd q)")
    assert_contains "! unknown command :zz (:h lists the commands)" "$out" "an incorrect command shows the warning bar"
    assert_eq "1" "$(grep -c -F '! unknown command :zz' <<<"$out")" "once: the next keys draw the screen without it"
    assert_eq "0" "$(grep -c -F 'unknown command' <<<"${out#*"! unknown command"}")" "and nothing is left under the menu"

    out=$(menu "$down" "$ENTER" "$(cmd q)")                              # broken-one, the second item
    assert_contains '! invalid request: unknown field "field_made_up_for_the_test"' "$out" "an invalid request pins its problem at the top"
    assert_eq "1" "$(( $(grep -c -F '! invalid request:' <<<"$out") >= 2 ))" "and it stays while the request is open and a command is typed"

    out=$(menu "$ENTER" "$(cmd q)")                                      # bad-address, the first item
    assert_contains "! invalid address in the url: it contains whitespace" "$out" "an address that is not usable is pinned too"

    out=$(menu "$down" "$down" "$ENTER" "$ENTER" "$(cmd q)")             # no-key, the third item, run
    assert_contains '! no value for key_made_up_for_the_test in environment "default"' "$out" "a run that fails shows its error in the bar"
    assert_not_contains "req: error:" "$out" "and not as text in the terminal"

    out=$($REQ run "$work/bad-address.get.json" 2>&1)
    assert_contains "request failed (curl exit code" "$out" "req run keeps reporting on stderr"
    assert_not_contains "invalid address" "$out" "and has no bar"

    if (( $(id -u) == 0 )); then
        out=$(menu "$(cmd q)")
        assert_contains "! running as root: files you create or edit may end up owned by root" "$out" "as root the persistent notice is there"
    else
        echo "  skip not root: the root notice is checked by hand (T10.9)"
    fi
}

test_usability() {
    echo "e2e: Ctrl-L and req log"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/usability port out after count stripped log fpid
    local clear=$'\033[H\033[2J'
    port=$(<"$TMP/port")
    mkdir -p "$work" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    log=$REQ_CONFIG_DIR/projects/usability/req.log
    printf 'restore_cursor=no\nlog=yes\n' >"$REQ_CONFIG_DIR/projects/usability/config"
    printf '{"name":"ping","method":"GET","url":"http://127.0.0.1:%s/echo?q=ping_marker"}\n' "$port" >ping.get.json

    # The details of the request, a run (its result stays on the screen), Ctrl-L, quit. The raw bytes
    # are needed to see the clear sequence (PTY_RAW keeps the escapes).
    out=$(PTY_RAW=1 menu "$ENTER" "$ENTER" $'\f' "$(cmd q)")
    assert_contains "HTTP 200" "$out" "the request ran and its result is on the screen"
    stripped=${out//"$clear"/}
    count=$(( (${#out} - ${#stripped}) / ${#clear} ))
    assert_eq "1" "$count" "Ctrl-L cleared the terminal once (and no draw before it did)"
    after=${out#*"$clear"}
    assert_eq "GET    ping" "${after%%$'\n'*}" "the menu is drawn again right after, from the top, with the same request open"
    assert_not_contains "HTTP 200" "$after" "and the old result is not drawn again"

    # What that run wrote to the log is what req log shows, and it keeps following.
    assert_contains "RESPONSE status=200" "$(<"$log")" "(the run wrote its request and response to the log)"
    command -v timeout >/dev/null 2>&1 || { echo "  skip timeout unavailable"; return; }
    timeout 10 bash "$ROOT/bin/req" log >"$TMP/follow_out" 2>&1 &
    fpid=$!
    for _ in {1..50}; do grep -q 'RESPONSE status=200' "$TMP/follow_out" && break; sleep 0.1; done
    assert_contains "REQUEST file=ping.get.json" "$(<"$TMP/follow_out")" "req log shows the lines the real run wrote"
    printf '2026-11-18T00:00:00+0000 NOTE line_appended_by_the_test\n' >>"$log"
    for _ in {1..50}; do grep -q line_appended_by_the_test "$TMP/follow_out" && break; sleep 0.1; done
    assert_contains "line_appended_by_the_test" "$(<"$TMP/follow_out")" "and a line appended while it runs"
    kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
    sleep 0.3
    command -v pgrep >/dev/null 2>&1 && assert_eq "" "$(pgrep -f "tail -n 200 -F -- $log")" "stopping it leaves no tail running"
}

test_response_view() {
    echo "e2e: v shows the last response"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/viewer port out status down=$'\033[B' standin=$TMP/pager_standin
    port=$(<"$TMP/port")
    mkdir -p "$work" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    printf 'restore_cursor=no\n' >"$REQ_CONFIG_DIR/projects/viewer/config"
    # In the order of the menu: ping (JSON), plain-text (text/plain), refused (nothing listens there).
    printf '{"name":"ping","method":"GET","url":"http://127.0.0.1:%s/echo"}\n' "$port" >ping.get.json
    printf '{"name":"plain-text","method":"GET","url":"http://127.0.0.1:%s/text"}\n' "$port" >plain-text.get.json
    printf '{"name":"refused","method":"GET","url":"http://127.0.0.1:1/x"}\n' >refused.get.json
    # A pager that keeps what it is given in a file, so the test can look at it.
    cat >"$standin" <<'EOF'
#!/bin/sh
cat >"$REQ_TEST_PAGER_OUT"
EOF
    chmod +x "$standin"
    export REQ_TEST_PAGER_OUT=$TMP/pager_out

    rm -f "$REQ_TEST_PAGER_OUT"
    out=$(PAGER=$standin menu "v" "$(cmd q)"); status=$?
    assert_contains "! no response to view yet: run a request first" "$out" "v before any request: a warning in the bar"
    [[ ! -e $REQ_TEST_PAGER_OUT ]]; assert_eq "0" "$?" "and no pager"
    assert_eq "0" "$status" "and the menu goes on: :q ends it"

    out=$(PAGER=$standin menu "$ENTER" "$ENTER" "v" "$(cmd q)"); status=$?
    assert_contains "HTTP 200" "$out" "a JSON request ran"
    assert_contains $'\n  "method": "GET"' $'\n'"$(<"$REQ_TEST_PAGER_OUT")" "v gave the pager the response, indented"
    assert_eq "0" "$status" "the menu is back after the pager: :q ends it"
    assert_contains "v response" "$out" "and the hint says v is there"

    rm -f "$REQ_TEST_PAGER_OUT"
    out=$(PAGER=$standin menu "$down" "$ENTER" "$ENTER" "v" "$(cmd q)"); status=$?
    assert_eq "hello text" "$(<"$REQ_TEST_PAGER_OUT")" "a text response reaches the pager as it came"

    rm -f "$REQ_TEST_PAGER_OUT"
    out=$(PAGER=$standin menu "$down" "$down" "$ENTER" "$ENTER" "v" "$(cmd q)"); status=$?
    assert_contains "! no response to view: the last request got none" "$out" "a request with no response, then v: the warning says so"
    [[ ! -e $REQ_TEST_PAGER_OUT ]]; assert_eq "0" "$?" "and no pager"

    command -v less >/dev/null 2>&1 || { echo "  skip less unavailable"; return; }
    out=$(PAGER='' menu "$ENTER" "$ENTER" "v" "q" "$(cmd q)"); status=$?
    assert_eq "2" "$(grep -c -F '"method": "GET"' <<<"$out")" "the real less showed the response (once on the screen, once in the pager)"
    assert_eq "0" "$status" "q leaves it and the menu is back: :q ends it"
    out=$(PAGER='' menu "$ENTER" "$ENTER" "v" $'\003' "q" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "Ctrl-C inside less does not close req: :q still ends it normally"
}

# shellcheck disable=SC2016  # the ${key} placeholders of the requests are single-quoted on purpose
test_environments() {
    echo "e2e: environments the program creates and lets you choose"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/envs port out state up=$'\033[A' down=$'\033[B' esc=$'\033' envdir
    port=$(<"$TMP/port")
    mkdir -p "$work" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    state=$REQ_CONFIG_DIR/projects/envs; envdir=$state/env
    printf 'restore_cursor=no\n' >"$state/config"
    printf '{"name":"a-ping","method":"GET","url":"http://127.0.0.1:%s/echo","headers":{"X-Test":"${tag}"}}\n' "$port" >a-ping.get.json
    printf '{"name":"b-extra","method":"GET","url":"http://127.0.0.1:%s/echo/${extra}"}\n' "$port" >b-extra.get.json

    # 1. nothing is made by hand: the folder and default exist right after req init, private
    [[ -d $envdir && -f $envdir/default ]]; assert_eq "0" "$?" "req init made the env folder and the default environment"
    assert_eq "700" "$(stat -c %a "$envdir")" "the folder is private"
    assert_eq "600" "$(stat -c %a "$envdir/default")" "and so is the file"
    rm -rf "$envdir"
    menu "$(cmd q)" >/dev/null
    [[ -f $envdir/default ]]; assert_eq "0" "$?" "a project from before this gets them when its menu opens"

    # 2. :env opens the menu: default in use, and the last row creates a new one
    out=$(menu "$(cmd env)" "$esc" "$(cmd q)")
    assert_contains "req environments" "$out" ":env opens the environment menu"
    assert_contains "default (in use)" "$out" "with default, the one in use"
    assert_contains "+ new environment" "$out" "and + new environment as the last row"
    assert_contains "Enter choose   Esc cancel" "$out" "and the keys on the hint line"

    # 3. the last row creates an environment: the name is asked, the file made, the variables loaded
    out=$(menu "$(cmd env)" "$up" "$ENTER" $'staging\r' "$(cmd q)")
    assert_contains "Environment name (a slug, e.g. staging)" "$out" "up from the top is + new environment, and Enter asks for the name"
    assert_contains "environment: staging, created in $envdir/staging (no variables)" "$out" "the environment is created and says where"
    assert_contains "envs @ staging" "$out" "and the header shows it"
    [[ -f $envdir/staging ]]; assert_eq "0" "$?" "the file is there"
    assert_eq "600" "$(stat -c %a "$envdir/staging")" "private"

    # 4. each environment is its own set of variables (the files are filled as a user would)
    printf 'tag=from-staging\nextra=staging-extra\n' >"$envdir/staging"
    printf 'tag=from-dev\n' >"$envdir/dev"
    out=$(menu "$(cmd env staging)" "$ENTER" "$ENTER" "$esc" "$down" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "environment: staging (2 variables)" "$out" ":env <name> switches straight to an environment and loads its variables"
    assert_contains '"x_test": "from-staging"' "$out" "a request uses the values of staging"
    assert_contains '"path": "/echo/staging-extra"' "$out" "all of them"
    out=$(menu "$(cmd env staging)" "$(cmd env dev)" "$ENTER" "$ENTER" "$esc" "$down" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "environment: dev (1 variable)" "$out" "switching to dev loads its own set"
    assert_contains '"x_test": "from-dev"' "$out" "a request uses the values of dev"
    assert_contains 'no value for extra in environment "dev"' "$out" "and nothing of staging stays: the key only staging had is missing"
    assert_not_contains "staging-extra" "$out" "so the request was not sent with it"

    # 5. the menu chooses too: default is in use, down is dev
    out=$(menu "$(cmd env)" "$down" "$ENTER" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "environment: dev (1 variable)" "$out" "Enter on a row of the menu switches to it"
    assert_contains '"x_test": "from-dev"' "$out" "and the next request runs in it"
    out=$(menu "$(cmd env dev)" "$(cmd env)" "$down" "$esc" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains '"x_test": "from-dev"' "$out" "Esc on the menu leaves the environment as it was"

    # 6. an environment that does not exist is offered for creation
    out=$(menu "$(cmd env prd)" $'n\r' "$(cmd q)")
    assert_contains 'Create environment "prd"? [Y/n]' "$out" ":env <name> asks before it creates one"
    assert_contains 'environment "prd" not created (in use: default)' "$out" "n says so and changes nothing"
    [[ ! -e $envdir/prd ]]; assert_eq "0" "$?" "no file is made"
    out=$(menu "$(cmd env prd)" "$ENTER" "$(cmd q)")
    assert_contains "environment: prd, created in $envdir/prd" "$out" "Enter creates it and switches"
    [[ -f $envdir/prd ]]; assert_eq "0" "$?" "with its file"

    # 7. a broken file is reported when switching to it, and left alone
    printf 'url=http://x\nthis line is not a pair\n' >"$envdir/broken-test-env"
    out=$(menu "$(cmd env broken-test-env)" "$(cmd q)")
    assert_contains "$envdir/broken-test-env:2: expected key=value" "$out" "the warning has the path and the line"
    assert_contains "environment: broken-test-env (variables not loaded)" "$out" "the switch stands, with nothing loaded"
    assert_eq $'url=http://x\nthis line is not a pair' "$(<"$envdir/broken-test-env")" "and the file is not touched"
    cd "$ROOT" || return
}

test_flow
test_notifications
test_usability
test_response_view
test_environments
test_summary
