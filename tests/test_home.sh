#!/usr/bin/env bash
# Tests for lib/home.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/home.sh"

TMP=$(mktemp -d)
export REQ_CONFIG_DIR=$TMP/cfg
trap 'rm -rf "$TMP"' EXIT

test_kv_read() {
    echo "home: key=value reading"
    local f=$TMP/read.kv out
    printf '# a comment\n\nname = demo project \n url=http://x/a?b=1&c=2\nempty=\r\nCRLF=yes\r\nbad line\n9bad=1\n  # indented comment\nname=second\n' >"$f"
    assert_eq "demo project" "$(req_kv_get "$f" name)" "trims spaces; the first line of a key wins"
    assert_eq "http://x/a?b=1&c=2" "$(req_kv_get "$f" url)" "the value may contain ="
    assert_eq "" "$(req_kv_get "$f" empty)" "an empty value is allowed"
    req_kv_get "$f" empty >/dev/null; assert_eq "0" "$?" "and it counts as present"
    assert_eq "yes" "$(req_kv_get "$f" CRLF)" "CRLF line endings are tolerated"
    req_kv_get "$f" absent >/dev/null; assert_eq "1" "$?" "a missing key fails"
    req_kv_get "$f" "9bad" >/dev/null; assert_eq "1" "$?" "an invalid key is never returned"
    req_kv_get "$TMP/none.kv" name >/dev/null; assert_eq "1" "$?" "a missing file fails"

    out=$(req_kv_list "$f")
    assert_eq $'name=demo project\nurl=http://x/a?b=1&c=2\nempty=\nCRLF=yes\nname=second' "$out" "lists the valid lines, normalized, in order"
    assert_eq "" "$(req_kv_list "$TMP/none.kv")" "a missing file lists nothing"
    req_kv_list "$TMP/none.kv"; assert_eq "0" "$?" "and is not an error"
}

test_kv_check() {
    echo "home: key=value checking"
    local f=$TMP/check.kv out
    printf '# ok\na=1\n\nb = 2\n' >"$f"
    req_kv_check "$f"; assert_eq "0" "$?" "a valid file passes"
    req_kv_check "$TMP/none.kv"; assert_eq "0" "$?" "a missing file passes"
    printf 'a=1\nnot a pair\n9x=2\n# fine\nc=3\n' >"$f"
    out=$(req_kv_check "$f" 2>&1); assert_eq "1" "$?" "invalid lines fail"
    assert_contains "$f:2: expected key=value" "$out" "the first problem has the absolute path and the line"
    assert_contains "$f:3: expected key=value" "$out" "the second problem too"
    [[ $out != *":4:"* && $out != *":5:"* ]]; assert_eq "0" "$?" "comments and valid lines are not reported"
}

test_kv_write() {
    echo "home: key=value writing"
    local f=$TMP/deep/er/write.kv
    req_kv_set "$f" token abc
    assert_eq "token=abc" "$(<"$f")" "set creates the file and its directories"
    assert_eq "600" "$(stat -c %a "$f")" "a new file is private"
    assert_eq "700" "$(stat -c %a "$TMP/deep/er")" "and so is its new directory"

    printf '# header\nfirst=1\n\n# middle\nsecond=2\nthird=3' >"$f"
    req_kv_set "$f" second "  two  "
    assert_eq $'# header\nfirst=1\n\n# middle\nsecond=two\nthird=3' "$(<"$f")" "set replaces in place and keeps comments, blanks and order"
    req_kv_set "$f" fourth 4
    assert_eq $'# header\nfirst=1\n\n# middle\nsecond=two\nthird=3\nfourth=4' "$(<"$f")" "a new key goes to the end (even after a last line without newline)"
    req_kv_set "$f" empty ""
    assert_eq "empty=" "$(tail -n1 "$f")" "an empty value is written"
    assert_eq "" "$(req_kv_get "$f" empty)" "and read back"
    req_kv_set "$f" url "http://x/?a=1"
    assert_eq "http://x/?a=1" "$(req_kv_get "$f" url)" "a value with = round-trips"

    printf 'k=1\nx=9\nk=2\n' >"$f"
    req_kv_set "$f" k 5
    assert_eq $'k=5\nx=9' "$(<"$f")" "set keeps only the first line of a duplicated key"

    chmod 640 "$f"
    req_kv_set "$f" x 10
    assert_eq "640" "$(stat -c %a "$f")" "the mode of an existing file is kept"
    assert_eq "" "$(compgen -G "$TMP/deep/er/write.kv.*")" "no temporary files are left"

    local out
    out=$(req_kv_set "$f" "bad key" 1 2>&1); assert_eq "1" "$?" "an invalid key is refused"
    assert_contains "invalid key" "$out" "and explained"
    out=$(req_kv_set "$f" ok $'two\nlines' 2>&1); assert_eq "1" "$?" "a multi-line value is refused"
    assert_contains "single line" "$out" "and explained"
    assert_eq $'k=5\nx=10' "$(<"$f")" "refusals leave the file untouched"

    printf 'k=1\n# c\nk=2\nz=3\n' >"$f"
    req_kv_unset "$f" k; assert_eq "0" "$?" "unset removes a key"
    assert_eq $'# c\nz=3' "$(<"$f")" "every line of it, and nothing else"
    req_kv_unset "$f" k; assert_eq "1" "$?" "unsetting an absent key fails"
    req_kv_unset "$TMP/none.kv" k; assert_eq "1" "$?" "unsetting in a missing file fails"
    assert_eq $'# c\nz=3' "$(<"$f")" "and changes nothing"

    ln -s "$f" "$TMP/link.kv"
    req_kv_set "$TMP/link.kv" z 4
    [[ -L $TMP/link.kv ]]; assert_eq "0" "$?" "a symbolic link stays a link"
    assert_eq "4" "$(req_kv_get "$f" z)" "and the target is the file written"
}

test_central_dir() {
    echo "home: central directory"
    assert_eq "$TMP/cfg" "$(req_config_dir)" "REQ_CONFIG_DIR sets the central directory"
    assert_eq "/h/.req" "$(REQ_CONFIG_DIR='' HOME=/h req_config_dir)" "the default is ~/.req"
    assert_eq "$TMP/cfg/projects" "$(req_projects_dir)" "projects live in projects/"
    assert_eq "$TMP/cfg/projects/api" "$(req_project_state_dir api)" "one directory per project"
    assert_eq "$TMP/cfg/projects/api/env/dev" "$(req_project_state_dir api env/dev)" "with a subpath"

    assert_eq "minha-api" "$(req_project_slug /x/Minha_API)" "the slug lowercases and replaces other characters"
    assert_eq "my-project-2" "$(req_project_slug "/x/ My Project (2) /")" "runs of other characters become one hyphen, ends are trimmed"
    assert_eq "project" "$(req_project_slug "/x/___")" "nothing left means \"project\""
    assert_eq "api" "$(req_project_slug api)" "a bare name works"
    assert_eq "1" "$(req_valid_name "$(req_project_slug "/x/Åäö 9")" && echo 1)" "slugs are valid names"
}

test_projects() {
    echo "home: projects"
    local a=$TMP/work/api b=$TMP/other/api c=$TMP/work/web id out
    mkdir -p "$a" "$b" "$c"

    req_project_find_id "$a" >/dev/null; assert_eq "1" "$?" "nothing is registered at first"
    id=$(req_project_create "$a"); assert_eq "api" "$id" "the id is the folder's slug"
    assert_eq "api" "$(req_kv_get "$TMP/cfg/projects/api/project" name)" "the project file has the name"
    assert_eq "$a" "$(req_kv_get "$TMP/cfg/projects/api/project" path)" "and the absolute path"
    assert_eq "api" "$(req_project_find_id "$a")" "the project is found by its path"
    assert_eq "api" "$(req_project_find_id "$a/../api")" "paths are normalized first"
    assert_eq "700" "$(stat -c %a "$TMP/cfg/projects/api")" "the project directory is private"

    id=$(req_project_create "$b"); assert_eq "api-2" "$id" "another folder with the same name gets a suffix"
    id=$(req_project_create "$c"); assert_eq "web" "$id" "a different name keeps its slug"
    assert_eq "api-2" "$(req_project_find_id "$b")" "each path finds its own project"
    mkdir -p "$TMP/third/api"
    assert_eq "api-3" "$(req_project_create "$TMP/third/api")" "the suffix keeps counting"

    ln -s "$a" "$TMP/linked"
    assert_eq "api" "$(req_project_find_id "$TMP/linked")" "a symbolic link finds the real project"

    out=$(req_project_create "$TMP/ghost" 2>&1); assert_eq "1" "$?" "a missing directory is refused"
    assert_contains "does not exist" "$out" "and explained"
    mkdir -p "$TMP/with space/My Dir"
    assert_eq "my-dir" "$(req_project_create "$TMP/with space/My Dir")" "a folder name with spaces works"
    assert_eq "$TMP/with space/My Dir" "$(req_project_find_id "$TMP/with space/My Dir" >/dev/null; req_kv_get "$TMP/cfg/projects/my-dir/project" path)" "and its path is stored as it is"
}

test_current() {
    echo "home: current project pointer"
    local a=$TMP/cur/one b=$TMP/cur/two out
    mkdir -p "$a" "$b"
    req_current_get >/dev/null; assert_eq "1" "$?" "no pointer at first"
    req_project_create "$a" >/dev/null; req_project_create "$b" >/dev/null
    req_current_set one; assert_eq "0" "$?" "a registered project can be selected"
    assert_eq "one" "$(req_current_get)" "and is read back"
    assert_eq "project=one" "$(<"$TMP/cfg/current")" "the pointer file is key=value"
    req_current_set two
    assert_eq "two" "$(req_current_get)" "the pointer moves"
    out=$(req_current_set nope 2>&1); assert_eq "1" "$?" "an unknown project is refused"
    assert_contains "unknown project" "$out" "and explained"
    assert_eq "two" "$(req_current_get)" "the pointer is unchanged"
    out=$(req_current_set "../x" 2>&1); assert_eq "1" "$?" "an id that is not a slug is refused"
    rm -rf "$TMP/cfg/projects/two"
    req_current_get >/dev/null; assert_eq "1" "$?" "a pointer to a removed project reads as none"
    printf 'project=../../etc\n' >"$TMP/cfg/current"
    req_current_get >/dev/null; assert_eq "1" "$?" "a hand-edited pointer outside the slug rule is ignored"
}

test_cursor() {
    echo "home: cursor file"
    local cfg=$REQ_CONFIG_DIR f
    REQ_CONFIG_DIR=$TMP/cur-cfg
    f=$(req_cursor_file shop)
    assert_eq "$TMP/cur-cfg/projects/shop/cursor" "$f" "the cursor lives in the project's folder"
    req_cursor_save shop "api/v2" "api/v2/list.get.json"; assert_eq "0" "$?" "saving works without the folder existing"
    assert_eq $'dir=api/v2\nitem=api/v2/list.get.json' "$(<"$f")" "it holds dir and item as key=value"
    req_cursor_save shop "" ""
    assert_eq "" "$(req_kv_get "$f" dir)$(req_kv_get "$f" item)" "the root with nothing selected is saved as empty values"
    assert_eq "dir=
item=" "$(<"$f")" "in place of the old lines"
    req_cursor_save shop "a" $'b\nc' 2>/dev/null; assert_eq "1" "$?" "a value with a line break is refused"
    if (( EUID != 0 )); then       # root ignores the permissions
        chmod 000 "$TMP/cur-cfg/projects/shop"
        req_cursor_save shop "a" "b" 2>/dev/null; assert_eq "1" "$?" "an unwritable folder fails"
        chmod 700 "$TMP/cur-cfg/projects/shop"
    fi
    REQ_CONFIG_DIR=$cfg
}

test_activate() {
    echo "home: project activation"
    local a=$TMP/act/one b=$TMP/act/two out status cfg=$REQ_CONFIG_DIR
    mkdir -p "$a" "$b"
    REQ_CONFIG_DIR=$TMP/act-cfg

    req_project_activate "$a"; assert_eq "0" "$?" "activating an unknown project succeeds"
    assert_eq "one" "$REQ_PROJECT_ID" "REQ_PROJECT_ID is set"
    assert_eq "one" "$(req_current_get)" "and it becomes the current project"
    assert_eq "$a" "$(req_kv_get "$TMP/act-cfg/projects/one/project" path)" "the project file is written"

    req_project_activate "$b"; assert_eq "two" "$REQ_PROJECT_ID" "a second project gets its own id"
    assert_eq "two" "$(req_current_get)" "and takes over the pointer"
    req_project_activate "$a"
    assert_eq "one" "$REQ_PROJECT_ID" "reopening a registered project reuses its id"
    assert_eq "one" "$(req_current_get)" "and moves the pointer back"
    assert_eq "2" "$(find "$TMP/act-cfg/projects" -mindepth 1 -maxdepth 1 | wc -l)" "no duplicate project was created"

    # ~/.req cannot be written: one warning, no failure of the caller's flow.
    printf 'x' >"$TMP/not-a-dir"
    REQ_CONFIG_DIR=$TMP/not-a-dir
    out=$(req_project_activate "$a" 2>&1); status=$?
    assert_eq "1" "$status" "an unwritable central directory fails softly"
    assert_contains "req: warning: the project state in $TMP/not-a-dir cannot be saved" "$out" "with a warning"
    assert_eq "1" "$(grep -c "warning" <<<"$out")" "printed once"
    req_project_activate "$a" 2>/dev/null
    assert_eq "" "$REQ_PROJECT_ID" "REQ_PROJECT_ID stays empty"
    REQ_CONFIG_DIR=$cfg
}

test_init_command() {
    echo "home: req init registers the project"
    local d=$TMP/initproj out
    mkdir -p "$d"
    out=$(cd "$d" && bash "$ROOT/bin/req" init 2>&1); assert_eq "0" "$?" "req init succeeds"
    assert_contains "Initialized req project" "$out" "and reports it"
    assert_contains "Use :n to create a new request." "$out" "and suggests creating a request"
    assert_contains "workspace=." "$(<"$d/.req")" "the .req carries the workspace"
    assert_eq "$d/.req" "$(find "$d" -mindepth 1 | tr -d '\n')" "and init creates nothing else"
    assert_eq "initproj" "$(req_project_find_id "$d")" "the project is registered under its folder name"
    assert_eq "initproj" "$(req_current_get)" "and is the current one"
    out=$(cd "$d" && REQ_CONFIG_DIR=$TMP/not-a-dir bash "$ROOT/bin/req" init 2>&1)
    assert_contains "already exists" "$out" "init still refuses an existing project"
    rm -rf "$d/.req" "$d/requests"
    out=$(cd "$d" && REQ_CONFIG_DIR=$TMP/not-a-dir bash "$ROOT/bin/req" init 2>&1); assert_eq "0" "$?" "an unwritable ~/.req does not fail init"
    assert_contains "Initialized req project" "$out" "the project is still created"
    assert_contains "warning: the project state" "$out" "and the warning is shown"
}

test_workspace() {
    echo "home: workspace of the .req"
    local p=$TMP/ws out f status
    mkdir -p "$p/content/deep" "$p/other" "$p/outside-target"
    f=$p/.req
    printf 'plain' >"$p/afile"

    printf '# req project\nworkspace=.\n' >"$f"
    assert_eq "$p" "$(req_project_workspace "$f")" "workspace=. is the project folder"
    : >"$f"
    assert_eq "$p" "$(req_project_workspace "$f")" "an empty .req defaults to the project folder"
    printf 'api\nauth/\n# old entries\n' >"$f"
    assert_eq "$p" "$(req_project_workspace "$f")" "old directory entries are ignored"
    printf 'workspace = content \r\n' >"$f"
    assert_eq "$p/content" "$(req_project_workspace "$f")" "spaces and CRLF around the value are tolerated"

    local v
    for v in content content/ ./content content/deep ./content/./deep/ other/../content; do
        printf 'workspace=%s\n' "$v" >"$f"
        out=$(req_project_workspace "$f" 2>&1); status=$?
        assert_eq "0" "$status" "workspace=$v is accepted"
    done
    printf 'workspace=./content/deep/\n' >"$f"
    assert_eq "$p/content/deep" "$(req_project_workspace "$f")" "the path is printed normalized"
    printf 'workspace=other/../content\n' >"$f"
    assert_eq "$p/content" "$(req_project_workspace "$f")" "a .. that stays inside is resolved"

    # Refusals: each fails, explains itself and names the .req by its absolute path.
    check_refused() {
        printf 'workspace=%s\n' "$1" >"$f"
        out=$(req_project_workspace "$f" 2>&1); status=$?
        assert_eq "1" "$status" "workspace=$1 is refused"
        assert_contains "$f: workspace" "$out" "  and the message names the .req"
        assert_contains "$2" "$out" "  and says why"
    }
    check_refused "/etc" "must be a relative path"
    check_refused "$p/content" "must be a relative path"
    check_refused ".." "leaves the project folder"
    check_refused "content/../.." "leaves the project folder"
    check_refused "../ws/content" "leaves the project folder"
    check_refused "ghost" "does not exist"
    check_refused "content/ghost" "does not exist"
    check_refused "afile" "is not a directory"
    check_refused "afile/sub" "is not a directory"
    printf 'workspace=\n' >"$f"
    out=$(req_project_workspace "$f" 2>&1); assert_eq "1" "$?" "an empty value is refused"
    assert_contains "workspace is empty" "$out" "  and says to use ."

    ln -s "$p/outside-target" "$p/linked"
    ln -s content "$p/inner-link"
    check_refused "linked" "symbolic link"
    check_refused "inner-link" "symbolic link"
    check_refused "inner-link/deep" "symbolic link"
    check_refused "linked/../content" "symbolic link"
    check_refused "content/../linked" "symbolic link"

    out=$(req_project_workspace "$p/none/.req" 2>&1); assert_eq "1" "$?" "a missing .req fails"
    assert_contains "project file not found" "$out" "  with a message"

    # The project folder itself may be reached through a link: only the workspace path is checked.
    ln -s "$p" "$TMP/ws-link"
    printf 'workspace=content\n' >"$f"
    assert_eq "$p/content" "$(req_project_workspace "$TMP/ws-link/.req")" "a project folder reached through a link works"
    unset -f check_refused
}

test_kv_read
test_kv_check
test_kv_write
test_central_dir
test_projects
test_current
test_cursor
test_activate
test_init_command
test_workspace
test_summary
