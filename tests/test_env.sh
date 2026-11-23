#!/usr/bin/env bash
# Tests for lib/env.sh.
# shellcheck disable=SC2016  # the ${key} placeholders are single-quoted on purpose

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
# envfile <env> <text> - writes the vars file of an environment of the project "shop"; varsfile <text> writes the
# vars file of the project that the previous layout had, which nothing reads any more.
envfile() { mkdir -p "$REQ_CONFIG_DIR/projects/$ID/env/$1"; printf '%s\n' "$2" >"$REQ_CONFIG_DIR/projects/$ID/env/$1/vars"; }
varsfile() { mkdir -p "$REQ_CONFIG_DIR/projects/$ID"; printf '%s\n' "$1" >"$REQ_CONFIG_DIR/projects/$ID/vars"; }

test_paths() {
    echo "env: paths"
    assert_eq "$TMP/cfg" "$(req_config_dir)" "REQ_CONFIG_DIR overrides the config directory"
    assert_eq "$HOME/.req" "$(REQ_CONFIG_DIR='' req_config_dir)" "the default is ~/.req"
    assert_eq "$TMP/cfg/projects/shop/env/dev" "$(req_env_dir shop dev)" "folder of an environment"
    assert_eq "$TMP/cfg/projects/shop/env/dev/vars" "$(req_env_file shop dev)" "file of an environment, inside its folder"
    declare -F req_vars_file >/dev/null; assert_eq "1" "$?" "there is no path for variables of the project: only environments have them"
}

test_load() {
    echo "env: loading variables"
    envfile dev $'# dev\nurl=http://x\n\n token = abc \nquery=a=b'
    req_vars_load dev $ID; assert_eq "0" "$?" "loads a valid file"
    assert_eq "3" "${#REQ_VARS[@]}" "all the variables are loaded"
    assert_eq "http://x" "${REQ_VARS[url]}" "a value"
    assert_eq "abc" "${REQ_VARS[token]}" "spaces around key and value are dropped"
    assert_eq "a=b" "${REQ_VARS[query]}" "a value keeps the = signs after the first"

    envfile prod 'token=zzz'
    req_vars_load prod $ID
    assert_eq "1" "${#REQ_VARS[@]}" "loading another environment replaces the previous variables"
    assert_eq "zzz" "${REQ_VARS[token]}" "with that environment's values"

    varsfile $'region=eu\ntoken=shared'
    req_vars_load dev $ID
    assert_eq "" "${REQ_VARS[region]-}" "a vars file of the project (the previous layout) is not read"
    assert_eq "abc" "${REQ_VARS[token]}" "only the variables of the environment are loaded"
    assert_eq "3" "${#REQ_VARS[@]}" "exactly those"
    req_vars_load nothing-here $ID; assert_eq "0" "$?" "a missing environment file is not an error"
    assert_eq "0" "${#REQ_VARS[@]}" "and nothing is loaded, not even the file of the project"

    envfile dup $'k=first\nk=second'
    req_vars_load dup $ID
    assert_eq "first" "${REQ_VARS[k]}" "the first line of a repeated key wins"

    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"
    envfile empty ''
    req_vars_load empty $ID; assert_eq "0" "$?" "an empty file is valid"
    assert_eq "0" "${#REQ_VARS[@]}" "and has no variables"

    REQ_PROJECT_ID=$ID; req_vars_load dev
    assert_eq "abc" "${REQ_VARS[token]}" "the project defaults to REQ_PROJECT_ID"
    REQ_PROJECT_ID=""; req_vars_load dev; assert_eq "0" "$?" "without a project nothing is loaded"
    assert_eq "0" "${#REQ_VARS[@]}" "and it is not an error"
}

test_invalid() {
    echo "env: invalid files"
    local out f before
    envfile bad $'ok=1\nthis is not valid\n1st=2'
    f=$REQ_CONFIG_DIR/projects/$ID/env/bad/vars; before=$(<"$f")
    out=$(req_vars_load bad $ID 2>&1); assert_eq "1" "$?" "an invalid line fails"
    assert_contains "$f:2: expected key=value" "$out" "the error names the absolute path and the line"
    assert_contains "$f:3: expected key=value" "$out" "every problem is reported"
    assert_eq "$before" "$(<"$f")" "the file is not touched"
    req_vars_load bad $ID 2>/dev/null
    assert_eq "0" "${#REQ_VARS[@]}" "nothing is loaded from an invalid file"

    varsfile 'broken line'
    out=$(req_vars_load dev $ID 2>&1); assert_eq "0" "$?" "an invalid vars file of the project is not read, so it is no problem"
    assert_eq "" "$out" "and says nothing"
    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"

    out=$(req_vars_load "../etc" $ID 2>&1); assert_eq "1" "$?" "an environment name that is not a slug is refused"
    assert_contains "invalid environment name" "$out" "and says why"
    req_vars_load "" $ID 2>/dev/null; assert_eq "1" "$?" "an empty environment name is refused"
    req_vars_load dev "../x" 2>/dev/null; assert_eq "1" "$?" "a project id that is not a slug is refused"
}

test_legacy() {
    echo "env: the old secrets.json"
    local out
    mkdir -p "$REQ_CONFIG_DIR/env/dev"
    printf '{"token":"old"}\n' >"$REQ_CONFIG_DIR/env/dev/secrets.json"
    out=$(req_vars_load dev $ID 2>&1); assert_eq "0" "$?" "the old file is not an error"
    assert_contains "secrets.json is no longer read" "$out" "a warning says so"
    assert_contains "$REQ_CONFIG_DIR/projects/$ID/env/dev/vars" "$out" "and points to the new location"
    req_vars_load dev $ID 2>/dev/null
    assert_eq "abc" "${REQ_VARS[token]}" "its content is ignored"
    out=$(req_vars_load prod $ID 2>&1); assert_not_contains "no longer read" "$out" "other environments are not warned about"
}

test_legacy_files() {
    echo "env: the files of the previous layout"
    local cfg=$REQ_CONFIG_DIR dir
    dir=$cfg/projects/oldlayout
    mkdir -p "$dir/env"
    assert_eq "" "$(req_env_legacy_files oldlayout)" "a project with nothing of the previous layout lists nothing"
    assert_eq "" "$(req_env_legacy_files nothing-here)" "so does a project with no folder"
    assert_eq "" "$(req_env_legacy_files "")" "and no project at all"
    mkdir -p "$dir/env/dev" "$dir/env/.hidden-test"; : >"$dir/env/dev/vars"
    assert_eq "" "$(req_env_legacy_files oldlayout)" "environments in the current layout are not old files"
    printf 'region=eu\n' >"$dir/vars"
    printf 'k=1\n' >"$dir/env/prod"; printf 'k=2\n' >"$dir/env/default"; : >"$dir/env/.hidden-file-test"
    assert_eq "$dir/vars"$'\n'"$dir/env/default"$'\n'"$dir/env/prod" "$(req_env_legacy_files oldlayout)" "the project's vars file comes first, then the plain files of env/ in order; folders and hidden files are left out"
    assert_eq "region=eu" "$(<"$dir/vars")" "nothing is touched"
    REQ_PROJECT_ID=oldlayout
    assert_eq "3" "$(req_env_legacy_files | wc -l | tr -d ' ')" "the project defaults to REQ_PROJECT_ID"
    REQ_PROJECT_ID=""
    rm -f "$dir/vars"
    assert_eq "$dir/env/default"$'\n'"$dir/env/prod" "$(req_env_legacy_files oldlayout)" "without the vars file only the environments are listed"
}

test_resolve() {
    echo "env: resolving a key"
    local out
    rm -f "$REQ_CONFIG_DIR/env/dev/secrets.json"       # left by the previous test
    rm -f "$REQ_CONFIG_DIR/projects/$ID/vars"
    varsfile $'token=from-project-file\nonly_project_file=v'
    envfile dev $'region=eu\nurl=http://dev\ntoken=from-env\nempty='
    req_vars_load dev $ID

    assert_eq "DEV_URL" "$(req_env_var_name dev url)" "the variable name is ENV_KEY in capitals"
    assert_eq "PRE_PROD_TOKEN" "$(req_env_var_name pre-prod token)" "hyphens of the environment become underscores"
    assert_eq "DEV_MY_KEY" "$(req_env_var_name dev my_key)" "underscores in the key stay"

    assert_eq "http://dev" "$(req_resolve_key dev url)" "a key of the environment file"
    assert_eq "eu" "$(req_resolve_key dev region)" "another key of the environment file"
    assert_eq "from-env" "$(req_resolve_key dev token)" "the value is the environment's, never the one of a vars file of the project"
    req_resolve_key dev only_project_file; assert_eq "1" "$?" "a key only a vars file of the project has is not resolved"
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
    REQ_VARS=()
    req_resolve_key dev url; assert_eq "1" "$?" "without loaded variables only the process variable can answer"
}

test_subst() {
    echo "env: substituting \${key}"
    local err
    envfile dev $'url=http://dev\nsecret=s3\nregion=eu\ntoken=from-vars'
    req_vars_load dev $ID

    req_subst 'GET ${url}/users?r=${region}' dev $ID; assert_eq "0" "$?" "a text with known keys is substituted"
    assert_eq "GET http://dev/users?r=eu" "$REQ_SUBST_OUT" "every placeholder is replaced"
    req_subst 'no placeholders here' dev $ID
    assert_eq "no placeholders here" "$REQ_SUBST_OUT" "a text without placeholders is unchanged"
    req_subst '' dev $ID; assert_eq "0|" "$?|$REQ_SUBST_OUT" "an empty text stays empty"
    req_subst '${url}${url}' dev $ID; assert_eq "http://devhttp://dev" "$REQ_SUBST_OUT" "a repeated key and adjacent placeholders"
    req_subst $'a\n${region}\n\n' dev $ID; assert_eq $'a\neu\n\n' "$REQ_SUBST_OUT" "line breaks, including the trailing ones, are kept"
    req_subst '{"k":"${secret}","n":1}' dev $ID; assert_eq '{"k":"s3","n":1}' "$REQ_SUBST_OUT" "it works inside JSON text"

    req_subst 'price $5 and ${not valid} and ${} and $${url} and ${1x}' dev $ID
    assert_eq 'price $5 and ${not valid} and ${} and $http://dev and ${1x}' "$REQ_SUBST_OUT" "only a valid name in braces is a placeholder; the rest is untouched"

    export DEV_LOOP='${url}'
    req_subst 'x=${loop}' dev $ID; assert_eq 'x=${url}' "$REQ_SUBST_OUT" "a value is not expanded again"
    unset DEV_LOOP
    export DEV_TOKEN=from-process
    req_subst '${token}' dev $ID; assert_eq "from-process" "$REQ_SUBST_OUT" "the usual precedence applies"
    unset DEV_TOKEN

    err=$(req_subst 'a ${missing} b ${url} ${other} c ${missing}' dev $ID 2>&1 >/dev/null); assert_eq "1" "$?" "missing keys fail"
    req_subst 'a ${missing} b ${url} ${other} c ${missing}' dev $ID 2>/dev/null
    assert_eq "" "$REQ_SUBST_OUT" "and nothing is produced"
    assert_contains 'req: error: no value for missing, other in environment "dev"' "$err" "the error lists each missing key once, in order"
    assert_contains "missing: set the variable DEV_MISSING, or add missing=... to $REQ_CONFIG_DIR/projects/$ID/env/dev/vars" "$err" "and says what to define and where"
    assert_not_contains "for every environment" "$err" "and no file shared by the environments is suggested, there is none"
    assert_contains "other: set the variable DEV_OTHER" "$err" "for every missing key"
    err=$(req_subst '${x}' pre-prod $ID 2>&1); assert_contains "PRE_PROD_X" "$err" "the variable name follows the environment"
    err=$(req_subst '${x}' dev "" 2>&1)
    assert_contains "set the variable DEV_X" "$err" "without a project only the variable is suggested"
    [[ $err != *"add x=..."* ]]; assert_eq "0" "$?" "and no file"
    REQ_PROJECT_ID=$ID; err=$(req_subst '${x}' dev 2>&1)
    assert_contains "env/dev/vars" "$err" "the project defaults to REQ_PROJECT_ID"
    REQ_PROJECT_ID=""
}

test_subst_json() {
    echo "env: substituting in a request"
    local j err
    envfile dev $'host=h.example\ntok=a"b\\c\nn=5\nextra=e1'
    req_vars_load dev $ID

    j='{"name":"${keep}","description":"${keep}","method":"POST","url":"https://${host}/x","headers":{"Authorization":"Bearer ${tok}","${host}":"k"},"query":{"q":"${n}"},"parameters":{"f":"${extra}"},"raw_data":{"a":["${tok}",1,true,null],"${host}":"v"}}'
    req_subst_json "$j" dev $ID; assert_eq "0" "$?" "a request with known keys is substituted"
    assert_eq "https://h.example/x" "$(jq -r .url <<<"$REQ_SUBST_OUT")" "in the url"
    assert_eq 'Bearer a"b\c' "$(jq -r .headers.Authorization <<<"$REQ_SUBST_OUT")" "in the headers (the quote and backslash survive as JSON)"
    assert_eq "5" "$(jq -r .query.q <<<"$REQ_SUBST_OUT")" "in the query"
    assert_eq "e1" "$(jq -r .parameters.f <<<"$REQ_SUBST_OUT")" "in the parameters"
    assert_eq '["a\"b\\c",1,true,null]' "$(jq -c .raw_data.a <<<"$REQ_SUBST_OUT")" "in the strings of a native JSON raw_data, other values unchanged"
    assert_eq '${keep}|${keep}' "$(jq -r '[.name,.description] | join("|")' <<<"$REQ_SUBST_OUT")" "name and description are left alone"
    assert_eq '["Authorization","${host}"]' "$(jq -c '.headers | keys_unsorted' <<<"$REQ_SUBST_OUT")" "names of properties are never substituted"
    jq -e . <<<"$REQ_SUBST_OUT" >/dev/null; assert_eq "0" "$?" "the result is valid JSON"

    req_subst_json '{"method":"GET","url":"http://x"}' dev $ID
    assert_eq '{"method":"GET","url":"http://x"}' "$REQ_SUBST_OUT" "a request without placeholders is unchanged"
    assert_eq "no" "$(jq -r 'has("headers") | if . then "yes" else "no" end' <<<"$REQ_SUBST_OUT")" "and no field is added"
    req_subst_json '{"method":"POST","url":"http://x","raw_data":"{\"k\":\"${host}\"}"}' dev $ID
    assert_eq '{"k":"h.example"}' "$(jq -r .raw_data <<<"$REQ_SUBST_OUT")" "a raw_data that is text is substituted too"
    export DEV_LOOP='${host}'
    req_subst_json '{"url":"http://${loop}"}' dev $ID; assert_eq 'http://${host}' "$(jq -r .url <<<"$REQ_SUBST_OUT")" "a value is not expanded again"
    unset DEV_LOOP

    err=$(req_subst_json '{"url":"${a}/${b}","headers":{"X":"${a}"},"raw_data":{"k":["${c}"]}}' dev $ID 2>&1 >/dev/null); assert_eq "1" "$?" "missing keys fail"
    req_subst_json '{"url":"${a}/${b}","headers":{"X":"${a}"},"raw_data":{"k":["${c}"]}}' dev $ID 2>/dev/null
    assert_eq "" "$REQ_SUBST_OUT" "with nothing produced"
    assert_contains 'no value for a, b, c in environment "dev"' "$err" "every missing key of the whole request is listed once"
    assert_contains "c: set the variable DEV_C, or add c=... to $REQ_CONFIG_DIR/projects/$ID/env/dev/vars" "$err" "with how to define it"
}

test_env_list() {
    echo "env: the environments of a project"
    mkdir -p "$REQ_CONFIG_DIR/projects/lister/env"
    assert_eq "" "$(req_env_list lister)" "a project without environments lists none"
    assert_eq "" "$(req_env_list nothing-here)" "so does a project with no folder"
    assert_eq "" "$(req_env_list "")" "and no project at all"
    mkdir "$REQ_CONFIG_DIR/projects/lister/env/prod" "$REQ_CONFIG_DIR/projects/lister/env/dev" "$REQ_CONFIG_DIR/projects/lister/env/Bad_Name"
    : >"$REQ_CONFIG_DIR/projects/lister/env/file-of-the-old-layout-test"
    assert_eq $'dev\nprod' "$(req_env_list lister)" "folders with a slug name are listed, sorted; other names and plain files are not"
    REQ_PROJECT_ID=lister
    assert_eq $'dev\nprod' "$(req_env_list)" "the project defaults to REQ_PROJECT_ID"
    req_env_exists dev; assert_eq "0" "$?" "an environment with a folder exists"
    req_env_exists staging; assert_eq "1" "$?" "one without a folder does not"
    req_env_exists file-of-the-old-layout-test; assert_eq "1" "$?" "a plain file of the old layout is not an environment"
    req_env_exists default; assert_eq "0" "$?" "default needs no folder"
    req_env_exists "../x"; assert_eq "1" "$?" "a name that is not a slug never exists"
    req_env_exists dev ""; assert_eq "1" "$?" "without a project only default exists"
    req_env_exists default ""; assert_eq "0" "$?" "which is always there"
    REQ_PROJECT_ID=""
}

test_env_create() {
    echo "env: creating environments"
    local cfg=$REQ_CONFIG_DIR out dir f empty_loads=0 env_dir
    mkdir -p "$cfg/projects/creator"
    dir=$cfg/projects/creator/env

    req_env_ensure_dir creator; assert_eq "0" "$?" "the folder of the environments is made"
    [[ -d $dir ]]; assert_eq "0" "$?" "and it is there"
    assert_eq "700" "$(stat -c %a "$dir")" "private, like the rest of the central directory"
    req_env_ensure_dir creator; assert_eq "0" "$?" "making it again is not an error"
    out=$(req_env_ensure_dir 2>&1); assert_eq "1" "$?" "without a project there is no folder"
    assert_contains "no project is open" "$out" "and the error says why"
    out=$(req_env_ensure_dir "Bad_Id" 2>&1); assert_eq "1" "$?" "a project id that is not a slug is refused"
    assert_contains 'invalid project id: "Bad_Id"' "$out" "and named"

    rmdir "$dir"
    env_dir=$dir/staging-test-env
    req_env_create staging-test-env creator; assert_eq "0" "$?" "an environment is created"
    [[ -d $env_dir && -f $env_dir/vars ]]; assert_eq "0" "$?" "as a folder with a vars file, and env/ is made with it when missing"
    assert_eq "700" "$(stat -c %a "$env_dir")" "the folder of the environment is private"
    assert_eq "600" "$(stat -c %a "$env_dir/vars")" "the file is private"
    assert_eq "700" "$(stat -c %a "$dir")" "and so is env/"
    assert_eq "$(req_vars_template staging-test-env)" "$(<"$env_dir/vars")" "the file starts with the template, which shows the format in comments"
    req_vars_load staging-test-env creator && empty_loads=1
    assert_eq "1" "$empty_loads" "that file is valid for the loader"
    assert_eq "0" "${#REQ_VARS[@]}" "and has no variables, comments are not variables"

    printf 'token=kept\n' >"$env_dir/vars"
    req_env_create staging-test-env creator; assert_eq "0" "$?" "creating one that exists is not an error"
    assert_eq "token=kept" "$(<"$env_dir/vars")" "and leaves its content alone"
    chmod 640 "$env_dir/vars"; chmod 750 "$env_dir"
    req_env_create staging-test-env creator
    assert_eq "640" "$(stat -c %a "$env_dir/vars")" "and the mode of its file"
    assert_eq "750" "$(stat -c %a "$env_dir")" "and of its folder"
    chmod 700 "$env_dir"; rm -f "$env_dir/vars"
    req_env_create staging-test-env creator; assert_eq "0" "$?" "a folder without its vars file is an environment that exists"
    [[ ! -e $env_dir/vars ]]; assert_eq "0" "$?" "and the missing file is not made behind the user's back"

    REQ_PROJECT_ID=creator
    req_env_create default-by-id-test; assert_eq "0" "$?" "the project defaults to REQ_PROJECT_ID"
    [[ -f $dir/default-by-id-test/vars ]]; assert_eq "0" "$?" "and the environment is made in it"
    REQ_PROJECT_ID=""

    out=$(req_env_create "../invalid-name-test" creator 2>&1); assert_eq "1" "$?" "a name that is not a slug is refused"
    assert_contains 'invalid environment name: "../invalid-name-test"' "$out" "and named in the error"
    [[ ! -e $cfg/projects/creator/invalid-name-test ]]; assert_eq "0" "$?" "and nothing is written outside the folder"
    out=$(req_env_create staging-test-env 2>&1); assert_eq "1" "$?" "without a project nothing is created"

    printf 'token=from-the-old-layout\n' >"$dir/plain-file-in-the-way-test"
    out=$(req_env_create plain-file-in-the-way-test creator 2>&1); assert_eq "1" "$?" "a plain file where the folder goes (the old layout) is refused"
    assert_contains "$dir/plain-file-in-the-way-test exists and is not a folder" "$out" "with the absolute path"
    assert_eq "token=from-the-old-layout" "$(<"$dir/plain-file-in-the-way-test")" "and the file is left as it was"
    ln -s "$TMP/nowhere" "$dir/dangling-link-test"
    out=$(req_env_create dangling-link-test creator 2>&1); assert_eq "1" "$?" "so is a link, even one that points nowhere"
    [[ ! -e $TMP/nowhere ]]; assert_eq "0" "$?" "and the target of the link is not created"

    if (( EUID != 0 )); then       # root ignores the permissions
        mkdir -p "$cfg/projects/locked-test"; chmod 500 "$cfg/projects/locked-test"
        out=$(req_env_create env-in-locked-test locked-test 2>&1); f=$?
        chmod 700 "$cfg/projects/locked-test"
        assert_eq "1" "$f" "a folder that cannot be written fails"
        assert_contains "req: error: cannot create $cfg/projects/locked-test/env" "$out" "with the absolute path of the folder"
        chmod 500 "$dir"
        out=$(req_env_create read-only-folder-test creator 2>&1); f=$?
        chmod 700 "$dir"
        assert_eq "1" "$f" "an env/ folder that cannot be written fails"
        assert_contains "cannot create $dir/read-only-folder-test" "$out" "naming the environment's folder"
        [[ ! -e $dir/read-only-folder-test ]]; assert_eq "0" "$?" "and leaves nothing behind"
    fi
}

test_vars_create() {
    echo "env: creating the variables of an environment"
    local cfg=$REQ_CONFIG_DIR out f dir file
    mkdir -p "$cfg/projects/varsmaker"
    dir=$cfg/projects/varsmaker/env/dev
    file=$dir/vars

    assert_contains "# host=https://api.example.com" "$(req_vars_template dev)" "the template shows a commented example"
    assert_contains '${host}' "$(req_vars_template dev)" "and how a request uses a variable"
    assert_contains "# Variables of environment dev:" "$(req_vars_template dev)" "it names the environment"
    assert_not_contains "shared" "$(req_vars_template dev)" "and says nothing about sharing: each environment has its own"
    req_vars_create dev varsmaker; assert_eq "0" "$?" "the file is made"
    [[ -f $file ]]; assert_eq "0" "$?" "in the folder of the environment, which is made with it"
    assert_eq "600" "$(stat -c %a "$file")" "private, since it may hold credentials"
    assert_eq "700" "$(stat -c %a "$dir")" "in a private folder"
    assert_eq "$(req_vars_template dev)" "$(<"$file")" "it starts with the template"
    req_kv_check "$file"; assert_eq "0" "$?" "which is a valid file"
    assert_eq "" "$(tail -n 1 "$file")" "and ends with a blank line, so a line opened after it in vim does not continue a comment"
    req_vars_load dev varsmaker
    assert_eq "0" "${#REQ_VARS[@]}" "its comment lines are not variables, the commented example included"
    printf 'host=https://dev.example.com\n' >>"$file"
    req_vars_load dev varsmaker
    assert_eq "1" "${#REQ_VARS[@]}" "only the line written after them is"
    assert_eq "https://dev.example.com" "${REQ_VARS[host]}" "with its value"
    req_subst '${host}/users' dev varsmaker
    assert_eq "https://dev.example.com/users" "$REQ_SUBST_OUT" "and a request can use it"

    : >"$file"; chmod 640 "$file"
    req_vars_create dev varsmaker; assert_eq "0" "$?" "making it again is not an error"
    assert_eq "0" "$(wc -c <"$file" | tr -d ' ')" "an empty file is left empty"
    assert_eq "640" "$(stat -c %a "$file")" "and keeps its mode"
    printf 'token=kept\n' >"$file"
    req_vars_create dev varsmaker
    assert_eq "token=kept" "$(<"$file")" "a file with content is never touched"

    rm -f "$file"
    req_vars_create dev varsmaker; assert_eq "0" "$?" "a folder without its file gets the file"
    assert_eq "$(req_vars_template dev)" "$(<"$file")" "with the template"
    assert_eq "600" "$(stat -c %a "$file")" "private"

    req_vars_create staging varsmaker
    assert_eq "$(req_vars_template staging)" "$(<"$cfg/projects/varsmaker/env/staging/vars")" "another environment has a file of its own, with its own name in the template"
    assert_eq "$(req_vars_template dev)" "$(<"$file")" "and the first one is untouched"

    rm -rf "$cfg/projects/varsmaker"
    req_vars_create dev varsmaker; assert_eq "0" "$?" "the project folder is made with it when it is missing"
    [[ -f $file ]]; assert_eq "0" "$?" "and so is the file"
    assert_eq "700" "$(stat -c %a "$cfg/projects/varsmaker")" "the project folder is private"

    REQ_PROJECT_ID=varsmaker; rm -f "$file"
    req_vars_create dev; assert_eq "0" "$?" "the project defaults to REQ_PROJECT_ID"
    [[ -f $file ]]; assert_eq "0" "$?" "and the file is made in it"
    REQ_PROJECT_ID=""
    out=$(req_vars_create dev 2>&1); assert_eq "1" "$?" "without a project nothing is made"
    assert_contains "no project is open" "$out" "and the error says why"
    out=$(req_vars_create dev "Bad_Id" 2>&1); assert_eq "1" "$?" "a project id that is not a slug is refused"
    assert_contains 'invalid project id: "Bad_Id"' "$out" "and named"
    out=$(req_vars_create "../etc" varsmaker 2>&1); assert_eq "1" "$?" "an environment name that is not a slug is refused"
    assert_contains 'invalid environment name: "../etc"' "$out" "and named"

    rm -rf "$dir"; : >"$dir"
    out=$(req_vars_create dev varsmaker 2>&1); assert_eq "1" "$?" "a plain file where the environment's folder goes is refused"
    assert_contains "$dir exists and is not a folder" "$out" "with the absolute path"
    rm -f "$dir"; mkdir -p "$file"
    out=$(req_vars_create dev varsmaker 2>&1); assert_eq "1" "$?" "a folder where the file goes is refused"
    assert_contains "$file exists and is not a file" "$out" "with the absolute path"
    rmdir "$file"; ln -s "$TMP/nowhere-vars" "$file"
    out=$(req_vars_create dev varsmaker 2>&1); assert_eq "1" "$?" "so is a link that points nowhere"
    [[ ! -e $TMP/nowhere-vars ]]; assert_eq "0" "$?" "and the target of the link is not created"
    rm -f "$file"

    if (( EUID != 0 )); then       # root ignores the permissions
        chmod 500 "$dir"
        out=$(req_vars_create dev varsmaker 2>&1); f=$?
        chmod 700 "$dir"
        assert_eq "1" "$f" "a folder that cannot be written fails"
        assert_contains "req: error: cannot create $file" "$out" "naming the file with its absolute path"
    fi
}

test_env_choices() {
    echo "env: the choices of the environment menu"
    local cfg=$REQ_CONFIG_DIR dir
    dir=$cfg/projects/chooser/env
    req_env_choices chooser; assert_eq "default" "${REQ_ENV_CHOICES[*]}" "a project with no environment has only default"
    assert_eq "1" "${#REQ_ENV_CHOICES[@]}" "which is always offered, with or without a file"
    req_env_choices ""; assert_eq "default" "${REQ_ENV_CHOICES[*]}" "so does no project at all"

    mkdir -p "$dir/prod" "$dir/dev" "$dir/Bad_Name"; : >"$dir/a-plain-file-test"
    req_env_choices chooser
    assert_eq "default dev prod" "${REQ_ENV_CHOICES[*]}" "default comes first, then the folders in order; a name that is not a slug, and a plain file, are left out"
    mkdir "$dir/default" "$dir/aaa"
    req_env_choices chooser
    assert_eq "default aaa dev prod" "${REQ_ENV_CHOICES[*]}" "default is first and listed once even with a folder of its own"
    REQ_PROJECT_ID=chooser; req_env_choices
    assert_eq "default aaa dev prod" "${REQ_ENV_CHOICES[*]}" "the project defaults to REQ_PROJECT_ID"
    REQ_PROJECT_ID=""
    req_env_choices chooser; req_env_choices ""
    assert_eq "default" "${REQ_ENV_CHOICES[*]}" "the list of the last call replaces the one before"
}

test_paths
test_load
test_invalid
test_legacy
test_legacy_files
test_resolve
test_subst
test_subst_json
test_env_list
test_env_create
test_vars_create
test_env_choices
test_summary
