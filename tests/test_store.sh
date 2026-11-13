#!/usr/bin/env bash
# Tests for lib/store.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check_out <file> - output (stderr) of req_request_check.
check_out() { req_request_check "$1" 2>&1; }

test_names() {
    echo "store: names and files"
    assert_eq "login.post.json" "$(req_request_filename login POST)" "file name with lowercase method"
    assert_eq "list-users.patch.json" "$(req_request_filename list-users PATCH)" "slug with hyphen and PATCH"
    assert_eq $'login\tPOST' "$(req_parse_filename /x/login.post.json)" "extracts name and method"
    assert_eq $'api-v2\tPATCH' "$(req_parse_filename api-v2.patch.json)" "slug with a digit"
    req_parse_filename notes.json >/dev/null;        assert_eq "1" "$?" "rejects a file without a method"
    req_parse_filename x.head.json >/dev/null;       assert_eq "1" "$?" "rejects an unsupported method"
    req_parse_filename .get.json >/dev/null;         assert_eq "1" "$?" "rejects an empty name"
    req_parse_filename Login.get.json >/dev/null;    assert_eq "1" "$?" "rejects uppercase"
    req_parse_filename api.v2.get.json >/dev/null;   assert_eq "1" "$?" "rejects a dot in the name"
    req_parse_filename my_name.get.json >/dev/null;  assert_eq "1" "$?" "rejects an underscore"
    local n
    for n in "a/b" ".x" "-x" "x-" "a--b" "A" "a b" ""; do
        req_valid_name "$n"; assert_eq "1" "$?" "invalid slug: \"$n\""
    done
    for n in ok a1 list-users v2-login; do
        req_valid_name "$n"; assert_eq "0" "$?" "valid slug: \"$n\""
    done
    for n in GET post Put patch DELETE; do
        req_valid_method "$n"; assert_eq "0" "$?" "valid method: $n"
    done
}

test_write_read() {
    echo "store: writing and reading"
    local d=$TMP/w out
    mkdir -p "$d"
    out=$(req_request_write "$d" users GET http://x/users)
    assert_eq "$d/users.get.json" "$out" "returns the created path"
    assert_eq "0" "$(check_out "$d/users.get.json"; echo $?)" "generated request is valid"
    assert_eq "GET" "$(req_request_get "$d/users.get.json" method)" "reads method"
    assert_eq "users" "$(req_request_get "$d/users.get.json" name)" "reads name"
    assert_eq "http://x/users" "$(req_request_get "$d/users.get.json" url)" "reads url"
    assert_eq "" "$(req_request_get "$d/users.get.json" description)" "empty description"
    assert_eq "{}" "$(req_request_get "$d/users.get.json" headers)" "empty headers"

    req_request_write "$d" create-user patch http://x/u \
        '{"description":"updates","headers":{"Content-Type":"application/json","X-N":5},"parameters":{"a":1,"b":true}}' >/dev/null
    assert_eq "PATCH" "$(req_request_get "$d/create-user.patch.json" method)" "method normalized to uppercase"
    assert_eq "updates" "$(req_request_get "$d/create-user.patch.json" description)" "writes description"
    assert_eq '{"Content-Type":"application/json","X-N":5}' "$(req_request_get "$d/create-user.patch.json" headers)" "writes headers"
    assert_eq '{"a":1,"b":true}' "$(req_request_get "$d/create-user.patch.json" parameters)" "writes parameters"
    assert_eq "" "$(compgen -G "$d/.req.*")" "no temporary files left"

    req_request_write "$d" ordered PUT http://x '{"parameters":{"a":"1"},"description":"d"}' >/dev/null
    assert_eq '["name","method","url"]' "$(jq -c 'keys_unsorted[0:3]' "$d/ordered.put.json")" "name, method and url come first in the file"
    out=$(req_request_write "$d" x GET http://x '{"name":"other","url":"http://other"}' 2>&1)
    assert_eq "http://x" "$(req_request_get "$d/x.get.json" url)" "arguments win over the json"
    assert_eq "x" "$(req_request_get "$d/x.get.json" name)" "name follows the argument"

    out=$(req_request_write "$d" bad GET http://x '{oops' 2>&1); assert_eq "1" "$?" "invalid JSON is not written"
    assert_contains "invalid" "$out" "error says the JSON is invalid"
    [[ ! -e $d/bad.get.json ]]; assert_eq "0" "$?" "file was not created"

    out=$(req_request_write "$d" bad2 GET http://x '{"headers":{"X":[1]}}' 2>&1)
    assert_eq "1" "$?" "a wrong type is not written"
    assert_contains "header \"X\"" "$out" "error names the header"
    [[ ! -e $d/bad2.get.json ]]; assert_eq "0" "$?" "invalid file was not created"
    assert_eq "" "$(compgen -G "$d/.req.*")" "no temporary files after a failure"

    out=$(req_request_write "$d" "My Name" GET http://x 2>&1);  assert_eq "1" "$?" "a name outside the slug format is refused"
    assert_contains "slug" "$out" "error mentions the slug"
    req_request_write "$d" x HEAD http://x >/dev/null 2>&1;     assert_eq "1" "$?" "an invalid method is refused"
    out=$(req_request_write "$d" x GET "" 2>&1);                assert_eq "1" "$?" "an empty url is refused"
    assert_contains "url" "$out" "error mentions the url"
    req_request_write "$TMP/missing" x GET http://x >/dev/null 2>&1; assert_eq "1" "$?" "a missing directory is refused"
}

test_invalid_manual() {
    echo "store: manually edited JSON"
    local d=$TMP/m out before after v
    mkdir -p "$d"
    printf '{"name": "a" "method": "GET"}\n' >"$d/a.get.json"
    before=$(cat "$d/a.get.json")
    out=$(check_out "$d/a.get.json"); assert_eq "1" "$(req_request_check "$d/a.get.json" 2>/dev/null; echo $?)" "invalid syntax fails"
    assert_contains "a.get.json" "$out" "error names the file"
    assert_contains "invalid JSON" "$out" "error says invalid JSON"
    after=$(cat "$d/a.get.json")
    assert_eq "$before" "$after" "file was not changed"

    out=$(cd "$d" && req_request_check a.get.json 2>&1)
    assert_contains "req: error: $d/a.get.json: invalid JSON" "$out" "a relative path is reported as an absolute one"

    printf '{"name":"b","method":"GET","url":"http://x","headers":[],"query":"x"}\n' >"$d/b.get.json"
    out=$(check_out "$d/b.get.json")
    assert_contains 'field "headers" must be an object' "$out" "headers with a wrong type"
    assert_contains 'field "query" must be an object' "$out" "query with a wrong type"

    out=$(cd "$d" && req_request_check b.get.json 2>&1)
    assert_contains "req: error: $d/b.get.json: field \"headers\" must be an object" "$out" "each problem carries the absolute path"

    printf '{"name":"c","method":"POST","url":"http://x"}\n' >"$d/c.get.json"
    assert_contains "differs from the file name" "$(check_out "$d/c.get.json")" "method differs from the file"

    printf '{"name":"other","method":"GET","url":"http://x"}\n' >"$d/d.get.json"
    out=$(check_out "$d/d.get.json")
    assert_contains 'field "name" ("other") differs from the file name ("d")' "$out" "name differs from the file"

    printf '{"method":"GET","url":"http://x"}\n' >"$d/e.get.json"
    assert_contains 'field "name" is required' "$(check_out "$d/e.get.json")" "missing name"

    printf '{"name":"f","method":"GET"}\n' >"$d/f.get.json"
    assert_contains 'field "url" is required' "$(check_out "$d/f.get.json")" "missing url"
    printf '{"name":"f2","method":"GET","url":""}\n' >"$d/f2.get.json"
    assert_contains 'field "url" is required' "$(check_out "$d/f2.get.json")" "empty url"
    printf '{"name":"f3","method":"GET","url":42}\n' >"$d/f3.get.json"
    assert_contains 'field "url" is required' "$(check_out "$d/f3.get.json")" "url with a wrong type"

    printf '[]\n' >"$d/g.get.json"
    assert_contains "the root must be an object" "$(check_out "$d/g.get.json")" "root is not an object"

    printf '{"name":"h","method":"GET","url":"http://x"}\n' >"$d/h.get.json"
    assert_eq "0" "$(req_request_check "$d/h.get.json" 2>/dev/null; echo $?)" "optional fields may be missing"

    printf '{"name":"i","method":"HEAD","url":"http://x"}\n' >"$d/i.get.json"
    assert_contains 'method "HEAD" is not supported' "$(check_out "$d/i.get.json")" "method outside the list"

    printf '{"name":"Bad Name","method":"GET","url":"http://x"}\n' >"$d/j.get.json"
    assert_contains "slug" "$(check_out "$d/j.get.json")" "name outside the slug format"

    printf '{"name":"k","method":"GET","url":"http://x","descr":"x","timeout":5}\n' >"$d/k.get.json"
    out=$(check_out "$d/k.get.json")
    assert_contains 'unknown field "descr"' "$out" "unknown field is invalidated"
    assert_contains 'unknown field "timeout"' "$out" "another unknown field"

    printf '{"name":"o","method":"POST","url":"http://x","data_parameter":{"a":"1"}}\n' >"$d/o.post.json"
    assert_contains '"data_parameter" was renamed to "parameters"' "$(check_out "$d/o.post.json")" "the old name points to the new one"
    printf '{"name":"l","method":"POST","url":"http://x","data_string":"x"}\n' >"$d/l.post.json"
    assert_contains '"data_string" was renamed to "raw_data"' "$(check_out "$d/l.post.json")" "the old data_string points to raw_data"
    for v in '{"a":{"b":[1]}}' '[1,"x"]' '"free text"' '""'; do
        printf '{"name":"r","method":"POST","url":"http://x","raw_data":%s}\n' "$v" >"$d/r.post.json"
        assert_eq "0" "$(req_request_check "$d/r.post.json" 2>/dev/null; echo $?)" "raw_data $v is valid"
    done
    for v in 5 true null; do
        printf '{"name":"r","method":"POST","url":"http://x","raw_data":%s}\n' "$v" >"$d/r.post.json"
        assert_contains 'must be an object, a list or a string' "$(check_out "$d/r.post.json")" "raw_data $v is invalid"
    done

    printf '{"name":"m","method":"GET","url":"http://x","description":5}\n' >"$d/m.get.json"
    assert_contains '"description" must be a string' "$(check_out "$d/m.get.json")" "description with a wrong type"

    printf '{"name":"n","method":"GET","url":"http://x","headers":{"X-A":{"b":1},"X B":"v","X-C":"a\\nb","X-D":null}}\n' >"$d/n.get.json"
    out=$(check_out "$d/n.get.json")
    assert_contains 'header "X-A": the value must be' "$out" "header with an object value"
    assert_contains 'header "X B": invalid name' "$out" "header with an invalid name"
    assert_contains 'header "X-C": the value must not contain line breaks' "$out" "header with a line break"
    assert_contains 'header "X-D": the value must be' "$out" "header with a null value"

    printf '{"name":"o","method":"GET","url":"http://x","headers":{"X-A":"v","X-N":1,"X-B":true},"query":{"a":1,"b":"c","d":false}}\n' >"$d/o.get.json"
    assert_eq "0" "$(req_request_check "$d/o.get.json" 2>/dev/null; echo $?)" "headers and query with simple values are valid"

    printf '{"name":"p","method":"POST","url":"http://x","parameters":{"a":{"b":1},"c":[1]}}\n' >"$d/p.post.json"
    out=$(check_out "$d/p.post.json")
    assert_contains 'parameters "a": the value must be' "$out" "parameters with an object"
    assert_contains 'parameters "c": the value must be' "$out" "parameters with a list"

    printf '{"name":"q","method":"GET","url":"http://x"}\n' >"$d/Q Name.get.json"
    assert_contains "does not follow" "$(check_out "$d/Q Name.get.json")" "file outside the pattern"
}

test_project() {
    echo "store: .req file"
    local p=$TMP/proj out
    mkdir -p "$p/api" "$p/auth" "$p/empty"
    printf '# project\napi\n\n  auth/  \n' >"$p/.req"
    assert_eq "$p/.req" "$(req_project_find "$p")" "finds the .req"
    req_project_find "$p/api" >/dev/null; assert_eq "1" "$?" "no .req in the directory"
}

test_init() {
    echo "store: project initialization"
    local d=$TMP/init out
    mkdir -p "$d"
    req_project_init "$d"; assert_eq "0" "$?" "initializes an empty directory"
    [[ -f $d/.req ]]; assert_eq "0" "$?" "creates the .req"
    assert_eq "$d/.req" "$(find "$d" -mindepth 1 | tr -d '\n')" "and nothing else (no directories)"
    assert_contains "workspace=." "$(cat "$d/.req")" "the .req has workspace=."
    assert_contains "# req project" "$(cat "$d/.req")" "and a comment header"
    out=$(req_project_init "$d" 2>&1); assert_eq "1" "$?" "does not overwrite an existing .req"
    assert_contains "already exists" "$out" "error explains why"
    out=$(req_project_init "$TMP/missing" 2>&1); assert_eq "1" "$?" "fails in a missing directory"
    assert_contains "does not exist" "$out" "error names the problem"
    mkdir -p "$TMP/init/nested"
    req_project_init "$TMP/init/nested" >/dev/null 2>&1 && req_project_find "$TMP/init/nested" >/dev/null
    assert_eq "0" "$?" "works in a nested directory"
}

test_list() {
    echo "store: listing"
    local d=$TMP/l out
    mkdir -p "$d/zeta" "$d/alpha-dir" "$d/.hidden"
    : >"$d/readme.md"
    printf '{}\n' >"$d/notes.json"
    printf '{}\n' >"$d/Upper.get.json"
    req_request_write "$d" beta POST http://x >/dev/null
    req_request_write "$d" alpha GET http://x >/dev/null
    req_request_write "$d" alpha DELETE http://x >/dev/null
    req_request_write "$d" alpha PATCH http://x >/dev/null
    out=$(req_list_dir "$d")
    assert_eq "$(printf 'd\talpha-dir\t%s/alpha-dir\nd\tzeta\t%s/zeta\nr\talpha\tDELETE\t%s/alpha.delete.json\nr\talpha\tGET\t%s/alpha.get.json\nr\talpha\tPATCH\t%s/alpha.patch.json\nr\tbeta\tPOST\t%s/beta.post.json' "$d" "$d" "$d" "$d" "$d" "$d")" \
        "$out" "directories first, then requests, sorted; ignores hidden and non-matching files"
    out=$(req_list_dir "$TMP/missing" 2>&1); assert_contains "does not exist" "$out" "missing directory"
    mkdir -p "$TMP/blank"
    assert_eq "" "$(req_list_dir "$TMP/blank")" "empty directory"
}

test_names
test_write_read
test_invalid_manual
test_project
test_init
test_list
test_summary
