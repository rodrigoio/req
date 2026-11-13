#!/usr/bin/env bash
# Tests for lib/env.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"
source "$ROOT/lib/env.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/cfg

ID=shop
# envfile <env> <text> / varsfile <text> - write the files of the project "shop".
envfile() { mkdir -p "$REQ_CONFIG_DIR/projects/$ID/env"; printf '%s\n' "$2" >"$REQ_CONFIG_DIR/projects/$ID/env/$1"; }
varsfile() { mkdir -p "$REQ_CONFIG_DIR/projects/$ID"; printf '%s\n' "$1" >"$REQ_CONFIG_DIR/projects/$ID/vars"; }

test_paths() {
    echo "env: paths"
    assert_eq "$TMP/cfg" "$(req_config_dir)" "REQ_CONFIG_DIR overrides the config directory"
    assert_eq "$HOME/.req" "$(REQ_CONFIG_DIR='' req_config_dir)" "the default is ~/.req"
    assert_eq "$TMP/cfg/projects/shop/env/dev" "$(req_env_file shop dev)" "file of an environment"
    assert_eq "$TMP/cfg/projects/shop/vars" "$(req_vars_file shop)" "project variables"
}

test_load() {
    echo "env: loading variables"
    envfile dev $'# dev\nurl=http://x\n\n token = abc \nquery=a=b'
    req_secrets_load dev $ID; assert_eq "0" "$?" "loads a valid file"
    assert_eq "3" "${#REQ_SECRETS[@]}" "all the variables are loaded"
    assert_eq "http://x" "${REQ_SECRETS[url]}" "a value"
    assert_eq "abc" "${REQ_SECRETS[token]}" "spaces around key and value are dropped"
    assert_eq "a=b" "${REQ_SECRETS[query]}" "a value keeps the = signs after the first"

    envfile prod 'token=zzz'
    req_secrets_load prod $ID
    assert_eq "1" "${#REQ_SECRETS[@]}" "loading another environment replaces the previous variables"
    assert_eq "zzz" "${REQ_SECRETS[token]}" "with that environment's values"

    varsfile $'region=eu\ntoken=shared'
    req_secrets_load dev $ID
    assert_eq "eu" "${REQ_SECRETS[region]}" "project variables are loaded too"
    assert_eq "abc" "${REQ_SECRETS[token]}" "the environment wins over the project variables"
    req_secrets_load nothing-here $ID; assert_eq "0" "$?" "a missing environment file is not an error"
    assert_eq "shared" "${REQ_SECRETS[token]}" "and only the project variables remain"
    assert_eq "2" "${#REQ_SECRETS[@]}" "exactly those"

    envfile dup $'k=first\nk=second'
    req_secrets_load dup $ID
    assert_eq "first" "${REQ_SECRETS[k]}" "the first line of a repeated key wins"

    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"
    envfile empty ''
    req_secrets_load empty $ID; assert_eq "0" "$?" "an empty file is valid"
    assert_eq "0" "${#REQ_SECRETS[@]}" "and has no variables"

    REQ_PROJECT_ID=$ID; req_secrets_load dev
    assert_eq "abc" "${REQ_SECRETS[token]}" "the project defaults to REQ_PROJECT_ID"
    REQ_PROJECT_ID=""; req_secrets_load dev; assert_eq "0" "$?" "without a project nothing is loaded"
    assert_eq "0" "${#REQ_SECRETS[@]}" "and it is not an error"
}

test_invalid() {
    echo "env: invalid files"
    local out f before
    envfile bad $'ok=1\nthis is not valid\n1st=2'
    f=$REQ_CONFIG_DIR/projects/$ID/env/bad; before=$(<"$f")
    out=$(req_secrets_load bad $ID 2>&1); assert_eq "1" "$?" "an invalid line fails"
    assert_contains "$f:2: expected key=value" "$out" "the error names the absolute path and the line"
    assert_contains "$f:3: expected key=value" "$out" "every problem is reported"
    assert_eq "$before" "$(<"$f")" "the file is not touched"
    req_secrets_load bad $ID 2>/dev/null
    assert_eq "0" "${#REQ_SECRETS[@]}" "nothing is loaded from an invalid file"

    varsfile 'broken line'
    out=$(req_secrets_load dev $ID 2>&1); assert_eq "1" "$?" "an invalid vars file fails even when the environment is fine"
    assert_contains "$REQ_CONFIG_DIR/projects/$ID/vars:1" "$out" "and names that file"
    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"

    out=$(req_secrets_load "../etc" $ID 2>&1); assert_eq "1" "$?" "an environment name that is not a slug is refused"
    assert_contains "invalid environment name" "$out" "and says why"
    req_secrets_load "" $ID 2>/dev/null; assert_eq "1" "$?" "an empty environment name is refused"
    req_secrets_load dev "../x" 2>/dev/null; assert_eq "1" "$?" "a project id that is not a slug is refused"
}

test_legacy() {
    echo "env: the old secrets.json"
    local out
    mkdir -p "$REQ_CONFIG_DIR/env/dev"
    printf '{"token":"old"}\n' >"$REQ_CONFIG_DIR/env/dev/secrets.json"
    out=$(req_secrets_load dev $ID 2>&1); assert_eq "0" "$?" "the old file is not an error"
    assert_contains "secrets.json is no longer read" "$out" "a warning says so"
    assert_contains "$REQ_CONFIG_DIR/projects/$ID/env/dev" "$out" "and points to the new location"
    req_secrets_load dev $ID 2>/dev/null
    assert_eq "abc" "${REQ_SECRETS[token]}" "its content is ignored"
    out=$(req_secrets_load prod $ID 2>&1); assert_not_contains "no longer read" "$out" "other environments are not warned about"
}

test_resolve() {
    echo "env: resolving a key"
    local out
    rm -rf "$REQ_CONFIG_DIR/env"       # the old secrets.json of the previous test
    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"
    varsfile $'region=eu\ntoken=from-vars\nonly_vars=v'
    envfile dev $'url=http://dev\ntoken=from-env\nempty='
    req_secrets_load dev $ID

    assert_eq "DEV_URL" "$(req_env_var_name dev url)" "the variable name is ENV_KEY in capitals"
    assert_eq "PRE_PROD_TOKEN" "$(req_env_var_name pre-prod token)" "hyphens of the environment become underscores"
    assert_eq "DEV_MY_KEY" "$(req_env_var_name dev my_key)" "underscores in the key stay"

    assert_eq "http://dev" "$(req_resolve_key dev url)" "a key of the environment file"
    assert_eq "eu" "$(req_resolve_key dev region)" "a key only the project variables define"
    assert_eq "from-env" "$(req_resolve_key dev token)" "the environment file wins over the project variables"
    out=$(req_resolve_key dev empty); assert_eq "0|" "$?|$out" "an empty value is a value"
    out=$(req_resolve_key dev missing); assert_eq "1|" "$?|$out" "an undefined key fails and prints nothing"

    export DEV_TOKEN=from-process DEV_URL=""
    assert_eq "from-process" "$(req_resolve_key dev token)" "a process variable wins over the files"
    out=$(req_resolve_key dev url); assert_eq "0|" "$?|$out" "even an empty process variable wins"
    export DEV_ONLY_PROCESS=p
    assert_eq "p" "$(req_resolve_key dev only_process)" "and it can define a key by itself"
    unset DEV_TOKEN DEV_URL DEV_ONLY_PROCESS

    export PROD_TOKEN=prod-process
    assert_eq "from-env" "$(req_resolve_key dev token)" "the variable of another environment is ignored"
    unset PROD_TOKEN
    assert_eq "from-env" "$(req_resolve_key dev token)" "unsetting it restores the file value"

    req_resolve_key dev "bad key"; assert_eq "1" "$?" "a key that is not a valid name fails"
    req_resolve_key dev ""; assert_eq "1" "$?" "an empty key fails"
    REQ_SECRETS=()
    req_resolve_key dev url; assert_eq "1" "$?" "without loaded variables only the process variable can answer"
}

test_paths
test_load
test_invalid
test_legacy
test_resolve
test_summary
