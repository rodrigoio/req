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

# guarded_menu <chunk...> - menu with a limit of time: a session that is meant to end by itself (a key that quits)
# and does not fails with status 124, instead of waiting for ever.
guarded_menu() { timeout 60 python3 -I "$ROOT/tests/pty_run.py" "$@" -- bash "$ROOT/bin/req" 2>&1; }

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
    printf 'base=http://127.0.0.1:%s\ntok=from-vars\n' "$port" >"$state/env/default/vars"
    mkdir -p "$state/env/dev"; printf 'base=http://127.0.0.1:%s\ntok=from-dev\n' "$port" >"$state/env/dev/vars"

    # 4. run from the menu in the default environment: the variables of that environment
    out=$(menu "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "POST http://127.0.0.1:$port/echo" "$out" "the menu shows the substituted url"
    assert_contains "HTTP 200" "$out" "and runs the request"
    assert_contains '"x_test": "from-vars"' "$out" "the header came from the variables of default"
    assert_contains 'from-vars' "$(grep -o 'body.*' <<<"$out" | head -n 1)" "and so did the body"

    # 5. :env dev switches the environment: it has its own variables
    out=$(menu "$(cmd env dev)" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "work @ dev" "$out" "the header shows the environment"
    assert_contains '"x_test": "from-dev"' "$out" "the variables of dev are used, not those of default"

    # 6. a process variable wins over the file; REQ_ENV chooses the environment from outside
    out=$(DEV_TOK=from-process REQ_ENV=dev $REQ run "$work/login.post.json" 2>&1)
    assert_eq "0" "$?" "req run works"
    assert_contains '"x_test": "from-process"' "$out" "the process variable DEV_TOK wins"

    # 7. a missing key stops the request with a friendly error
    printf 'base=http://127.0.0.1:%s\n' "$port" >"$state/env/default/vars"
    out=$($REQ run "$work/login.post.json" 2>&1); assert_eq "1" "$?" "a missing key fails req run"
    assert_contains 'no value for tok in environment "default"' "$out" "naming the key and the environment"
    assert_contains "DEFAULT_TOK" "$out" "and how to define it"
    printf 'base=http://127.0.0.1:%s\ntok=from-vars\n' "$port" >"$state/env/default/vars"

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
    assert_eq "2" "$count" "the terminal was cleared when the menu started and once by Ctrl-L (no draw cleared it)"
    after=${out##*"$clear"}
    assert_eq "GET    ping" "${after%%$'\n'*}" "the menu is drawn again right after, from the top: the details come first, without the logo"
    assert_contains "url  http://" "$(sed -n 2p <<<"$after")" "and the same request is open: its url is under it"
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
    assert_not_contains "v response" "$out" "and no hint line about v (the help lists it)"

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

    # 1. nothing is made by hand: env/ and default (a folder with a vars file) exist right after req init, private
    [[ -d $envdir/default && -f $envdir/default/vars ]]; assert_eq "0" "$?" "req init made the env folder and the default environment"
    assert_eq "700" "$(stat -c %a "$envdir")" "env/ is private"
    assert_eq "700" "$(stat -c %a "$envdir/default")" "so is the folder of the environment"
    assert_eq "600" "$(stat -c %a "$envdir/default/vars")" "and its file"
    rm -rf "$envdir"
    menu "$(cmd q)" >/dev/null
    [[ -f $envdir/default/vars ]]; assert_eq "0" "$?" "a project from before this gets them when its menu opens"

    # 2. :env opens the menu: default in use, and the last row creates a new one
    out=$(menu "$(cmd env)" "$esc" "$(cmd q)")
    assert_contains "req environments" "$out" ":env opens the environment menu"
    assert_contains "default (in use)" "$out" "with default, the one in use"
    assert_contains "+ new environment" "$out" "and + new environment as the last row"
    assert_not_contains "Enter choose" "$out" "and no hint line about its keys"

    # 3. the last row creates an environment: the name is asked, the folder and its file made, the variables loaded
    out=$(menu "$(cmd env)" "$up" "$ENTER" $'staging\r' "$(cmd q)")
    assert_contains "Environment name (a slug, e.g. staging)" "$out" "up from the top is + new environment, and Enter asks for the name"
    assert_contains "environment: staging, created in $envdir/staging/vars (no variables)" "$out" "the environment is created and says where its file is"
    assert_contains "envs @ staging" "$out" "and the header shows it"
    [[ -f $envdir/staging/vars ]]; assert_eq "0" "$?" "the file is there, in the folder of the environment"
    assert_eq "600" "$(stat -c %a "$envdir/staging/vars")" "private"

    # 4. each environment is its own set of variables (the files are filled as a user would)
    printf 'tag=from-staging\nextra=staging-extra\n' >"$envdir/staging/vars"
    mkdir -p "$envdir/dev"; printf 'tag=from-dev\n' >"$envdir/dev/vars"
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
    [[ ! -e $envdir/prd ]]; assert_eq "0" "$?" "nothing is made"
    out=$(menu "$(cmd env prd)" "$ENTER" "$(cmd q)")
    assert_contains "environment: prd, created in $envdir/prd/vars" "$out" "Enter creates it and switches"
    [[ -f $envdir/prd/vars ]]; assert_eq "0" "$?" "with its file"

    # 7. a broken file is reported when switching to it, and left alone
    mkdir -p "$envdir/broken-test-env"; printf 'url=http://x\nthis line is not a pair\n' >"$envdir/broken-test-env/vars"
    out=$(menu "$(cmd env broken-test-env)" "$(cmd q)")
    assert_contains "$envdir/broken-test-env/vars:2: expected key=value" "$out" "the warning has the path and the line"
    assert_contains "environment: broken-test-env (variables not loaded)" "$out" "the switch stands, with nothing loaded"
    assert_eq $'url=http://x\nthis line is not a pair' "$(<"$envdir/broken-test-env/vars")" "and the file is not touched"
    cd "$ROOT" || return
}

# editors_off <dir> - makes <dir> a PATH with what the menu needs and no editor at all (no vim, vi,
# nano or editor), so that "there is no vim" is true for the real run and not only on this machine.
editors_off() {
    local t
    mkdir -p "$1"
    for t in bash sh env python3 curl jq awk sed grep cat mktemp rm mkdir dirname basename tr sort stty \
             tput date stat tail head wc cp mv ls tty cut sleep id uname readlink chmod ln touch less; do
        command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$1/$t"
    done
    return 0
}

# shellcheck disable=SC2016  # the text of the fake editors and the placeholders are single-quoted on purpose
test_vars() {
    echo "e2e: :vars edits the variables of the environment in the editor"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/varsproj port out status state file fakes=$TMP/vars-fakes tools=$TMP/vars-tools
    port=$(<"$TMP/port")
    mkdir -p "$work" "$fakes" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    state=$REQ_CONFIG_DIR/projects/varsproj; file=$state/env/default/vars
    printf 'restore_cursor=no\n' >"$state/config"
    printf '{"name":"a-ping","method":"GET","url":"${host}/echo","headers":{"X-Test":"${tag}"}}\n' >a-ping.get.json
    printf '#!/bin/sh\nprintf "host=http://127.0.0.1:%s\\ntag=from-vars\\n" >>"$1"\n' "$port" >"$fakes/writer"
    printf '#!/bin/sh\necho "tag=second-line" >>"$1"\n' >"$fakes/second"
    printf '#!/bin/sh\nprintf "ok=1\\nthis line is not a pair\\n" >"$1"\n' >"$fakes/breaker"
    printf '#!/bin/sh\nexit 3\n' >"$fakes/failer"
    printf '#!/bin/sh\ncat "$1" >"%s/seen"\n' "$fakes" >"$fakes/viewer"
    chmod +x "$fakes"/*
    unset VISUAL EDITOR

    # 1. the environment has its vars file from the start, with comments; with its folder gone :vars makes both
    assert_contains "# Variables of environment default" "$(<"$file")" "req init made the vars file of default, with comments that show the format"
    rm -rf "$state/env/default"
    out=$(VISUAL=$fakes/viewer menu "$(cmd vars)" "$(cmd q)")
    [[ -f $file ]]; assert_eq "0" "$?" ":vars made the folder and the file"
    assert_eq "600" "$(stat -c %a "$file")" "private"
    assert_contains "# host=https://api.example.com" "$(<"$fakes/seen")" "the editor found the commented examples in it"
    assert_contains "environment: default (no variables)" "$out" "the comment lines are not variables"

    # 2. what the editor writes is used by the next request, and the comments define nothing
    out=$(VISUAL=$fakes/writer menu "$(cmd vars)" "$ENTER" "$ENTER" "$(cmd q)")
    assert_contains "environment: default (2 variables)" "$out" "when the editor closes the variables are loaded and counted"
    assert_contains "GET http://127.0.0.1:$port/echo" "$out" "the request goes to the host from the file, not to the commented example"
    assert_contains '"x_test": "from-vars"' "$out" "and uses its other variable"
    assert_contains "# Variables of environment default" "$(<"$file")" "the file keeps the comments the program wrote"

    # 3. :var is the same command, and the editor works on the file in the project's folder
    out=$(VISUAL=$fakes/second menu "$(cmd var)" "$(cmd q)")
    assert_contains "environment: default (2 variables)" "$out" ":var runs it too (a repeated key keeps its first line)"
    assert_contains "tag=second-line" "$(<"$file")" "and the editor appended to the same file"

    # 4. the editors, in order: VISUAL, EDITOR, vim, nano, then the message (a PATH with no real editor)
    editors_off "$tools"
    printf '#!/bin/sh\necho "from-vim" >>"$1"\n' >"$tools/vim"
    printf '#!/bin/sh\necho "from-nano" >>"$1"\n' >"$tools/nano"
    chmod +x "$tools/vim" "$tools/nano"
    : >"$file"
    PATH=$tools menu "$(cmd vars)" "$(cmd q)" >/dev/null
    assert_eq "from-vim" "$(<"$file")" "with no VISUAL or EDITOR vim is used"
    rm -f "$tools/vim"; : >"$file"
    PATH=$tools menu "$(cmd vars)" "$(cmd q)" >/dev/null
    assert_eq "from-nano" "$(<"$file")" "without vim, nano is used"
    printf '#!/bin/sh\necho "from-vim" >>"$1"\n' >"$tools/vim"; chmod +x "$tools/vim"; : >"$file"
    PATH=$tools EDITOR=$fakes/second menu "$(cmd vars)" "$(cmd q)" >/dev/null
    assert_eq "tag=second-line" "$(<"$file")" "the user's EDITOR comes before vim and nano"
    : >"$file"
    PATH=$tools VISUAL=$fakes/writer EDITOR=$fakes/second menu "$(cmd vars)" "$(cmd q)" >/dev/null
    assert_contains "tag=from-vars" "$(<"$file")" "and VISUAL before EDITOR"

    # 5. no editor at all: the file is made anyway and the message says where it is and how to write it
    rm -f "$tools/vim" "$tools/nano" "$file"
    out=$(PATH=$tools menu "$(cmd vars)" "$ENTER" "$(cmd q)"); status=$?
    assert_contains 'No editor found (tried $VISUAL, $EDITOR, vim and nano).' "$out" "with no editor the message says so"
    assert_contains "$file" "$out" "gives the whole path of the file"
    assert_contains "host=https://api.example.com" "$out" "shows how to write a variable"
    assert_contains 'use it in a request as ${host}' "$out" "and how a request uses it"
    [[ -f $file ]]; assert_eq "0" "$?" "the file exists, ready to be filled any other way"
    assert_eq "600" "$(stat -c %a "$file")" "private"
    assert_contains "Press Enter to go back" "$out" "and waits for Enter"
    assert_eq "0" "$status" "after which the menu is back: the :q that follows quit it"

    # 6. a bad line is reported with its path and line, and the file is left as the editor wrote it
    out=$(VISUAL=$fakes/breaker menu "$(cmd vars)" "$(cmd q)")
    assert_contains "$file:2: expected key=value" "$out" "a bad line has the path and the line in the warning"
    assert_contains "environment: default (variables not loaded)" "$out" "and nothing is loaded"
    assert_eq $'ok=1\nthis line is not a pair' "$(<"$file")" "the file is not fixed"

    # 7. an editor that fails, and a wrong use
    out=$(VISUAL=$fakes/failer menu "$(cmd vars)" "$(cmd q)")
    assert_contains "the editor failed; $file is as the editor left it" "$out" "an editor that fails is a warning with the path"
    out=$(VISUAL=$fakes/viewer menu "$(cmd vars dev)" "$(cmd q)")
    assert_contains "usage: :vars" "$out" "an argument is a usage warning"
    assert_contains ":vars" "$(menu "$(cmd h)" "$ENTER" "$(cmd q)")" "the help lists :vars"
    cd "$ROOT" || return
}

test_headers() {
    echo "e2e: headers are typed as key=value, like query and parameters"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/hdrs port out state file
    port=$(<"$TMP/port")
    mkdir -p "$work" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    state=$REQ_CONFIG_DIR/projects/hdrs; file=$work/ping.get.json
    printf 'restore_cursor=no\nlog=yes\n' >"$state/config"
    printf 'tok=from-vars\n' >"$state/env/default/vars"

    # 1. :n: a header with a placeholder typed as key=value is stored; one typed as key: value is refused
    # shellcheck disable=SC2016  # a placeholder, literal text
    out=$(menu "$(cmd n)" "ping"$'\r' "GET"$'\r' "http://127.0.0.1:$port/echo"$'\r' "y"$'\r' $'\r' "4"$'\r' \
        'X-Test=Bearer ${tok}'$'\r' 'Accept: a/b'$'\r' $'\r' $'\r' "$(cmd q)")
    assert_contains "Headers: key=value per line" "$out" ":n asks for the headers as key=value"
    assert_contains "expected key=value" "$out" "a header typed as key: value is refused with the format"
    assert_contains "created ping.get.json" "$out" "the request is made"
    # shellcheck disable=SC2016  # a placeholder, literal text
    assert_eq '{"X-Test":"Bearer ${tok}"}' "$(jq -c .headers "$file")" "with the typed header only, the placeholder kept"

    # 2. run: the placeholder of the header is replaced by the variable
    out=$($REQ run "$file" 2>&1)
    assert_contains '"x_test": "Bearer from-vars"' "$out" "the header reaches the server with the value of the variable"

    # 3. :e, field 5: a key=value line adds a header and the others stay; key: value is refused and changes nothing
    # shellcheck disable=SC2016  # a placeholder, literal text
    out=$(menu "$(cmd e)" "5"$'\r' 'X-Extra=${tok}'$'\r' $'\r' "s"$'\r' "$(cmd q)")
    assert_contains "saved ping.get.json" "$out" ":e saves the request"
    # shellcheck disable=SC2016  # a placeholder, literal text
    assert_eq '{"X-Test":"Bearer ${tok}","X-Extra":"${tok}"}' "$(jq -c .headers "$file")" "the new header joins the old one"
    out=$(menu "$(cmd e)" "5"$'\r' 'X-Bad: 1'$'\r' $'\r' "q"$'\r' "$(cmd q)")
    assert_contains "expected key=value" "$out" ":e refuses key: value too"
    assert_eq "2" "$(jq '.headers | length' "$file")" "and the headers stay as they were"

    # 4. both headers go out with their values (the log has the request as it was sent)
    : >"$state/req.log"
    $REQ run "$file" >/dev/null 2>&1
    assert_contains "| header: X-Test: Bearer from-vars | header: X-Extra: from-vars" "$(<"$state/req.log")" "each header is sent with its value"
    cd "$ROOT" || return
}

test_start_clear() {
    echo "e2e: the screen is cleared when the menu starts"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/startclear empty=$TMP/startclear-empty port out stripped count
    local clear=$'\033[H\033[2J'
    port=$(<"$TMP/port")
    mkdir -p "$work" "$empty" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    printf 'restore_cursor=no\n' >"$REQ_CONFIG_DIR/projects/startclear/config"
    printf '{"name":"ping","method":"GET","url":"http://127.0.0.1:%s/echo"}\n' "$port" >ping.get.json

    # 1. the first thing a start prints is the clear, once, and the menu comes after it
    out=$(PTY_RAW=1 menu "$(cmd q)")
    assert_eq "$clear" "${out:0:${#clear}}" "the first thing the menu prints is the clear sequence"
    stripped=${out//"$clear"/}
    count=$(( (${#out} - ${#stripped}) / ${#clear} ))
    assert_eq "1" "$count" "and it clears once"
    assert_contains "{❯} Req / (1/1)" "${out#"$clear"}" "the menu is drawn after it, with the logo in its header"

    # 2. what is not the menu never clears
    out=$($REQ run "$work/ping.get.json" 2>&1)
    assert_not_contains $'\033[2J' "$out" "req run does not clear the screen"
    out=$($REQ --version 2>&1)
    assert_not_contains $'\033[2J' "$out" "nor does --version"

    # 3. with no project the clear comes before the offer to start one
    cd "$empty" || return
    out=$(PTY_RAW=1 menu "n"$'\r')
    assert_eq "$clear" "${out:0:${#clear}}" "with no project the clear comes first too"
    assert_contains "No .req file found" "${out#"$clear"}" "and then the offer to start a project"
    assert_contains "Nothing created" "$out" "(declined here: nothing is made)"
    cd "$ROOT" || return
}

test_usability_release() {
    echo "e2e: the usability release (a clean start, q and Esc, h, no hint lines, messages in the bar)"
    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    command -v timeout >/dev/null 2>&1 || { echo "  skip timeout unavailable"; return; }
    [[ -s $TMP/port ]] || { echo "  skip the mock server of test_flow is not running"; return; }
    local work=$TMP/usab port out status state after line word details
    local clear=$'\033[H\033[2J' esc=$'\033' down=$'\033[B'
    port=$(<"$TMP/port")
    mkdir -p "$work/sub" && cd "$work" || return
    $REQ init >/dev/null 2>&1
    state=$REQ_CONFIG_DIR/projects/usab
    printf 'restore_cursor=no\n' >"$state/config"
    printf '{"name":"ping","method":"GET","url":"http://127.0.0.1:%s/echo"}\n' "$port" >sub/ping.get.json
    printf '{"name":"top","method":"GET","url":"http://127.0.0.1:%s/echo"}\n' "$port" >top.get.json

    # 1. a clean start, no hint line on the list, and q at the root ends the program by itself
    out=$(PTY_RAW=1 guarded_menu "q"); status=$?
    assert_eq "0" "$status" "q at the root of the list quits req"
    assert_eq "$clear" "${out:0:${#clear}}" "the screen was cleared when the menu started"
    assert_contains "{❯} Req / (1/2)" "$out" "and the list was drawn, with the logo in its header"
    for word in "Enter open" "Esc back" "v response" ":h help" "move   Enter"; do
        assert_not_contains "$word" "$out" "the list has no hint line: no \"$word\""
    done

    # 2. Esc at the root does nothing (the program is still there to open the help), and the help lists every key
    out=$(guarded_menu "$esc" "h" "x" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "Esc did not quit: h opened the help, a key closed it, :q ended the session"
    assert_contains "req help" "$out" "h opened the help"
    for word in "move the selection" "go back one level" "this help (same as :h)" "show the last response" \
                "clear the screen" "closes this help" "command mode"; do
        assert_contains "$word" "$out" "the help lists a key: $word"
    done
    assert_contains "Ctrl-C   quit" "$out" "Ctrl-C included"

    # 3. on the details h opens the help and any key goes back to them; q goes back to the list of the directory
    out=$(guarded_menu "$ENTER" "$ENTER" "h" "x" "q" "$ENTER" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "the session ended with :q"
    assert_eq $'dir=sub\nitem=sub/ping.get.json' "$(<"$state/cursor")" "q on the details went back to the list of sub, not further"
    assert_not_contains "HTTP 200" "$out" "after q the list was showing: Enter opened the details again and ran nothing"
    assert_contains "req help" "$out" "h opened the help on the details"
    for word in "Enter run" "Esc back" "Enter choose" "Press any key"; do
        assert_not_contains "$word" "$out" "no hint line on the details or the help: no \"$word\""
    done

    # 4. q goes up from a directory to the root
    out=$(guarded_menu "$ENTER" "q" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "the session ended with :q"
    assert_eq $'dir=\nitem=sub' "$(<"$state/cursor")" "q went up from sub to the root, with sub selected"

    # 5. q leaves the environment menu (:q works afterwards, so the view is the list again), and it has no hint line
    out=$(guarded_menu "$(cmd env)" "q" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "q left the :env menu: the :q that follows ended the session"
    assert_contains "req environments" "$out" "the menu was open"
    assert_not_contains "Enter choose" "$out" "with no hint line"

    # 6. what a command says is a bar at the top, once, right above the header and not under the menu
    out=$(guarded_menu "$(cmd env staging)" "$ENTER" "$(cmd q)"); status=$?
    assert_eq "0" "$status" "the session ended with :q"
    assert_eq "1" "$(grep -c 'environment: staging, created in' <<<"$out")" ":env staging said where it made the file, once"
    line=$(grep -n '^! environment: staging, created in' <<<"$out" | head -1 | cut -d: -f1)
    assert_contains "! environment: staging, created in" "$(sed -n "${line:-0}p" <<<"$out")" "in a bar"
    assert_contains "{❯} Req / (1/2)  usab @ staging" "$(sed -n "$(( ${line:-0} + 1 ))p" <<<"$out")" "and the header, in the new environment, is right under it"

    # 7. an arrow key in the viewer does not close it (Esc is not bound there: it would close it at the first arrow)
    if command -v less >/dev/null 2>&1; then
        out=$(PAGER='' guarded_menu "$down" "$ENTER" "$ENTER" "v" "$down" "q" "$(cmd q)"); status=$?
        assert_eq "0" "$status" "the session ended with :q"
        assert_contains "HTTP 200" "$out" "the request ran"
        after=$(awk '/^=+$/ { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' <<<"$out")
        assert_contains "GET    top" "$after" "after the run the details were drawn again, the viewer was opened"
        assert_not_contains "{❯} Req / (" "$after" "an arrow key did not close the viewer, and q closed it: the list was never drawn again"
    else
        echo "  skip less unavailable"
    fi

    # 8. the logo is in the header of the list and nowhere else: opening a request and coming back never leaves it
    # on a row of its own or in the details, and the list shows it once per draw
    out=$(guarded_menu "$down" "$ENTER" "$esc" "q"); status=$?
    assert_eq "0" "$status" "q at the root of the list ended the session (no command was typed, so no extra draw)"
    assert_eq "0" "$(grep -c -E '^\{❯\} Req[[:space:]]*$' <<<"$out")" "the logo has no row of its own"
    # the details block: the row above its first line (where a logo of its own would be) up to the next list header
    details=$(awk '/^GET    top/ { on = 1; print prev } on && /\{❯\} Req/ { exit } on { print } { prev = $0 }' <<<"$out")
    assert_contains "url  http://" "$details" "the details of the request were drawn"
    assert_not_contains "{❯}" "$details" "and they have no logo"
    assert_eq "3" "$(grep -c '{❯} Req / (' <<<"$out")" "the list has it once per draw: the start, the arrow and the way back from the details"
    cd "$ROOT" || return
}

test_flow
test_notifications
test_usability
test_response_view
test_environments
test_vars
test_headers
test_start_clear
test_usability_release
test_summary
