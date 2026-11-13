#!/usr/bin/env bash
# Tests for lib/wizard.sh. Answers are fed through fd 3 (REQ_INPUT_FD).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/wizard.sh"

REQ_INPUT_FD=3
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run <function> <args...> - runs a wizard function with $IN as its answers (or at end of
# input when it is <EOF>); the
# combined output ends up in $OUT and the status in $STATUS.
run() {
    if [[ $IN == "<EOF>" ]]; then
        "$@" 3</dev/null >"$TMP/out" 2>&1
    else
        "$@" 3<<<"$IN" >"$TMP/out" 2>&1
    fi
    STATUS=$?
    OUT=$(<"$TMP/out")
}

fresh() { D=$TMP/$1; rm -rf "$D"; mkdir -p "$D"; }

test_pairs_and_presets() {
    echo "wizard: helpers"
    assert_eq '{"Content-Type":"application/json","Accept":"application/json"}' "$(req_preset_headers json)" "json preset"
    assert_eq '{"Content-Type":"text/plain","Accept":"text/plain"}' "$(req_preset_headers text)" "text preset"
    assert_eq '{"Content-Type":"text/html","Accept":"text/html"}' "$(req_preset_headers html)" "html preset"
    assert_eq '{}' "$(req_preset_headers none)" "no preset"

    IN=$'3\n'; run req_ask_preset
    assert_eq "0" "$STATUS" "preset by number"
    IN=$'3\n'; req_ask_preset 3<<<"$IN" >/dev/null; assert_eq '{"Content-Type":"text/html","Accept":"text/html"}' "$REQ_REPLY_JSON" "html chosen by number"
    req_ask_preset 3<<<$'x\nJSON\n' >/dev/null 2>&1; assert_eq '{"Content-Type":"application/json","Accept":"application/json"}' "$REQ_REPLY_JSON" "retries, then accepts a name"
    req_ask_preset 3<<<$'\n' >/dev/null; assert_eq '{}' "$REQ_REPLY_JSON" "Enter picks none"

    req_ask_pairs "Headers" ":" '{"A":"1","B":"2"}' 3<<<$'C: 3\n-A\nbad line\n: x\nD:   spaced value  \n\n' >"$TMP/out" 2>&1
    assert_eq '{"B":"2","C":"3","D":"spaced value"}' "$REQ_REPLY_JSON" "sets, removes and trims entries"
    assert_contains "expected key:value" "$(<"$TMP/out")" "reports a line without a separator"
    assert_contains "key cannot be empty" "$(<"$TMP/out")" "reports an empty key"
    req_ask_pairs "Query" "=" '{}' 3<<<$'a=b=c\n\n' >/dev/null
    assert_eq '{"a":"b=c"}' "$REQ_REPLY_JSON" "splits at the first separator only"
    req_ask_pairs "Query" "=" '{"x":"1"}' 3</dev/null >/dev/null
    assert_eq '{"x":"1"}' "$REQ_REPLY_JSON" "end of input keeps what exists"
}

test_new() {
    echo "wizard: new request"
    fresh new
    IN=$'my-req\npost\nhttp://x/a\nn\n'; run req_wizard_new "$D"
    assert_eq "0" "$STATUS" "creates a minimal request"
    assert_contains "Created $D/my-req.post.json" "$OUT" "reports the created file"
    assert_eq "0" "$(req_request_check "$D/my-req.post.json" 2>/dev/null; echo $?)" "the file is valid"
    assert_eq "POST" "$(req_request_get "$D/my-req.post.json" method)" "method normalized"
    assert_eq "$D/my-req.post.json" "$REQ_LAST_FILE" "REQ_LAST_FILE points to it"

    fresh full
    IN=$'full\nPOST\nhttp://x/a\ny\nthe desc\n1\nX-A: 1\n-Accept\n\npage=2\n\nuser=ann\n\n'; run req_wizard_new "$D"
    assert_eq "0" "$STATUS" "creates a request with optional fields"
    f=$D/full.post.json
    assert_eq "the desc" "$(req_request_get "$f" description)" "description"
    assert_eq '{"Content-Type":"application/json","X-A":"1"}' "$(req_request_get "$f" headers)" "preset plus edits on the headers"
    assert_eq '{"page":"2"}' "$(req_request_get "$f" query)" "query"
    assert_eq '{"user":"ann"}' "$(req_request_get "$f" parameters)" "parameters"

    fresh get
    IN=$'g\nGET\nhttp://x\ny\n\n4\n\n\n'; run req_wizard_new "$D"
    [[ $OUT != *"Parameters:"* ]]; assert_eq "0" "$?" "GET does not ask for parameters"
    assert_eq "0" "$STATUS" "GET with optional fields"

    fresh retry
    IN=$'Bad Name\nok-name\nnope\nget\n\nhttp://x\nn\n'; run req_wizard_new "$D"
    assert_eq "0" "$STATUS" "retries invalid answers"
    assert_contains "invalid name" "$OUT" "explains the invalid name"
    assert_contains "invalid method: nope" "$OUT" "explains the invalid method"
    assert_contains "the url is required" "$OUT" "explains the missing url"
    [[ -f $D/ok-name.get.json ]]; assert_eq "0" "$?" "creates it with the corrected answers"

    IN=$'ok-name\nGET\n'; run req_wizard_new "$D"
    assert_eq "1" "$STATUS" "refuses to overwrite"
    assert_contains "already exists" "$OUT" "says why"

    fresh cancel
    IN=$'\n'; run req_wizard_new "$D"
    assert_eq "1" "$STATUS" "an empty name cancels"
    assert_contains "Cancelled." "$OUT" "says it was cancelled"
    IN='<EOF>'; run req_wizard_new "$D"; assert_eq "1" "$STATUS" "end of input cancels"
    assert_eq "" "$(ls -A "$D")" "nothing was created"

    fresh badheader
    IN=$'bh\nGET\nhttp://x\ny\n\n4\nBad Name: 1\n\n\n'; run req_wizard_new "$D"
    assert_eq "1" "$STATUS" "an invalid header is rejected on write"
    assert_contains "invalid name" "$OUT" "explains the invalid header"
    assert_eq "" "$(ls -A "$D")" "nothing is written then"
}

test_edit() {
    echo "wizard: edit request"
    fresh edit
    req_request_write "$D" base GET http://x '{"description":"old","headers":{"A":"1"}}' >/dev/null
    f=$D/base.get.json
    before=$(<"$f")

    IN=$'q\n'; run req_wizard_edit "$f"
    assert_eq "1" "$STATUS" "q cancels"
    assert_eq "$before" "$(<"$f")" "cancelling leaves the file untouched"
    assert_contains "1) name         base" "$OUT" "shows the fields"
    assert_contains "5) headers      1 entry" "$OUT" "shows entry counts"

    IN=$'9\nq\n'; run req_wizard_edit "$f"
    assert_contains "choose 1-7, s or q" "$OUT" "an invalid choice is explained"

    IN=$'1\nnew-name\n2\nput\n3\nhttp://y\n4\nhello\n5\nX-B: 2\n-A\n\n6\nq=1\n\n7\nk=v\n\ns\n'; run req_wizard_edit "$f"
    assert_eq "0" "$STATUS" "edits and saves"
    n=$D/new-name.put.json
    [[ -f $n && ! -e $f ]]; assert_eq "0" "$?" "renaming moves the file"
    assert_eq "$n" "$REQ_LAST_FILE" "REQ_LAST_FILE points to the new file"
    assert_eq "new-name" "$(req_request_get "$n" name)" "name"
    assert_eq "PUT" "$(req_request_get "$n" method)" "method"
    assert_eq "http://y" "$(req_request_get "$n" url)" "url"
    assert_eq "hello" "$(req_request_get "$n" description)" "description"
    assert_eq '{"X-B":"2"}' "$(req_request_get "$n" headers)" "headers"
    assert_eq '{"q":"1"}' "$(req_request_get "$n" query)" "query"
    assert_eq '{"k":"v"}' "$(req_request_get "$n" parameters)" "parameters"
    assert_eq "0" "$(req_request_check "$n" 2>/dev/null; echo $?)" "the edited file is valid"

    IN=$'4\n-\ns\n'; run req_wizard_edit "$n"
    assert_eq "" "$(req_request_get "$n" description)" "- clears the description"

    req_request_write "$D" taken PUT http://z >/dev/null
    IN=$'1\ntaken\ns\nq\n'; run req_wizard_edit "$n"
    assert_contains "already exists" "$OUT" "a rename onto an existing file is refused"
    [[ -f $n ]]; assert_eq "0" "$?" "the original stays"

    printf '{broken' >"$D/oops.get.json"
    IN=$'q\n'; run req_wizard_edit "$D/oops.get.json"
    assert_eq "1" "$STATUS" "refuses to edit an invalid request"
    assert_contains "fix the file first: $D/oops.get.json" "$OUT" "tells what to do and where the file is"
    assert_eq "{broken" "$(<"$D/oops.get.json")" "the invalid file is not touched"

    IN='<EOF>'; run req_wizard_edit "$n"; assert_eq "1" "$STATUS" "end of input cancels"
}

test_duplicate() {
    echo "wizard: duplicate request"
    fresh dup
    req_request_write "$D" orig POST http://x '{"description":"d","parameters":{"a":"1"}}' >/dev/null
    f=$D/orig.post.json
    IN=$'copy-one\ns\n'; run req_wizard_duplicate "$f"
    assert_eq "0" "$STATUS" "duplicates and saves"
    c=$D/copy-one.post.json
    [[ -f $c && -f $f ]]; assert_eq "0" "$?" "both files exist"
    assert_eq "copy-one" "$(req_request_get "$c" name)" "the copy has the new name"
    assert_eq '{"a":"1"}' "$(req_request_get "$c" parameters)" "the copy keeps the fields"
    assert_eq "POST" "$(req_request_get "$c" method)" "the copy keeps the method"
    assert_contains "Editing copy-one.post.json" "$OUT" "starts the edit menu on the copy"

    IN=$'\nq\n'; run req_wizard_duplicate "$f"
    [[ -f $D/orig-copy.post.json ]]; assert_eq "0" "$?" "Enter accepts <name>-copy"
    assert_eq "$D/orig-copy.post.json" "$REQ_LAST_FILE" "cancelling the edit keeps the copy"

    IN=$'copy-one\ncopy-two\nq\n'; run req_wizard_duplicate "$f"
    assert_contains "already exists" "$OUT" "a taken name is refused"
    [[ -f $D/copy-two.post.json ]]; assert_eq "0" "$?" "then asks again"

    fresh dup2; req_request_write "$D" a GET http://x >/dev/null
    IN='<EOF>'; run req_wizard_duplicate "$D/a.get.json"; assert_eq "1" "$STATUS" "end of input cancels"
    printf '{x' >"$D/b.get.json"
    IN=$'x\n'; run req_wizard_duplicate "$D/b.get.json"; assert_eq "1" "$STATUS" "refuses to duplicate an invalid request"
}

test_mkdir() {
    echo "wizard: new directory"
    fresh mk
    IN=$'sub-dir\n'; run req_wizard_mkdir "$D"
    assert_eq "0" "$STATUS" "creates a subdirectory"
    [[ -d $D/sub-dir ]]; assert_eq "0" "$?" "the directory exists"
    assert_eq "$D/sub-dir" "$REQ_LAST_DIR" "REQ_LAST_DIR points to it"
    run req_wizard_mkdir "$D" "" "given"; assert_eq "0" "$STATUS" "a name given as argument skips the prompt"
    IN=$'sub-dir\n'; run req_wizard_mkdir "$D" "" "sub-dir"
    assert_eq "1" "$STATUS" "refuses an existing directory"
    assert_contains "already exists" "$OUT" "says why"
    IN='<EOF>'; run req_wizard_mkdir "$D" "" "Bad Name"; assert_eq "1" "$STATUS" "refuses an invalid name"
    IN=$'\n'; run req_wizard_mkdir "$D"; assert_eq "1" "$STATUS" "an empty name cancels"

    printf '# project\napi' >"$D/.req"; mkdir "$D/api"
    IN=$'auth\n'; run req_wizard_mkdir "$D" "$D/.req"
    assert_eq "0" "$STATUS" "creates a project directory"
    assert_eq $'# project\napi\nauth' "$(<"$D/.req")" "lists it in the .req (even without a trailing newline)"
    assert_eq "$D/api"$'\n'"$D/auth" "$(req_project_dirs "$D/.req")" "the .req parses"
    IN='<EOF>'; run req_wizard_mkdir "$D" "$D/.req" "auth"
    assert_eq "1" "$STATUS" "refuses a directory that is already listed"
    assert_contains "already listed" "$OUT" "says why"
    assert_eq "$D/auth" "$REQ_LAST_DIR" "REQ_LAST_DIR is still the last created one"
}

test_pairs_and_presets
test_new
test_edit
test_duplicate
test_mkdir
test_summary
