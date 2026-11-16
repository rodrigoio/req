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

# fake_editor <path> <sh commands> - an "editor" script that runs the commands on "$1".
fake_editor() { printf '#!/bin/sh\n%s\n' "$2" >"$1"; chmod +x "$1"; }

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
    IN=$'full\nPOST\nhttp://x/a\ny\nthe desc\n1\nX-A: 1\n-Accept\n\npage=2\n\nn\nuser=ann\n\n'; run req_wizard_new "$D"
    assert_eq "0" "$STATUS" "creates a request with optional fields"
    f=$D/full.post.json
    assert_eq "the desc" "$(req_request_get "$f" description)" "description"
    assert_eq '{"Content-Type":"application/json","X-A":"1"}' "$(req_request_get "$f" headers)" "preset plus edits on the headers"
    assert_eq '{"page":"2"}' "$(req_request_get "$f" query)" "query"
    assert_eq '{"user":"ann"}' "$(req_request_get "$f" parameters)" "declining the editor asks for parameters"

    # With a format preset the body is offered in the editor instead of parameters.
    local bin=$TMP/newbin
    mkdir -p "$bin"
    # shellcheck disable=SC2016  # the editor script is run by sh, not expanded here
    fake_editor "$bin/json-ed" 'printf "{\"user\": \"ann\"}\n" >"$1"'
    fresh rawnew
    VISUAL=$bin/json-ed IN=$'rn\nPOST\nhttp://x\ny\n\n1\n\n\ny\n'; export VISUAL; run req_wizard_new "$D"
    f=$D/rn.post.json
    assert_eq "0" "$STATUS" "creates a request with a raw body"
    assert_eq '{"user":"ann"}' "$(jq -c .raw_data "$f")" "the body typed in the editor is stored as raw_data"
    assert_eq '{}' "$(req_request_get "$f" parameters)" "and parameters are not asked for"
    [[ $OUT != *"Parameters:"* ]]; assert_eq "0" "$?" "no parameters prompt"
    assert_eq "0" "$(req_request_check "$f" 2>/dev/null; echo $?)" "the file is valid"

    # shellcheck disable=SC2016
    fake_editor "$bin/text-ed" 'printf "a plain body\n" >"$1"'
    fresh rawtext
    VISUAL=$bin/text-ed IN=$'rt\nPUT\nhttp://x\ny\n\n2\n\n\n\n'; export VISUAL; run req_wizard_new "$D"
    assert_eq "a plain body" "$(jq -r .raw_data "$D/rt.put.json")" "text preset stores the body as text without questions"
    [[ $OUT != *"Not a JSON"* ]]; assert_eq "0" "$?" "no JSON question with the text preset"

    fresh rawempty
    # shellcheck disable=SC2016
    fake_editor "$bin/empty-ed" ': >"$1"'
    VISUAL=$bin/empty-ed IN=$'re\nPOST\nhttp://x\ny\n\n1\n\n\ny\n'; export VISUAL; run req_wizard_new "$D"
    assert_eq "null" "$(jq -c .raw_data "$D/re.post.json")" "an emptied editor stores no raw_data"

    fresh nopreset
    VISUAL=$bin/json-ed IN=$'np\nPOST\nhttp://x\ny\n\n4\n\n\nk=v\n\n'; export VISUAL; run req_wizard_new "$D"
    assert_eq '{"k":"v"}' "$(req_request_get "$D/np.post.json" parameters)" "without a preset the parameters are asked as before"
    assert_eq "null" "$(jq -c .raw_data "$D/np.post.json")" "and there is no raw_data"
    unset VISUAL

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
    assert_contains "choose 1-8, s or q" "$OUT" "an invalid choice is explained"

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

test_raw_data() {
    echo "wizard: raw data"
    fresh raw
    local bin=$TMP/rawbin f
    mkdir -p "$bin"
    req_request_write "$D" base POST http://x '{"raw_data":{"a":1}}' >/dev/null
    f=$D/base.post.json

    assert_eq $'{\n  "a": 1\n}' "$(req_raw_text '{"a":1}')" "an object is shown indented"
    assert_eq $'two\nlines' "$(req_raw_text '"two\nlines"')" "a string is shown as it is"
    assert_eq "" "$(req_raw_text '')" "nothing when there is no value"

    IN=$'q\n'; run req_wizard_edit "$f"
    assert_contains "8) raw data     JSON object, 1 keys" "$OUT" "the menu summarizes raw_data"

    # With an editor: a script that replaces the text, as a user would.
    # shellcheck disable=SC2016  # the editor script is run by sh, not expanded here
    fake_editor "$bin/json-ed" 'printf "{\"user\": \"ann\", \"tags\": [1, 2]}\n" >"$1"'
    VISUAL=$bin/json-ed; export VISUAL
    IN=$'8\ns\n'; run req_wizard_edit "$f"
    assert_eq '{"user":"ann","tags":[1,2]}' "$(jq -c .raw_data "$f")" "valid JSON is stored as native JSON"

    # shellcheck disable=SC2016
    fake_editor "$bin/text-ed" 'printf "plain text\nsecond line\n" >"$1"'
    VISUAL=$bin/text-ed
    IN=$'8\n2\ns\n'; run req_wizard_edit "$f"
    assert_contains "Not a JSON object or list" "$OUT" "text that is not JSON is questioned"
    assert_eq $'plain text\nsecond line' "$(jq -r .raw_data "$f")" "2 keeps it as a string"
    assert_eq "string" "$(jq -r '.raw_data | type' "$f")" "stored as a string"
    assert_contains "text, 22 chars" "$(IN=$'q\n'; run req_wizard_edit "$f"; printf '%s' "$OUT")" "the menu summarizes text"

    IN=$'8\n3\ns\n'; run req_wizard_edit "$f"
    assert_eq $'plain text\nsecond line' "$(jq -r .raw_data "$f")" "3 discards the edit"

    # 1 edits again: the second round sees the first round's text.
    # shellcheck disable=SC2016
    fake_editor "$bin/two-step" 'if [ -e "$0.done" ]; then printf "}" >>"$1"; else printf "{\"fixed\": true" >"$1"; : >"$0.done"; fi'
    VISUAL=$bin/two-step
    IN=$'8\n1\ns\n'; run req_wizard_edit "$f"
    assert_eq '{"fixed":true}' "$(jq -c .raw_data "$f")" "1 opens the editor again on the same text"

    # An emptied text clears the field.
    # shellcheck disable=SC2016
    fake_editor "$bin/empty-ed" ': >"$1"'
    VISUAL=$bin/empty-ed
    IN=$'8\ns\n'; run req_wizard_edit "$f"
    assert_eq "null" "$(jq -c '.raw_data' "$f")" "an empty text removes raw_data"

    # A non-JSON Content-Type does not question free text.
    req_request_write "$D" page POST http://x '{"headers":{"Content-Type":"text/html"}}' >/dev/null
    # shellcheck disable=SC2016
    fake_editor "$bin/html-ed" 'printf "<p>hi</p>\n" >"$1"'
    VISUAL=$bin/html-ed
    IN=$'8\ns\n'; run req_wizard_edit "$D/page.post.json"
    [[ $OUT != *"Not a JSON"* ]]; assert_eq "0" "$?" "no question with a text Content-Type"
    assert_eq "<p>hi</p>" "$(jq -r .raw_data "$D/page.post.json")" "and the text is stored"

    # An editor that fails leaves the field alone.
    # shellcheck disable=SC2016
    fake_editor "$bin/failer" 'echo oops >"$1"; exit 1'
    VISUAL=$bin/failer
    IN=$'8\ns\n'; run req_wizard_edit "$D/page.post.json"
    assert_contains "the editor failed" "$OUT" "an editor failure is reported"
    assert_eq "<p>hi</p>" "$(jq -r .raw_data "$D/page.post.json")" "and raw_data is unchanged"

    # No editor: one prompt line.
    unset VISUAL; EDITOR=''; export EDITOR
    # shellcheck disable=SC2317  # called by req_ask_raw_data
    req_editor() { return 1; }
    IN=$'8\n{"x": [1,2]}\ns\n'; run req_wizard_edit "$f"
    assert_eq '{"x":[1,2]}' "$(jq -c .raw_data "$f")" "without an editor the JSON is typed on one line"
    IN=$'8\n-\ns\n'; run req_wizard_edit "$f"
    assert_eq "null" "$(jq -c .raw_data "$f")" "- clears raw_data"
    IN=$'8\nhello\n2\ns\n'; run req_wizard_edit "$f"
    assert_eq "hello" "$(jq -r .raw_data "$f")" "free text typed on the line is kept as text"
    IN=$'8\n\ns\n'; run req_wizard_edit "$f"
    assert_eq "hello" "$(jq -r .raw_data "$f")" "Enter keeps the default (the current text)"
    unset -f req_editor
    source "$ROOT/lib/core.sh"
    unset EDITOR
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
    run req_wizard_mkdir "$D" "given"; assert_eq "0" "$STATUS" "a name given as argument skips the prompt"
    IN=$'sub-dir\n'; run req_wizard_mkdir "$D" "sub-dir"
    assert_eq "1" "$STATUS" "refuses an existing directory"
    assert_contains "already exists" "$OUT" "says why"
    IN='<EOF>'; run req_wizard_mkdir "$D" "Bad Name"; assert_eq "1" "$STATUS" "refuses an invalid name"
    assert_contains "invalid directory name" "$OUT" "says why"
    IN=$'\n'; run req_wizard_mkdir "$D"; assert_eq "1" "$STATUS" "an empty name cancels"
    IN='<EOF>'; run req_wizard_mkdir "$D"; assert_eq "1" "$STATUS" "end of input cancels"
    assert_eq "2" "$(find "$D" -mindepth 1 | wc -l | tr -d ' ')" "only the two valid directories were created"
}

test_rename_dir() {
    echo "wizard: rename directory"
    fresh rn
    mkdir -p "$D/api/v2" "$D/auth" "$D/taken"
    req_request_write "$D/api" ping GET http://x >/dev/null

    IN=$'service\n'; run req_wizard_rename_dir "$D/api"
    assert_eq "0" "$STATUS" "renames a directory"
    [[ -d $D/service/v2 && -f $D/service/ping.get.json && ! -e $D/api ]]; assert_eq "0" "$?" "the contents move with it"
    assert_eq "$D/service" "$REQ_LAST_DIR" "REQ_LAST_DIR is the new path"
    assert_contains "Renamed $D/api to $D/service" "$OUT" "the result is reported"

    IN=$'\n'; run req_wizard_rename_dir "$D/service"
    assert_eq "1" "$STATUS" "keeping the default name changes nothing"
    assert_contains "Name unchanged" "$OUT" "and says so"
    [[ -d $D/service ]]; assert_eq "0" "$?" "the directory stays"
    assert_contains "[service]" "$OUT" "the prompt offers the current name as default"

    run req_wizard_rename_dir "$D/service" "taken"
    assert_eq "1" "$STATUS" "refuses a name that already exists"
    assert_contains "already exists" "$OUT" "says why"
    run req_wizard_rename_dir "$D/service" "Bad Name"
    assert_eq "1" "$STATUS" "refuses an invalid name"
    assert_contains "invalid directory name" "$OUT" "says why"

    run req_wizard_rename_dir "$D/service/v2" "v3"
    assert_eq "0" "$STATUS" "renames a subdirectory"
    [[ -d $D/service/v3 && ! -e $D/service/v2 ]]; assert_eq "0" "$?" "it moved"

    IN='<EOF>'; run req_wizard_rename_dir "$D/service"
    assert_eq "1" "$STATUS" "end of input cancels"
    run req_wizard_rename_dir "$D/ghost" "x"
    assert_eq "1" "$STATUS" "a missing directory fails"
}

test_copy_dir() {
    echo "wizard: copy directory"
    fresh cp
    mkdir -p "$D/api/v2" "$D/auth"
    req_request_write "$D/api" ping GET http://x >/dev/null
    req_request_write "$D/api/v2" deep POST http://x/d '{"raw_data":{"a":1}}' >/dev/null
    ln -s ping.get.json "$D/api/link.json"

    IN=$'\n'; run req_wizard_copy_dir "$D/api"
    assert_eq "0" "$STATUS" "copies a directory with the default name"
    assert_contains "[api-copy]" "$OUT" "the prompt offers <name>-copy"
    assert_eq "$D/api-copy" "$REQ_LAST_DIR" "REQ_LAST_DIR is the copy"
    [[ -f $D/api-copy/ping.get.json && -f $D/api-copy/v2/deep.post.json ]]; assert_eq "0" "$?" "everything inside is copied, subdirectories too"
    cmp -s "$D/api/v2/deep.post.json" "$D/api-copy/v2/deep.post.json"; assert_eq "0" "$?" "with the same content"
    [[ -f $D/api/ping.get.json && -d $D/api/v2 ]]; assert_eq "0" "$?" "the original is untouched"
    [[ -L $D/api-copy/link.json ]]; assert_eq "0" "$?" "symbolic links are copied as links"
    assert_eq "0" "$(req_request_check "$D/api-copy/ping.get.json" 2>/dev/null; echo $?)" "the copied request is valid"

    IN=$'\nfresh-name\n'; run req_wizard_copy_dir "$D/api"
    assert_eq "0" "$STATUS" "a taken default asks again"
    assert_contains "already exists" "$OUT" "and says why"
    [[ -d $D/fresh-name ]]; assert_eq "0" "$?" "using the new name"

    run req_wizard_copy_dir "$D/auth" "auth-two"
    assert_eq "0" "$STATUS" "a name given as argument skips the prompt"
    run req_wizard_copy_dir "$D/auth" "auth-two"
    assert_eq "1" "$STATUS" "refuses an existing target"
    run req_wizard_copy_dir "$D/auth" "Bad Name"
    assert_eq "1" "$STATUS" "refuses an invalid name"
    assert_contains "invalid directory name" "$OUT" "says why"

    run req_wizard_copy_dir "$D/api/v2" "v3"
    assert_eq "0" "$STATUS" "copies a subdirectory"
    [[ -f $D/api/v3/deep.post.json ]]; assert_eq "0" "$?" "next to the original"

    IN='<EOF>'; run req_wizard_copy_dir "$D/api"
    assert_eq "1" "$STATUS" "end of input cancels"
    run req_wizard_copy_dir "$D/ghost" "x"
    assert_eq "1" "$STATUS" "a missing directory fails"
}

test_copy_request() {
    echo "wizard: copy request"
    fresh cr
    req_request_write "$D" orig POST http://x/o '{"description":"d","headers":{"A":"1"},"raw_data":{"k":[1,2]}}' >/dev/null
    printf '{broken' >"$D/oops.get.json"

    IN=$'\n'; run req_wizard_copy_request "$D/orig.post.json"
    assert_eq "0" "$STATUS" "copies a request with the default name"
    assert_contains "[orig-copy]" "$OUT" "the prompt offers <name>-copy"
    assert_eq "$D/orig-copy.post.json" "$REQ_LAST_FILE" "REQ_LAST_FILE is the copy"
    assert_eq "orig-copy" "$(req_request_get "$D/orig-copy.post.json" name)" "the copy has the new name"
    assert_eq "$(jq -c 'del(.name)' "$D/orig.post.json")" "$(jq -c 'del(.name)' "$D/orig-copy.post.json")" "and every other field is the same"
    assert_contains "Created" "$OUT" "the result is reported"
    [[ $OUT != *"Editing"* ]]; assert_eq "0" "$?" "no edit menu follows"

    IN=$'\nother\n'; run req_wizard_copy_request "$D/orig.post.json"
    assert_contains "already exists" "$OUT" "a taken default asks again"
    [[ -f $D/other.post.json ]]; assert_eq "0" "$?" "using the new name"

    run req_wizard_copy_request "$D/orig.post.json" "given"
    assert_eq "0" "$STATUS" "a name given as argument skips the prompt"
    run req_wizard_copy_request "$D/orig.post.json" "given"
    assert_eq "1" "$STATUS" "refuses an existing target"
    run req_wizard_copy_request "$D/orig.post.json" "Bad Name"
    assert_eq "1" "$STATUS" "refuses an invalid name"
    run req_wizard_copy_request "$D/oops.get.json" "x"
    assert_eq "1" "$STATUS" "refuses an invalid request"
    assert_contains "fix the file first: $D/oops.get.json" "$OUT" "and tells where it is"
    IN='<EOF>'; run req_wizard_copy_request "$D/orig.post.json"
    assert_eq "1" "$STATUS" "end of input cancels"
}

test_remove_request() {
    echo "wizard: remove request"
    fresh rm
    req_request_write "$D" gone GET http://x >/dev/null
    printf '{broken' >"$D/oops.get.json"

    IN=$'\n'; run req_wizard_remove_request "$D/gone.get.json"
    assert_eq "1" "$STATUS" "Enter keeps the request (the default is no)"
    assert_contains "[y/N]" "$OUT" "the prompt shows the default"
    assert_contains "Remove $D/gone.get.json" "$OUT" "shows the full path first"
    [[ -f $D/gone.get.json ]]; assert_eq "0" "$?" "the file is still there"
    IN=$'n\n'; run req_wizard_remove_request "$D/gone.get.json"
    assert_eq "1" "$STATUS" "n keeps it"
    IN='<EOF>'; run req_wizard_remove_request "$D/gone.get.json"
    assert_eq "1" "$STATUS" "end of input keeps it"
    [[ -f $D/gone.get.json ]]; assert_eq "0" "$?" "still there"

    IN=$'y\n'; run req_wizard_remove_request "$D/gone.get.json"
    assert_eq "0" "$STATUS" "y removes it"
    [[ ! -e $D/gone.get.json ]]; assert_eq "0" "$?" "the file is gone"
    assert_eq "$D/gone.get.json" "$REQ_LAST_FILE" "REQ_LAST_FILE is the removed path"

    IN=$'y\n'; run req_wizard_remove_request "$D/oops.get.json"
    assert_eq "0" "$STATUS" "an invalid request can be removed"
    [[ ! -e $D/oops.get.json ]]; assert_eq "0" "$?" "and it is gone"

    run req_wizard_remove_request "$D/ghost.get.json"
    assert_eq "1" "$STATUS" "a missing request fails"
}

test_remove_dir() {
    echo "wizard: remove directory"
    fresh rd
    local ws=$D/ws out before
    mkdir -p "$ws/api/v2" "$ws/auth" "$D/outside/inner"
    req_request_write "$ws/api" ping GET http://x >/dev/null
    req_request_write "$ws/api/v2" deep GET http://x >/dev/null
    printf 'keep' >"$D/outside/precious.txt"

    IN=$'\n'; run req_wizard_remove_dir "$ws/api" "$ws"
    assert_eq "1" "$STATUS" "Enter keeps the directory (the default is no)"
    assert_contains "[y/N]" "$OUT" "the prompt shows the default"
    assert_contains "Remove the directory $ws/api" "$OUT" "the warning has the full path"
    assert_contains "2 files in 1 subdirectories" "$OUT" "and the size of the contents"
    [[ -f $ws/api/v2/deep.get.json ]]; assert_eq "0" "$?" "nothing was removed"
    IN=$'n\n'; run req_wizard_remove_dir "$ws/api" "$ws"; assert_eq "1" "$STATUS" "n keeps it"
    IN='<EOF>'; run req_wizard_remove_dir "$ws/api" "$ws"; assert_eq "1" "$STATUS" "end of input keeps it"
    [[ -d $ws/api ]]; assert_eq "0" "$?" "still there"

    REQ_COLORS=1; IN=$'n\n'; run req_wizard_remove_dir "$ws/api" "$ws"; REQ_COLORS=0
    assert_contains $'\033[31mRemove the directory' "$OUT" "the warning is red"

    IN=$'y\n'; run req_wizard_remove_dir "$ws/api" "$ws"
    assert_eq "0" "$STATUS" "y removes the directory"
    [[ ! -e $ws/api ]]; assert_eq "0" "$?" "with everything inside"
    assert_eq "$ws/api" "$REQ_LAST_DIR" "REQ_LAST_DIR is the directory"
    [[ -d $ws/auth ]]; assert_eq "0" "$?" "other directories are untouched"

    mkdir -p "$ws/auth/sub"; printf 'x' >"$ws/auth/sub/f"
    IN=$'y\n'; run req_wizard_remove_dir "$ws/auth/sub" "$ws"
    assert_eq "0" "$STATUS" "removes a subdirectory"
    [[ ! -e $ws/auth/sub && -d $ws/auth ]]; assert_eq "0" "$?" "only that one"

    # Never outside the workspace: the files stay and nothing is asked.
    IN=$'y\n'; run req_wizard_remove_dir "$D/outside" "$ws"
    assert_eq "1" "$STATUS" "a directory outside the workspace is refused"
    assert_contains "refusing to remove" "$OUT" "with an explanation"
    assert_contains "not a directory inside the workspace" "$OUT" "that names the rule"
    [[ -f $D/outside/precious.txt && -d $D/outside/inner ]]; assert_eq "0" "$?" "its files are safe"
    IN=$'y\n'; run req_wizard_remove_dir "$ws" "$ws"
    assert_eq "1" "$STATUS" "the workspace itself is refused"
    [[ -d $ws/auth ]]; assert_eq "0" "$?" "and is still there"
    IN=$'y\n'; run req_wizard_remove_dir "$D" "$ws"
    assert_eq "1" "$STATUS" "a parent of the workspace is refused"
    [[ -d $ws ]]; assert_eq "0" "$?" "and is still there"
    mkdir -p "$ws/auth/../auth2"
    IN=$'y\n'; run req_wizard_remove_dir "$ws/auth/../../outside" "$ws"
    assert_eq "1" "$STATUS" "a path that climbs out with .. is refused"
    [[ -f $D/outside/precious.txt ]]; assert_eq "0" "$?" "and its files are safe"

    # Symbolic links are never removed, and their target never touched.
    ln -s "$D/outside" "$ws/auth/link"
    IN=$'y\n'; run req_wizard_remove_dir "$ws/auth/link" "$ws"
    assert_eq "1" "$STATUS" "a symbolic link is refused"
    assert_contains "symbolic link" "$OUT" "and the reason is given"
    [[ -f $D/outside/precious.txt && -L $ws/auth/link ]]; assert_eq "0" "$?" "the link and its target stay"
    ln -s "$ws/auth" "$ws/auth-link"
    IN=$'y\n'; run req_wizard_remove_dir "$ws/auth-link" "$ws"
    assert_eq "1" "$STATUS" "a link to a directory inside the workspace is refused too"
    [[ -d $ws/auth && -L $ws/auth-link ]]; assert_eq "0" "$?" "nothing changed"

    run req_wizard_remove_dir "$ws/ghost" "$ws"
    assert_eq "1" "$STATUS" "a missing directory fails"
    run req_wizard_remove_dir "$ws/auth" "$D/no-such-workspace"
    assert_eq "1" "$STATUS" "a missing workspace fails"
    assert_contains "workspace not found" "$OUT" "with a message"
}

test_pairs_and_presets
test_new
test_edit
test_raw_data
test_duplicate
test_mkdir
test_rename_dir
test_copy_dir
test_copy_request
test_remove_request
test_remove_dir
test_summary
