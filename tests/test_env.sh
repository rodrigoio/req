#!/usr/bin/env bash
# Tests for lib/env.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/env.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/cfg

# secrets <env> <json> - writes an environment's secrets file.
secrets() { mkdir -p "$REQ_CONFIG_DIR/env/$1"; printf '%s\n' "$2" >"$REQ_CONFIG_DIR/env/$1/secrets.json"; }

test_paths() {
    echo "env: paths"
    assert_eq "$TMP/cfg" "$(req_config_dir)" "REQ_CONFIG_DIR overrides the config directory"
    assert_eq "$HOME/.req" "$(REQ_CONFIG_DIR='' req_config_dir)" "the default is ~/.req"
    assert_eq "$TMP/cfg/env/dev/secrets.json" "$(req_env_secrets_file dev)" "secrets file of an environment"
}

test_load() {
    echo "env: loading secrets"
    secrets dev '{"token":"abc","port":8080,"debug":true,"base_url":"http://x"}'
    req_secrets_load dev; assert_eq "0" "$?" "loads a valid file"
    assert_eq "4" "${#REQ_SECRETS[@]}" "all the secrets are loaded"
    assert_eq "abc" "${REQ_SECRETS[token]}" "a string"
    assert_eq "8080" "${REQ_SECRETS[port]}" "a number becomes text"
    assert_eq "true" "${REQ_SECRETS[debug]}" "a boolean becomes text"
    assert_eq "http://x" "${REQ_SECRETS[base_url]}" "a key with an underscore"

    secrets prod '{"token":"zzz"}'
    req_secrets_load prod
    assert_eq "1" "${#REQ_SECRETS[@]}" "loading another environment replaces the previous secrets"
    assert_eq "zzz" "${REQ_SECRETS[token]}" "with that environment's values"

    secrets spaces '{"msg":"a b\nc"}'
    req_secrets_load spaces
    assert_eq $'a b\nc' "${REQ_SECRETS[msg]}" "values keep spaces and newlines"

    req_secrets_load nothing-here; assert_eq "0" "$?" "a missing file is not an error"
    assert_eq "0" "${#REQ_SECRETS[@]}" "and leaves no secrets"
    secrets empty '{}'
    req_secrets_load empty; assert_eq "0" "$?" "an empty object is valid"
}

test_invalid() {
    echo "env: invalid secrets files"
    local out f
    secrets bad '{"token": "abc" "x": 1}'
    f=$REQ_CONFIG_DIR/env/bad/secrets.json; before=$(<"$f")
    out=$(req_secrets_load bad 2>&1); assert_eq "1" "$?" "invalid JSON fails"
    assert_contains "req: error: $f: invalid JSON" "$out" "the error names the absolute path"
    assert_eq "$before" "$(<"$f")" "the file is not touched"

    secrets list '["a"]'
    out=$(req_secrets_load list 2>&1); assert_eq "1" "$?" "a non-object root fails"
    assert_contains "the root must be an object" "$out" "and says so"

    secrets types '{"ok":"1","obj":{"a":1},"arr":[1],"nul":null}'
    out=$(req_secrets_load types 2>&1); assert_eq "1" "$?" "wrong value types fail"
    assert_contains 'secret "obj": the value must be' "$out" "an object value is reported"
    assert_contains 'secret "arr": the value must be' "$out" "a list value is reported"
    assert_contains 'secret "nul": the value must be' "$out" "a null value is reported"
    assert_eq "0" "${#REQ_SECRETS[@]}" "nothing is loaded from an invalid file"

    secrets names '{"good":"1","bad name":"2","1st":"3"}'
    out=$(req_secrets_load names 2>&1)
    assert_contains 'secret "bad name": invalid name' "$out" "a key with a space is reported"
    assert_contains 'secret "1st": invalid name' "$out" "a key starting with a digit is reported"

    out=$(req_secrets_load "../etc" 2>&1); assert_eq "1" "$?" "an environment name that is not a slug is refused"
    assert_contains "invalid environment name" "$out" "and says why"
    req_secrets_load "" 2>/dev/null; assert_eq "1" "$?" "an empty environment name is refused"
}

test_paths
test_load
test_invalid
test_summary
