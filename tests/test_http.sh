#!/usr/bin/env bash
# Tests for lib/http.sh. The execution ones use tests/mock_server.py (needs python3).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/env.sh"
source "$ROOT/lib/log.sh"
source "$ROOT/lib/http.sh"

TMP=$(mktemp -d)
export REQ_CONFIG_DIR=$TMP/cfg      # never touch the real ~/.req
SERVER_PID=""
cleanup() { [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# has_arg <arg> - succeeds if REQ_CURL_ARGS contains exactly that argument.
has_arg() {
    local a
    for a in "${REQ_CURL_ARGS[@]}"; do [[ $a == "$1" ]] && return 0; done
    return 1
}

test_url() {
    echo "http: url and querystring"
    assert_eq "http://x/a?b=1&c=a%20b" "$(req_build_url '{"url":"http://x/a","query":{"b":1,"c":"a b"}}')" "appends the query with encoding"
    assert_eq "http://x/a?z=9&b=1" "$(req_build_url '{"url":"http://x/a?z=9","query":{"b":1}}')" "uses & when there is already a ?"
    assert_eq "http://x/a" "$(req_build_url '{"url":"http://x/a"}')" "no query"
    local out; out=$(req_build_url '{"method":"GET"}' 2>&1); assert_eq "1" "$?" "a missing url fails"
    assert_contains '"url"' "$out" "error names the url field"
}

test_args() {
    echo "http: curl arguments"
    req_build_curl_args '{"method":"get","url":"http://x","headers":{"X-A":"1","Accept":"text/html"}}'
    has_arg -X && has_arg GET && has_arg "X-A: 1" && has_arg "Accept: text/html" && has_arg http://x
    assert_eq "0" "$?" "method, headers and url"
    assert_eq "" "$REQ_BODY" "GET has no body"

    local m
    for m in GET DELETE; do
        req_build_curl_args "{\"method\":\"$m\",\"url\":\"http://x\",\"parameters\":{\"a\":1},\"headers\":{\"Content-Type\":\"application/json\"}}"
        has_arg --data-urlencode || has_arg --data-binary; assert_eq "1" "$?" "$m sends no body"
        assert_eq "" "$REQ_BODY" "$m has no body on stdin"
    done

    req_build_curl_args '{"method":"PATCH","url":"http://x","parameters":{"a":"@/etc/passwd"}}'
    has_arg -X && has_arg PATCH && has_arg "a=@/etc/passwd"; assert_eq "0" "$?" "PATCH; a value with @ stays literal"

    req_build_curl_args '{"method":"POST","url":"http://x","headers":{"content-type":"application/json"},"parameters":{"a":1,"b":"x"}}'
    has_arg --data-urlencode && has_arg "a=1" && has_arg "b=x"
    assert_eq "0" "$?" "parameters is a form even with a JSON Content-Type"
    assert_eq "" "$REQ_BODY" "and does not use stdin"

    req_build_curl_args '{"method":"PUT","url":"http://x","parameters":{"a":1,"b":"x y"}}'
    has_arg --data-urlencode && has_arg "a=1" && has_arg "b=x y"
    assert_eq "0" "$?" "parameters becomes a form"
    assert_eq "" "$REQ_BODY" "a form does not use stdin"

    # raw_data: object, list or string; wins over parameters.
    req_build_curl_args '{"method":"POST","url":"http://x","raw_data":{"a":[1,2],"b":"x"},"parameters":{"p":1}}'
    assert_eq '{"a":[1,2],"b":"x"}' "$REQ_BODY" "an object raw_data is the body, as compact JSON"
    has_arg --data-binary && has_arg "Content-Type: application/json"; assert_eq "0" "$?" "JSON without a Content-Type is sent as application/json"
    has_arg --data-urlencode; assert_eq "1" "$?" "raw_data takes precedence over parameters"
    req_build_curl_args '{"method":"PUT","url":"http://x","raw_data":[1,{"a":2}]}'
    assert_eq '[1,{"a":2}]' "$REQ_BODY" "a list raw_data is the body"
    req_build_curl_args '{"method":"POST","url":"http://x","headers":{"content-type":"application/vnd.api+json"},"raw_data":{"a":1}}'
    has_arg "Content-Type: application/json"; assert_eq "1" "$?" "an existing Content-Type is kept (no extra header)"
    req_build_curl_args '{"method":"PATCH","url":"http://x","raw_data":"line 1\nline 2\n"}'
    assert_eq $'line 1\nline 2\n' "$REQ_BODY" "a string raw_data is sent as it is"
    has_arg "Content-Type:" && ! has_arg "Content-Type: application/json"; assert_eq "0" "$?" "free text gets no automatic Content-Type"
    req_build_curl_args '{"method":"POST","url":"http://x","headers":{"Content-Type":"text/plain"},"raw_data":"hi"}'
    has_arg "Content-Type:"; assert_eq "1" "$?" "free text with its own Content-Type adds nothing"
    req_build_curl_args '{"method":"POST","url":"http://x","raw_data":"","parameters":{"p":"1"}}'
    has_arg --data-urlencode && has_arg "p=1"; assert_eq "0" "$?" "an empty raw_data falls back to parameters"
    req_build_curl_args '{"method":"GET","url":"http://x","raw_data":{"a":1}}'
    has_arg --data-binary; assert_eq "1" "$?" "GET sends no raw_data"
}

test_timing() {
    echo "http: timing stages"
    assert_eq $'DNS\t10\nTCP\t20\nTLS\t30\nWait\t100\nDownload\t40\nTotal\t200' \
        "$(req_timing_stages 0.010 0.030 0.060 0.060 0.160 0.200)" "stages of a secure connection"
    assert_eq $'DNS\t5\nTCP\t5\nWait\t90\nDownload\t10\nTotal\t110' \
        "$(req_timing_stages 0.005 0.010 0.000 0.010 0.100 0.110)" "no TLS over http"
    assert_eq $'DNS\t0\nTCP\t0\nWait\t0\nDownload\t0\nTotal\t0' \
        "$(req_timing_stages 0 0 0 0 0 0)" "all zero"
}

test_print() {
    echo "http: display"
    local out
    out=$(req_print_body application/json '{"a":1}'); assert_eq $'{\n  "a": 1\n}' "$out" "indented JSON"
    out=$(req_print_body text/plain 'hello'); assert_eq "hello" "$out" "raw text"
    out=$(req_print_body text/html '<h1>x</h1>'); assert_eq "<h1>x</h1>" "$out" "raw HTML"
    out=$(req_print_body application/json '{broken'); assert_eq "{broken" "$out" "invalid JSON comes out raw"
    out=$(req_print_body text/plain ''); assert_eq "(no body)" "$out" "empty body"
    out=$(COLUMNS=10 req_rule '='); assert_eq "==========" "$out" "line as wide as the terminal"
    out=$(COLUMNS=5 req_rule -); assert_eq "-----" "$out" "line with another character"

    REQ_RESP_TIMES=(0.010 0.030 0 0.030 0.130 0.150)
    out=$(LC_ALL=C req_print_profile)
    assert_contains "DNS" "$out" "profile lists DNS"
    assert_contains "Wait" "$out" "profile lists the wait"
    assert_contains "150 ms" "$out" "profile shows the total"
    [[ $out != *TLS* ]]; assert_eq "0" "$?" "profile omits TLS over http"
    assert_contains "#" "$out" "ASCII bar outside UTF-8"

    REQ_CONFIG=([time_stats]=no)
    out=$(LC_ALL=C req_print_profile)
    assert_contains "Timing" "$out" "time_stats=no keeps the title"
    assert_contains "150 ms" "$out" "and the total line"
    [[ $out != *DNS* && $out != *Wait* && $out != *"#"* ]]; assert_eq "0" "$?" "but drops the stages and their bars"
    REQ_CONFIG=([time_stat_total]=no)
    out=$(LC_ALL=C req_print_profile)
    assert_contains "Wait" "$out" "time_stat_total=no keeps the stages"
    [[ $out != *Total* && $out != *"150 ms"* ]]; assert_eq "0" "$?" "but drops the total line"
    REQ_CONFIG=([time_stats]=no [time_stat_total]=no)
    out=$(LC_ALL=C req_print_profile)
    assert_eq "" "$out" "with both off nothing is printed"
    REQ_CONFIG=()
    out=$(LC_ALL=C req_print_profile)
    assert_contains "Total" "$out" "by default everything is shown"
}

start_server() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I "$ROOT/tests/mock_server.py" >"$TMP/port" 2>/dev/null &
    SERVER_PID=$!
    for _ in {1..50}; do
        [[ -s $TMP/port ]] && { PORT=$(<"$TMP/port"); return 0; }
        sleep 0.1
    done
    return 1
}

test_execute() {
    echo "http: execution (local mock)"
    if ! start_server; then
        echo "  skip python3 unavailable or the server did not start"
        return
    fi
    local base=http://127.0.0.1:$PORT out

    req_execute "{\"method\":\"GET\",\"url\":\"$base/x\",\"query\":{\"q\":\"a b\"},\"headers\":{\"X-Test\":\"ola\"}}"
    assert_eq "0" "$?" "GET runs"
    assert_eq "200" "$REQ_RESP_STATUS" "status 200"
    assert_eq "application/json" "$REQ_RESP_CTYPE" "content-type"
    assert_eq "GET" "$(jq -r .method <<<"$REQ_RESP_BODY")" "method reached the server"
    assert_eq "a b" "$(jq -r '.query.q[0]' <<<"$REQ_RESP_BODY")" "querystring arrived decoded"
    assert_eq "ola" "$(jq -r .x_test <<<"$REQ_RESP_BODY")" "header arrived"
    assert_eq "6" "${#REQ_RESP_TIMES[@]}" "six timings captured"

    req_execute "{\"method\":\"POST\",\"url\":\"$base/p\",\"raw_data\":{\"a\":1}}"
    assert_eq '{"a":1}' "$(jq -r .body <<<"$REQ_RESP_BODY")" "POST with a JSON raw_data"
    assert_eq "application/json" "$(jq -r .content_type <<<"$REQ_RESP_BODY")" "the JSON content-type arrived"

    req_execute "{\"method\":\"POST\",\"url\":\"$base/p\",\"raw_data\":\"a=1&b\"}"
    assert_eq 'a=1&b' "$(jq -r .body <<<"$REQ_RESP_BODY")" "POST with a text raw_data"
    assert_eq "" "$(jq -r '.content_type // ""' <<<"$REQ_RESP_BODY")" "free text arrives without a content-type"

    req_execute "{\"method\":\"PUT\",\"url\":\"$base/p\",\"parameters\":{\"k\":\"v 1\"}}"
    # curl versions differ: a space comes out as %20 or +; both are valid.
    out=$(jq -r .body <<<"$REQ_RESP_BODY")
    [[ $out == "k=v%201" || $out == "k=v+1" ]]; assert_eq "0" "$?" "PUT with an url-encoded form"
    assert_contains "x-www-form-urlencoded" "$(jq -r .content_type <<<"$REQ_RESP_BODY")" "form content-type"

    req_execute "{\"method\":\"PATCH\",\"url\":\"$base/p\",\"parameters\":{\"f\":\"@/etc/hostname\"}}"
    assert_eq "PATCH" "$(jq -r .method <<<"$REQ_RESP_BODY")" "PATCH reaches the server"
    out=$(jq -r .body <<<"$REQ_RESP_BODY")
    [[ $out == f=%40* ]]; assert_eq "0" "$?" "@ in a value is sent literally, without reading a file"

    req_execute "{\"method\":\"DELETE\",\"url\":\"$base/d\",\"parameters\":{\"a\":1}}"
    assert_eq "DELETE" "$(jq -r .method <<<"$REQ_RESP_BODY")" "DELETE reaches the server"
    assert_eq "" "$(jq -r .body <<<"$REQ_RESP_BODY")" "DELETE sends no body"

    req_execute "{\"method\":\"DELETE\",\"url\":\"$base/status/404\"}"
    assert_eq "404" "$REQ_RESP_STATUS" "DELETE with status 404"

    req_execute "{\"method\":\"GET\",\"url\":\"$base/empty\"}"
    assert_eq "204" "$REQ_RESP_STATUS" "204"; assert_eq "" "$REQ_RESP_BODY" "no body"

    req_execute '{"method":"GET","url":"http://127.0.0.1:1/"}' 2>/dev/null
    assert_eq "7" "$?" "connection refused returns curl's exit code"

    echo "http: req_run_request"
    req_request_write "$TMP" users GET "$base/text" >/dev/null
    out=$(NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/users.get.json" 2>&1)
    assert_eq "0" "$?" "run finishes successfully"
    assert_contains "GET $base/text" "$out" "shows method and url"
    assert_contains "HTTP 200" "$out" "shows the status"
    assert_contains "hello text" "$out" "shows the body"
    assert_contains "Timing" "$out" "shows the profile"
    assert_eq "====================" "$(tail -n 1 <<<"$out")" "ends with a separator"
    REQ_CONFIG=([time_stats]=no [time_stat_total]=no)
    out=$(NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/users.get.json" 2>&1)
    [[ $out != *Timing* ]]; assert_eq "0" "$?" "with both settings off the run shows no profile"
    assert_contains "hello text" "$out" "but still the response"
    REQ_CONFIG=()
    assert_eq "" "$(find "$TMP" -newer "$TMP/port" -type f ! -name 'users.get.json' ! -name 'port')" "no extra file written"

    # ${key} placeholders: the environment is REQ_ENV, "default" when it is not set.
    # shellcheck disable=SC2016  # the placeholders are single-quoted on purpose
    printf '{"name":"sub","method":"POST","url":"${base}/echo","headers":{"X-Test":"${tok}"},"raw_data":{"who":"${tok}"}}\n' >"$TMP/sub.post.json"
    export DEFAULT_BASE=$base DEFAULT_TOK=s3cret
    out=$(NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/sub.post.json" 2>&1)
    assert_eq "0" "$?" "a request with placeholders runs"
    assert_contains "POST $base/echo" "$out" "the url shown is the substituted one"
    assert_contains '"x_test": "s3cret"' "$out" "the header the server received was substituted"
    assert_contains '{\"who\":\"s3cret\"}' "$out" "and so was the body the server received"
    unset DEFAULT_TOK
    out=$(NO_COLOR=1 req_run_request "$TMP/sub.post.json" 2>&1); assert_eq "1" "$?" "a missing key stops the request"
    assert_contains "no value for tok in environment \"default\"" "$out" "the error names the key and the environment"
    assert_contains "DEFAULT_TOK" "$out" "and the variable that would define it"
    [[ $out != *HTTP* ]]; assert_eq "0" "$?" "and nothing was sent"
    REQ_ENV=staging; export STAGING_BASE=$base STAGING_TOK=t2
    out=$(NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/sub.post.json" 2>&1)
    assert_contains '"x_test": "t2"' "$out" "REQ_ENV chooses the environment"
    unset REQ_ENV STAGING_BASE STAGING_TOK DEFAULT_BASE

    # The log: only when log=yes and a project is open; the request is written before it is sent.
    local lid=logproj logf=$TMP/cfgdir/projects/logproj/req.log
    mkdir -p "$TMP/cfgdir/projects/$lid"
    local saved_cfg=${REQ_CONFIG_DIR-}
    export REQ_CONFIG_DIR=$TMP/cfgdir
    export DEFAULT_BASE=$base DEFAULT_TOK=s3cret
    REQ_PROJECT_ID=$lid; REQ_CONFIG=([log]=yes)
    NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/sub.post.json" >/dev/null 2>&1
    assert_eq "2" "$(wc -l <"$logf" | tr -d ' ')" "log=yes: a run writes the request and the response"
    assert_contains "REQUEST file=sub.post.json env=default POST $base/echo | header: X-Test: s3cret" "$(<"$logf")" "with the substituted values"
    assert_contains 'body: {"who":"s3cret"}' "$(<"$logf")" "and the body"
    assert_contains " RESPONSE status=200 type=application/json" "$(sed -n 2p "$logf")" "on the next line, with the status and type"
    unset DEFAULT_TOK
    NO_COLOR=1 req_run_request "$TMP/sub.post.json" >/dev/null 2>&1
    assert_eq "2" "$(wc -l <"$logf" | tr -d ' ')" "a request stopped by a missing key is not logged"
    export DEFAULT_TOK=s3cret
    REQ_CONFIG=([log]=no)
    NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/sub.post.json" >/dev/null 2>&1
    assert_eq "2" "$(wc -l <"$logf" | tr -d ' ')" "log=no: nothing more is written"
    REQ_CONFIG=([log]=yes)
    printf '{"name":"down","method":"GET","url":"http://127.0.0.1:1/x"}\n' >"$TMP/down.get.json"
    NO_COLOR=1 req_run_request "$TMP/down.get.json" >/dev/null 2>&1
    assert_eq "4" "$(wc -l <"$logf" | tr -d ' ')" "a request with no answer logs the request and the failure"
    assert_contains " ERROR no response (curl exit code 7)" "$(sed -n 4p "$logf")" "with curl's exit code"
    REQ_PROJECT_ID=""; REQ_CONFIG=()
    unset DEFAULT_BASE DEFAULT_TOK
    if [[ -n $saved_cfg ]]; then export REQ_CONFIG_DIR=$saved_cfg; else unset REQ_CONFIG_DIR; fi

    printf '{"name":"nourl","method":"GET"}\n' >"$TMP/nourl.get.json"
    out=$(req_run_request "$TMP/nourl.get.json" 2>&1); assert_eq "1" "$?" "a request without a url fails"
    assert_contains '"url"' "$out" "tells how to set the url"
    out=$(req_run_request "$TMP/missing.get.json" 2>&1); assert_eq "1" "$?" "a missing file fails"
}

test_url
test_args
test_timing
test_print
test_execute
test_summary
