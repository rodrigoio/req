#!/usr/bin/env bash
# store.sh - request persistence (<name>.<method>.json) and the .req project file.
#
# Request format:
#   {"name": "list-users", "method": "GET", "url": "https://api/users",
#    "description": "...", "headers": {}, "query": {}, "parameters": {}, "raw_data": ...}
#
# - `name` is a slug (lowercase letters, digits and hyphens) identical to the
#   file name; it is also the label shown in the menu.
# - `name`, `method` and `url` are required; the other fields are optional.
# - headers, query and parameters are objects with simple values (string,
#   number or boolean).
# - raw_data is the raw body: an object or list (JSON) or a string (any other text).
# Any unknown field or wrong type invalidates the request; the file is never
# changed, the error is only reported.

REQ_METHODS=(GET POST PUT PATCH DELETE)
REQ_PROJECT_FILE=.req
REQ_PROJECT_DEFAULT_DIR=requests

# Content checks (independent of the file name): prints one problem per line.
# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
REQ_SCHEMA_JQ='
def scalar: type == "string" or type == "number" or type == "boolean";
def check_map($lbl; $item):
    if type != "object" then "field \"\($lbl)\" must be an object"
    else to_entries[] | select((.value | scalar) | not)
         | "\($item) \"\(.key)\": the value must be a string, number or boolean" end;
["name", "method", "url", "description", "headers", "query", "parameters", "raw_data"] as $allowed
| if type != "object" then "the root must be an object"
  else
    (keys[] | select(. as $k | $allowed | index($k) | not)
        | if . == "data_parameter" then "field \"data_parameter\" was renamed to \"parameters\""
          elif . == "data_string" then "field \"data_string\" was renamed to \"raw_data\""
          else "unknown field \"\(.)\" (allowed: \($allowed | join(", ")))" end),
    (if (.name | type) != "string" then "field \"name\" is required (string)"
     elif (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)
         then "field \"name\" must be a slug: lowercase letters, digits and hyphens (e.g. list-users)"
     else empty end),
    (if (.method | type) != "string" then "field \"method\" is required (string)" else empty end),
    (if (.url | type) != "string" or .url == "" then "field \"url\" is required (string)" else empty end),
    (if has("description") and (.description | type) != "string"
         then "field \"description\" must be a string" else empty end),
    (if has("headers") then
        (.headers | check_map("headers"; "header")),
        (if (.headers | type) == "object" then
            .headers | to_entries[]
            | if (.key | test("^[A-Za-z0-9!#$%&*+.^_|~-]+$") | not)
                  then "header \"\(.key)\": invalid name"
              elif (.value | type) == "string" and (.value | test("[\r\n]"))
                  then "header \"\(.key)\": the value must not contain line breaks"
              else empty end
         else empty end)
     else empty end),
    (if has("query") then (.query | check_map("query"; "query")) else empty end),
    (if has("parameters") then (.parameters | check_map("parameters"; "parameters")) else empty end),
    (if has("raw_data") and ((.raw_data | type) as $t | $t != "object" and $t != "array" and $t != "string")
         then "field \"raw_data\" must be an object, a list or a string" else empty end)
  end'

# req_valid_method <method> - succeeds for a supported method (any case).
req_valid_method() {
    local m
    for m in "${REQ_METHODS[@]}"; do
        [[ ${1^^} == "$m" ]] && return 0
    done
    return 1
}

# req_valid_name <name> - slug: lowercase letters, digits and hyphens (e.g. list-users).
req_valid_name() {
    [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# req_request_filename <name> <method> - prints "<name>.<lowercase method>.json".
req_request_filename() {
    printf '%s.%s.json' "$1" "${2,,}"
}

# req_parse_filename <file> - prints "<name>\t<METHOD>", or fails if the file
# does not follow <slug>.<method>.json with a supported method.
req_parse_filename() {
    local base=${1##*/} stem method
    [[ $base == *.*.json ]] || return 1
    stem=${base%.json}
    method=${stem##*.}
    req_valid_method "$method" || return 1
    req_valid_name "${stem%.*}" || return 1
    printf '%s\t%s\n' "${stem%.*}" "${method^^}"
}

# Full check in a single jq call: the first two output lines are name and method
# (empty when missing or not a string), the rest are content problems, one per line.
REQ_CHECK_JQ='
(if type == "object" then
    (.name   | if type == "string" then gsub("[\r\n]"; " ") else "" end),
    (.method | if type == "string" then gsub("[\r\n]"; " ") else "" end)
 else "", "" end),
('"$REQ_SCHEMA_JQ"')'

# Request fields for display, as "tag NUL value NUL" records.
REQ_FIELDS_JQ='
(["name", (.name // "")], ["method", (.method // "")], ["url", (.url // "")],
 ["description", (.description // "")],
 ((.headers // {})        | to_entries[] | ["h", "\(.key): \(.value)"]),
 ((.query // {})          | to_entries[] | ["q", "\(.key)=\(.value)"]),
 ((.parameters // {}) | to_entries[] | ["p", "\(.key)=\(.value)"]))
| .[] | (., "\u0000")'

REQ_F_NAME=""; REQ_F_METHOD=""; REQ_F_URL=""; REQ_F_DESC=""
REQ_F_HEADERS=(); REQ_F_QUERY=(); REQ_F_PARAMS=()

# shellcheck disable=SC2034  # REQ_F_* are read by nav.sh
# req_request_fields <file> - reads the fields of an already validated request in
# a single jq call and fills REQ_F_NAME, REQ_F_METHOD, REQ_F_URL, REQ_F_DESC and
# the arrays REQ_F_HEADERS ("key: value"), REQ_F_QUERY and REQ_F_PARAMS ("key=value").
req_request_fields() {
    local tag val
    REQ_F_NAME=""; REQ_F_METHOD=""; REQ_F_URL=""; REQ_F_DESC=""
    REQ_F_HEADERS=(); REQ_F_QUERY=(); REQ_F_PARAMS=()
    while IFS= read -r -d '' tag && IFS= read -r -d '' val; do
        case $tag in
            name)        REQ_F_NAME=$val ;;
            method)      REQ_F_METHOD=${val^^} ;;
            url)         REQ_F_URL=$val ;;
            description) REQ_F_DESC=$val ;;
            h)           REQ_F_HEADERS+=("$val") ;;
            q)           REQ_F_QUERY+=("$val") ;;
            p)           REQ_F_PARAMS+=("$val") ;;
        esac
    done < <(jq -j "$REQ_FIELDS_JQ" "$1")
}

# req_request_check <file> - validates the JSON, fields, types and consistency
# with the file name. Prints each problem to stderr; succeeds if there are none.
# Invalid JSON is only reported, the file is never changed.
req_request_check() {
    local file=$1 abs out status line parsed stem fmethod jname jmethod
    local lines=() problems=()
    abs=$(req_abs_path "$file")     # messages carry the absolute path, easy to copy
    out=$(jq -r "$REQ_CHECK_JQ" "$file" 2>&1); status=$?
    if (( status != 0 )) && [[ $out == *"parse error"* ]]; then
        req_err "$abs: invalid JSON: $out"
        return 1
    elif (( status != 0 )); then
        req_err "$abs: cannot validate: $out"
        return 1
    fi
    mapfile -t lines <<<"$out"
    jname=${lines[0]}
    jmethod=${lines[1]}
    problems=("${lines[@]:2}")

    if [[ ${problems[0]-} != *"the root must be"* ]]; then
        if [[ -n $jmethod ]] && ! req_valid_method "$jmethod"; then
            problems+=("method \"$jmethod\" is not supported (use ${REQ_METHODS[*]})")
        fi
        if parsed=$(req_parse_filename "$file"); then
            stem=${parsed%%$'\t'*}
            fmethod=${parsed#*$'\t'}
            if [[ -n $jname && $jname != "$stem" ]]; then
                problems+=("field \"name\" (\"$jname\") differs from the file name (\"$stem\")")
            fi
            if [[ -n $jmethod ]] && req_valid_method "$jmethod" && [[ $fmethod != "${jmethod^^}" ]]; then
                problems+=("method \"$jmethod\" differs from the file name ($fmethod)")
            fi
        else
            problems+=("file name does not follow <slug>.<method>.json")
        fi
    fi

    (( ${#problems[@]} == 0 )) && return 0
    for line in "${problems[@]}"; do
        req_err "$abs: $line"
    done
    return 1
}

# req_request_template <name> <method> <url> - prints a new request as JSON.
req_request_template() {
    jq -n --arg name "$1" --arg method "${2^^}" --arg url "$3" '{
        name: $name, method: $method, url: $url, description: "",
        headers: {}, query: {}, parameters: {}
    }'
}

# req_request_write <directory> <name> <method> <url> [json]
# Atomically writes the request as valid JSON and prints the created path.
# [json] carries the optional fields (description, headers, query, parameters);
# name, method and url come from the arguments and take precedence. If the
# result fails validation, nothing is written.
req_request_write() {
    local dir=$1 name=$2 method=$3 url=$4 json=${5-} target tmp problems line
    req_valid_name "$name" || {
        req_err "invalid name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"; return 1; }
    req_valid_method "$method" || {
        req_err "invalid method: \"$method\" (use ${REQ_METHODS[*]})"; return 1; }
    [[ -n $url ]] || { req_err "the url is required"; return 1; }
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }

    [[ -n $json ]] || json=$(req_request_template "$name" "$method" "$url")
    target=$dir/$(req_request_filename "$name" "$method")
    tmp=$(mktemp "$dir/.req.XXXXXX") || { req_err "cannot write to $dir"; return 1; }
    if ! jq --arg name "$name" --arg method "${method^^}" --arg url "$url" \
            '{name: $name, method: $method, url: $url} + del(.name, .method, .url)' <<<"$json" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        req_err "the JSON of request \"$name\" is invalid; nothing was written"
        return 1
    fi
    problems=$(jq -r "$REQ_SCHEMA_JQ" "$tmp") || {
        rm -f "$tmp"; req_err "failed to validate request \"$name\""; return 1; }
    if [[ -n $problems ]]; then
        rm -f "$tmp"
        while IFS= read -r line; do
            req_err "request \"$name\": $line"
        done <<<"$problems"
        return 1
    fi
    mv "$tmp" "$target" && printf '%s\n' "$target"
}

# req_request_get <file> <field> - prints a field's value (raw text).
# Missing fields become {} (headers, query, parameters) or empty (others).
req_request_get() {
    case $2 in
        headers|query|parameters) jq -c --arg f "$2" '.[$f] // {}' "$1" ;;
        *) jq -r --arg f "$2" '.[$f] // ""' "$1" ;;
    esac
}

# req_project_find [directory] - prints the path of the .req in the directory (default: current).
req_project_find() {
    local file=${1:-.}/$REQ_PROJECT_FILE
    [[ -f $file ]] || return 1
    printf '%s\n' "$file"
}

# req_project_init [directory] - creates a .req and its default directory. Fails
# if the directory does not exist or already has a .req.
req_project_init() {
    local dir=${1:-.} file
    file=$dir/$REQ_PROJECT_FILE
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    [[ ! -e $file ]] || { req_err "$file already exists"; return 1; }
    if ! { mkdir -p "$dir/$REQ_PROJECT_DEFAULT_DIR" &&
            printf '# req project: one directory per line, relative to this file.\n%s\n' \
                "$REQ_PROJECT_DEFAULT_DIR" >"$file"; } 2>/dev/null; then
        req_err "cannot write to $dir"
        return 1
    fi
}

# req_project_add_dir <.req file> <name> - creates the directory next to the .req
# and lists it in the .req. Fails if the name is not a slug or is already listed.
req_project_add_dir() {
    local pfile=$1 name=$2 base listed
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    base=$(cd -P "$(dirname "$pfile")" && pwd)
    listed=$(req_project_dirs "$pfile" 2>/dev/null)
    if grep -qxF -- "$base/$name" <<<"$listed"; then
        req_err "\"$name\" is already listed in $pfile"
        return 1
    fi
    mkdir -p "$base/$name" 2>/dev/null || { req_err "cannot create $base/$name"; return 1; }
    # Make sure the last line ends with a newline before appending.
    if [[ -s $pfile && -n $(tail -c1 "$pfile") ]]; then printf '\n' >>"$pfile"; fi
    printf '%s\n' "$name" >>"$pfile"
}

# req_project_dirs <.req file> - prints the project directories, one per line.
# .req format: one directory per line, relative to the .req itself; blank lines
# and lines starting with # are ignored. Missing entries are reported to stderr,
# skipped, and the final status is 1.
req_project_dirs() {
    local file=$1 base line dir status=0
    [[ -f $file ]] || { req_err "project file not found: $file"; return 1; }
    base=$(cd -P "$(dirname "$file")" && pwd)
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line || $line == \#* ]] && continue
        line=${line%/}
        if [[ $line == /* ]]; then dir=$line; else dir=$base/$line; fi
        if [[ -d $dir ]]; then
            printf '%s\n' "$dir"
        else
            req_err "$file: listed directory does not exist: $line"
            status=1
        fi
    done <"$file"
    return "$status"
}

# req_list_dir <directory> - lists the contents, subdirectories first and then
# requests, each group in alphabetical order. One TAB-separated entry per line:
#   d  <name>             <path>
#   r  <name>  <METHOD>   <path>
# Hidden items and files not matching <slug>.<method>.json are ignored.
req_list_dir() {
    local dir=${1%/} entry name parsed
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    (
        shopt -s nullglob
        export LC_ALL=C
        for entry in "$dir"/*/; do
            entry=${entry%/}
            printf 'd\t%s\t%s\n' "${entry##*/}" "$entry"
        done | sort -t$'\t' -k2,2
        for entry in "$dir"/*.json; do
            [[ -f $entry ]] || continue
            parsed=$(req_parse_filename "$entry") || continue
            name=${parsed%%$'\t'*}
            printf 'r\t%s\t%s\t%s\n' "$name" "${parsed#*$'\t'}" "$entry"
        done | sort -t$'\t' -k2,2 -k3,3
    )
}
