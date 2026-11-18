#!/usr/bin/env bash
# Tests for lib/log.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/log.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/cfg
mkdir -p "$REQ_CONFIG_DIR/projects/shop"

# on - turns the log on for the project "shop"; off - turns it off.
on()  { REQ_PROJECT_ID=shop; REQ_CONFIG=([log]=yes); }
off() { REQ_PROJECT_ID=shop; REQ_CONFIG=([log]=no); }

test_enabled() {
    echo "log: when it is written"
    local f
    on; f=$(req_log_file)
    assert_eq "$TMP/cfg/projects/shop/req.log" "$f" "the log is req.log in the project's directory"
    req_log_enabled; assert_eq "0" "$?" "log=yes with a project: enabled"
    off; req_log_enabled; assert_eq "1" "$?" "log=no: disabled"
    REQ_PROJECT_ID=""; REQ_CONFIG=([log]=yes); req_log_enabled; assert_eq "1" "$?" "no project: disabled"
    REQ_CONFIG=(); REQ_PROJECT_ID=shop; req_log_enabled; assert_eq "1" "$?" "the default is off"
    off; REQ_LOG_SESSION=yes; req_log_enabled; assert_eq "0" "$?" "the session's yes wins over log=no"
    on; REQ_LOG_SESSION=no; req_log_enabled; assert_eq "1" "$?" "the session's no wins over log=yes"
    REQ_PROJECT_ID=""; REQ_LOG_SESSION=yes; req_log_enabled; assert_eq "1" "$?" "but a project is always needed"
    REQ_LOG_SESSION=""
    off; req_log_write TEST "x"; assert_eq "0" "$?" "writing with the log off is fine"
    [[ ! -e $f ]]; assert_eq "0" "$?" "and creates nothing"
}

test_write() {
    echo "log: lines"
    local f out
    on; f=$(req_log_file); rm -f "$f"
    req_log_write TEST "hello"; assert_eq "0" "$?" "a line is written"
    req_log_write TEST $'a\nb\r\nc'
    assert_eq "2" "$(wc -l <"$f" | tr -d ' ')" "one line per event, even with line breaks in the text"
    out=$(<"$f")
    [[ $out =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\ TEST\ hello$'\n' ]]
    assert_eq "0" "$?" "each starts with an ISO timestamp, the event and the text"
    assert_contains 'TEST a\nb\nc' "$out" "line breaks are written as \\n and carriage returns dropped"
    rm -f "$f"; mkdir "$f"      # a directory where the file should be: unwritable even for root
    out=$(req_log_write TEST "x" 2>&1); assert_eq "1" "$?" "an unwritable log fails"
    rmdir "$f"
    assert_contains "cannot write the log $f" "$out" "with a warning that names the file"
}

test_request() {
    echo "log: the request"
    local f out
    on; f=$(req_log_file); rm -f "$f"
    REQ_P_METHOD=POST; REQ_P_URL="http://x/y?a=1"; REQ_P_HEADERS=("X-A: 1" "X-B: 2")
    REQ_P_FORM=(); REQ_P_RAWSET=1; REQ_BODY=$'{"k":\n"v"}'
    req_log_request "/some/dir/add.post.json" dev
    out=$(<"$f")
    assert_contains ' REQUEST file=add.post.json env=dev POST http://x/y?a=1 | header: X-A: 1 | header: X-B: 2 | body: {"k":\n"v"}' "$out" "file name, environment, method, url, headers and body, on one line"
    rm -f "$f"
    REQ_P_HEADERS=(); REQ_P_FORM=("a=1" "b=two words"); REQ_P_RAWSET=0; REQ_BODY=""
    req_log_request add.post.json default
    out=$(<"$f")
    assert_contains 'POST http://x/y?a=1 | form: a=1 | form: b=two words' "$out" "form fields are logged when there is no raw_data"
    [[ $out != *body:* ]]; assert_eq "0" "$?" "and no body"
    rm -f "$f"; REQ_P_FORM=("a=1"); REQ_P_FILES=("doc=a.txt")
    req_log_request add.post.json default
    assert_contains ' | form: a=1 | file: doc=a.txt' "$(<"$f")" "files are logged as field=path"
    REQ_P_FILES=()
    rm -f "$f"; off; req_log_request add.post.json default
    [[ ! -e $f ]]; assert_eq "0" "$?" "with the log off nothing is written"
}

test_response() {
    echo "log: the response"
    local f out
    on; f=$(req_log_file); rm -f "$f"
    REQ_RESP_STATUS=201; REQ_RESP_CTYPE="application/json"; REQ_RESP_TIMES=(0.001 0.002 0 0.003 0.100 0.150)
    REQ_RESP_BODY=$'{"id":\n7}'
    req_log_response
    out=$(<"$f")
    assert_contains ' RESPONSE status=201 type=application/json total=0.150s | body: {"id":\n7}' "$out" "status, type, total time and the whole body, on one line"
    assert_eq "1" "$(wc -l <"$f" | tr -d ' ')" "one line"
    rm -f "$f"; REQ_RESP_CTYPE=""; REQ_RESP_BODY=""
    req_log_response
    assert_contains 'type=- total=0.150s | body: ' "$(<"$f")" "no Content-Type is a dash, no body is an empty one"
    rm -f "$f"; req_log_failure 7
    assert_contains ' ERROR no response (curl exit code 7)' "$(<"$f")" "a failure is logged with curl's exit code"
    rm -f "$f"; off; req_log_response; req_log_failure 7
    [[ ! -e $f ]]; assert_eq "0" "$?" "with the log off nothing is written"
}

test_limit() {
    echo "log: the line limit"
    local f out i
    on; f=$(req_log_file); rm -f "$f"
    REQ_CONFIG=([log]=yes [log_request_limit]=5)
    for i in 1 2 3; do req_log_write TEST "line $i"; done
    assert_eq "3" "$(wc -l <"$f" | tr -d ' ')" "below the limit nothing is dropped"
    for i in 4 5 6 7 8; do req_log_write TEST "line $i"; done
    assert_eq "5" "$(wc -l <"$f" | tr -d ' ')" "at the limit the log keeps that many lines"
    out=$(<"$f")
    assert_contains "TEST line 8" "$out" "the newest line is kept"
    assert_contains "TEST line 4" "$out" "back to the fifth newest"
    [[ $out != *"line 3"* ]]; assert_eq "0" "$?" "and the oldest are gone"
    assert_eq "" "$(find "$(dirname "$f")" -name 'req.log.*')" "no temporary file is left"
    REQ_CONFIG=([log]=yes [log_request_limit]=0)
    for i in 1 2 3 4 5 6 7 8; do req_log_write TEST "more $i"; done
    assert_eq "13" "$(wc -l <"$f" | tr -d ' ')" "with 0 there is no limit"
    REQ_CONFIG=([log]=yes [log_request_limit]=2)
    req_log_write TEST last
    assert_eq "2" "$(wc -l <"$f" | tr -d ' ')" "a lower limit cuts an existing log at the next write"
    assert_contains "TEST more 8" "$(<"$f")" "keeping the newest"
    REQ_CONFIG=([log]=yes)
    rm -f "$f"; for i in $(seq 1 12); do printf 'x\n' >>"$f"; done
    req_log_write TEST new
    assert_eq "13" "$(wc -l <"$f" | tr -d ' ')" "the default (500) leaves a small log alone"
}

test_follow() {
    echo "log: req log follows the project's log"
    local work=$TMP/follow_work stub=$TMP/follow_stub args=$TMP/follow_args notice=$TMP/follow_notice
    local out id file pid actual want
    mkdir -p "$work" "$stub"
    # A tail made up for the tests: it only records its arguments, so no test follows a file for real.
    cat >"$stub/tail" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$REQ_TEST_TAIL_ARGS"
EOF
    chmod +x "$stub/tail"
    export REQ_TEST_TAIL_ARGS=$args

    out=$(cd "$work" && req_log_follow 2>&1); assert_eq "1" "$?" "no .req in the folder: it fails"
    assert_contains "no .req in $work" "$out" "naming the folder"
    req_project_init "$work"
    out=$(cd "$work" && req_log_follow 2>&1); assert_eq "1" "$?" "a .req that is not registered: it fails"
    assert_contains "$work/.req is not registered yet" "$out" "naming the .req"

    id=$(req_project_create "$work"); file=$(req_project_state_dir "$id" req.log)
    want=$'-n\n200\n-F\n--\n'$file
    printf 'line one\nline two\n' >"$file"
    out=$(cd "$work" && PATH=$stub:$PATH req_log_follow 2>&1); assert_eq "0" "$?" "a registered project with a log: it follows"
    assert_eq "$want" "$(<"$args")" "tail -n 200 -F on the log of the project (-F: the trim replaces the file)"

    # No log yet: a notice, and tail only starts once the file exists.
    rm -f "$file" "$args"
    ( cd "$work" && PATH=$stub:$PATH req_log_follow 2>"$notice" ) &
    pid=$!
    for _ in {1..30}; do [[ -s $notice ]] && break; sleep 0.1; done
    assert_contains "waiting for the log $file" "$(<"$notice")" "no log yet: it says it waits, with the absolute path"
    assert_contains ":config log=yes" "$(<"$notice")" "and how to turn the log on"
    [[ ! -e $args ]]; assert_eq "0" "$?" "tail does not start while there is no file"
    : >"$file"
    for _ in {1..30}; do [[ -s $args ]] && break; sleep 0.1; done
    actual=""; [[ -s $args ]] && actual=$(<"$args")
    assert_eq "$want" "$actual" "when the file appears tail starts with the same arguments"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    out=$(cd "$work" && bash "$ROOT/bin/req" log extra_argument_test 2>&1); assert_eq "1" "$?" "bin/req: an extra argument is a usage error"
    assert_contains "req log" "$out" "which shows the usage, with req log in it"

    if command -v timeout >/dev/null 2>&1; then
        printf 'first line\nsecond line\n' >"$file"
        out=$(cd "$work" && timeout 1 bash "$ROOT/bin/req" log 2>&1)
        assert_contains "second line" "$out" "bin/req with the real tail prints the last lines of the log"
        sleep 0.3
        command -v pgrep >/dev/null 2>&1 && assert_eq "" "$(pgrep -f "tail -n 200 -F -- $file")" "and no tail is left running"
    else
        echo "  skip timeout unavailable"
    fi
}

test_enabled
test_limit
test_write
test_request
test_response
test_follow
test_summary
