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
    chmod 555 "$TMP/cfg/projects/shop"; chmod 444 "$f"
    out=$(req_log_write TEST "x" 2>&1); assert_eq "1" "$?" "an unwritable log fails"
    chmod 755 "$TMP/cfg/projects/shop"; chmod 644 "$f"
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

test_enabled
test_write
test_request
test_response
test_summary
