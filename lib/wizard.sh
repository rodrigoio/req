#!/usr/bin/env bash
# wizard.sh - interactive prompts to create, edit and duplicate requests and directories.
# All answers come from REQ_INPUT_FD, so the flows can be driven by tests.
#
# Conventions: an empty name (or end of input) cancels a flow; any other prompt
# accepts its default with Enter.

REQ_REPLY_JSON="{}"     # last object built by req_ask_pairs / req_ask_preset
REQ_PRESET=none         # format chosen by the last req_ask_preset: json, text, html or none
REQ_LAST_FILE=""        # last request file written by a wizard
REQ_LAST_DIR=""         # last directory created by a wizard

# req_cancelled - prints the cancellation notice and fails.
req_cancelled() {
    printf 'Cancelled.\n'
    return 1
}

# req_ask_name <default> [what] - asks for a slug; empty cancels (without default).
req_ask_name() {
    local def=${1-} what=${2:-Name} label
    label="$what (a slug, e.g. list-users)"
    [[ -z $def ]] && label+=" - empty to cancel"
    while :; do
        req_prompt "$label" "$def" || return 1
        [[ -n $REQ_REPLY ]] || return 1
        req_valid_name "$REQ_REPLY" && return 0
        req_err "invalid name: use lowercase letters, digits and hyphens"
    done
}

# req_ask_method [default] - asks for an HTTP method.
req_ask_method() {
    local def=${1:-GET}
    while :; do
        req_prompt "Method (${REQ_METHODS[*]})" "$def" || return 1
        if req_valid_method "$REQ_REPLY"; then
            REQ_REPLY=${REQ_REPLY^^}
            return 0
        fi
        req_err "invalid method: $REQ_REPLY"
    done
}

# req_ask_url [default] - asks for the url; it cannot be empty.
req_ask_url() {
    while :; do
        req_prompt "URL" "${1-}" || return 1
        [[ -n $REQ_REPLY ]] && return 0
        req_err "the url is required"
    done
}

# req_preset_headers <json|text|html|none> - prints the headers object of a format preset.
req_preset_headers() {
    local ct
    case $1 in
        json) ct=application/json ;;
        text) ct=text/plain ;;
        html) ct=text/html ;;
        *)    printf '{}'; return 0 ;;
    esac
    jq -cn --arg ct "$ct" '{"Content-Type": $ct, "Accept": $ct}'
}

# req_ask_preset - asks for a popular format (json, text, html); the matching
# headers object ends up in REQ_REPLY_JSON and the choice in REQ_PRESET.
req_ask_preset() {
    local choice
    while :; do
        req_prompt "Format preset: 1) json  2) text  3) html  4) none" "4" || return 1
        case ${REQ_REPLY,,} in
            1|json) choice=json ;;
            2|text) choice=text ;;
            3|html) choice=html ;;
            4|none) choice=none ;;
            *) req_err "choose 1-4"; continue ;;
        esac
        REQ_PRESET=$choice
        REQ_REPLY_JSON=$(req_preset_headers "$choice")
        return 0
    done
}

# req_ask_pairs <title> <separator> <json> - edits an object of simple values.
# One "key<separator>value" per line sets an entry, "-key" removes it, an empty
# line finishes. The resulting object ends up in REQ_REPLY_JSON.
req_ask_pairs() {
    local title=$1 sep=$2 json=${3:-"{}"} line key val
    printf '%s: key%svalue per line, "-key" removes, empty line to finish\n' "$title" "$sep"
    while :; do
        req_prompt "  $title" "" || break
        line=$(req_trim "$REQ_REPLY")
        [[ -n $line ]] || break
        if [[ $line == -* ]]; then
            key=$(req_trim "${line#-}")
            json=$(jq -c --arg k "$key" 'del(.[$k])' <<<"$json")
            continue
        fi
        if [[ $line != *"$sep"* ]]; then
            req_err "expected key${sep}value"
            continue
        fi
        key=$(req_trim "${line%%"$sep"*}")
        val=$(req_trim "${line#*"$sep"}")
        if [[ -z $key ]]; then
            req_err "the key cannot be empty"
            continue
        fi
        json=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$json")
    done
    REQ_REPLY_JSON=$json
}

# req_raw_text <json value> - prints raw_data as editable text: indented JSON for an
# object or list, the string itself otherwise ("" when there is no value).
req_raw_text() {
    [[ -n ${1-} ]] || return 0
    if [[ $(jq -r type <<<"$1") == string ]]; then jq -r . <<<"$1"; else jq . <<<"$1"; fi
}

# req_ask_raw_data <current> [ask] - edits the raw body (raw_data). <current> is the
# JSON value now stored ("" when none). The text is edited in the external editor
# (req_edit_text), or on one prompt line when there is no editor. An empty result
# clears raw_data. An object or list is stored as native JSON; any other text is
# stored as a string, but when [ask] is 1 (the default) the user is first offered to
# edit it again, since it was probably meant to be JSON. On success REQ_REPLY_JSON
# holds the new JSON value ("" = clear) and the status is 0; status 1 keeps it as is.
req_ask_raw_data() {
    local text native status ask=${2:-1}
    text=$(req_raw_text "${1-}")
    while :; do
        if req_edit_text "$text" .json; then
            text=$REQ_EDIT_TEXT
        else
            status=$?
            if (( status == 1 )); then req_err "the editor failed; raw data left as it was"; return 1; fi
            local def=$text
            [[ $def == *$'\n'* ]] && def=$(jq -c . <<<"$def" 2>/dev/null || tr '\n' ' ' <<<"$def")
            req_prompt "Raw data on one line (- clears; set an editor with \$EDITOR for more)" "$def" || return 1
            text=$REQ_REPLY
            [[ $text == - ]] && text=""
        fi
        if [[ -z $(req_trim "$text") ]]; then REQ_REPLY_JSON=""; return 0; fi
        native=$(jq -c 'select(type == "object" or type == "array")' <<<"$text" 2>/dev/null)
        if [[ -n $native ]]; then REQ_REPLY_JSON=$native; return 0; fi
        if (( ask )); then
            req_prompt "Not a JSON object or list: 1) edit again  2) keep as text  3) discard" "1" || return 1
            case ${REQ_REPLY,,} in
                1|e|edit) continue ;;
                3|d|discard) return 1 ;;
                2|k|keep|t|text) ;;
                *) req_err "choose 1-3"; continue ;;
            esac
        fi
        REQ_REPLY_JSON=$(jq -cn --arg t "$text" '$t')
        return 0
    done
}

# req_wizard_new <directory> - creates a request in the directory.
req_wizard_new() {
    local dir=$1 name method url desc="" headers="{}" query="{}" params="{}" raw="" json target
    req_ask_name "" || { req_cancelled; return 1; }
    name=$REQ_REPLY
    req_ask_method GET || { req_cancelled; return 1; }
    method=$REQ_REPLY
    target=$dir/$(req_request_filename "$name" "$method")
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    req_ask_url "" || { req_cancelled; return 1; }
    url=$REQ_REPLY

    if req_confirm "Add optional fields (description, headers, query, parameters)?" n; then
        req_prompt "Description" "" && desc=$REQ_REPLY
        REQ_PRESET=none
        req_ask_preset && headers=$REQ_REPLY_JSON
        req_ask_pairs "Headers" ":" "$headers" && headers=$REQ_REPLY_JSON
        req_ask_pairs "Query" "=" "{}" && query=$REQ_REPLY_JSON
        case $method in
            POST|PUT|PATCH)
                # With a format preset the body is usually raw: offer the editor first, and
                # ask for form parameters only when it is declined (or there is no preset).
                if [[ $REQ_PRESET != none ]] &&
                   req_confirm "Write the body (raw data) in your editor?" y; then
                    # Only JSON is questioned when the text is not an object or list.
                    local ask=0; [[ $REQ_PRESET == json ]] && ask=1
                    req_ask_raw_data "" "$ask" && raw=$REQ_REPLY_JSON
                else
                    req_ask_pairs "Parameters" "=" "{}" && params=$REQ_REPLY_JSON
                fi ;;
        esac
    fi

    json=$(jq -cn --arg d "$desc" --argjson h "$headers" --argjson q "$query" --argjson p "$params" \
        --arg r "$raw" \
        '{description: $d, headers: $h, query: $q, parameters: $p}
         + (if $r == "" then {} else {raw_data: ($r | fromjson)} end)')
    REQ_LAST_FILE=$(req_request_write "$dir" "$name" "$method" "$url" "$json") || return 1
    printf 'Created %s\n' "$REQ_LAST_FILE"
}

# req_edit_show <json> - prints the numbered fields of the request being edited.
req_edit_show() {
    jq -r '
        def count: length | if . == 1 then "1 entry" else "\(.) entries" end;
        "  1) name         \(.name)",
        "  2) method       \(.method)",
        "  3) url          \(.url)",
        "  4) description  \(.description // "")",
        "  5) headers      \((.headers // {}) | count)",
        "  6) query        \((.query // {}) | count)",
        "  7) parameters   \((.parameters // {}) | count)",
        "  8) raw data     \(.raw_data // "" | if . == "" then "none"
                              elif type == "string" then "text, \(length) chars"
                              elif type == "array" then "JSON list, \(length) items"
                              else "JSON object, \(length) keys" end)"' <<<"$1"
}

# req_wizard_edit <file> - field menu for a request. Changing the name or the
# method renames the file. Returns 0 after saving and 1 when cancelled.
req_wizard_edit() {
    local file=$1 dir json name method url target fields newfile cur ask
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot edit an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    json=$(<"$file")

    while :; do
        printf 'Editing %s\n' "${file##*/}"
        req_edit_show "$json"
        req_prompt "Field to edit (1-8), s to save, q to cancel" "" || { req_cancelled; return 1; }
        case ${REQ_REPLY,,} in
            1) req_ask_name "$(jq -r .name <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.name = $v' <<<"$json") ;;
            2) req_ask_method "$(jq -r .method <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.method = $v' <<<"$json") ;;
            3) req_ask_url "$(jq -r .url <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.url = $v' <<<"$json") ;;
            4) cur=$(jq -r '.description // ""' <<<"$json")
               if req_prompt "Description (- clears)" "$cur"; then
                   [[ $REQ_REPLY == - ]] && REQ_REPLY=""
                   json=$(jq -c --arg v "$REQ_REPLY" '.description = $v' <<<"$json")
               fi ;;
            5) req_ask_pairs "Headers" ":" "$(jq -c '.headers // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.headers = $v' <<<"$json") ;;
            6) req_ask_pairs "Query" "=" "$(jq -c '.query // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.query = $v' <<<"$json") ;;
            7) req_ask_pairs "Parameters" "=" "$(jq -c '.parameters // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.parameters = $v' <<<"$json") ;;
            8) cur=$(jq -c '.raw_data // ""' <<<"$json")
               [[ $cur == '""' ]] && cur=""
               # Free text is not questioned when the request declares a non-JSON Content-Type.
               ask=$(jq -r '[(.headers // {}) | to_entries[] | select(.key | ascii_downcase == "content-type")
                             | .value | tostring | ascii_downcase] as $c
                            | if ($c | length) > 0 and ($c | all(contains("json") | not)) then 0 else 1 end' <<<"$json")
               if req_ask_raw_data "$cur" "$ask"; then
                   if [[ -z $REQ_REPLY_JSON ]]; then
                       json=$(jq -c 'del(.raw_data)' <<<"$json")
                   else
                       json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.raw_data = $v' <<<"$json")
                   fi
               fi ;;
            s|save)
                name=$(jq -r .name <<<"$json"); method=$(jq -r '.method | ascii_upcase' <<<"$json")
                url=$(jq -r .url <<<"$json")
                target=$dir/$(req_request_filename "$name" "$method")
                if [[ $target != "$file" && -e $target ]]; then
                    req_err "$target already exists"
                    continue
                fi
                fields=$(jq -c 'del(.name, .method, .url)' <<<"$json")
                newfile=$(req_request_write "$dir" "$name" "$method" "$url" "$fields") || continue
                [[ $newfile == "$file" ]] || rm -f "$file"
                REQ_LAST_FILE=$newfile
                printf 'Saved %s\n' "$newfile"
                return 0 ;;
            q|quit|cancel) req_cancelled; return 1 ;;
            *) req_err "choose 1-8, s or q" ;;
        esac
    done
}

# req_wizard_duplicate <file> - copies a request under a new name, then opens the
# edit menu on the copy. Cancelling the edit keeps the copy.
req_wizard_duplicate() {
    local file=$1 dir name method url fields target
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot duplicate an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    name=$(req_request_get "$file" name)
    method=$(req_request_get "$file" method); method=${method^^}
    url=$(req_request_get "$file" url)
    fields=$(jq -c 'del(.name, .method, .url)' "$file")

    while :; do
        req_ask_name "$name-copy" || { req_cancelled; return 1; }
        target=$dir/$(req_request_filename "$REQ_REPLY" "$method")
        [[ ! -e $target ]] && break
        req_err "$target already exists"
    done
    REQ_LAST_FILE=$(req_request_write "$dir" "$REQ_REPLY" "$method" "$url" "$fields") || return 1
    printf 'Created %s\n' "$REQ_LAST_FILE"
    req_wizard_edit "$REQ_LAST_FILE"
    return 0
}

# req_wizard_mkdir <parent> [.req file] [name] - creates a directory. With a .req
# file (the project root) the directory is created next to it and listed in it;
# otherwise it is created inside <parent>. The name is asked for unless given.
req_wizard_mkdir() {
    local parent=$1 pfile=${2-} name=${3-} base
    if [[ -z $name ]]; then
        req_ask_name "" "Directory name" || { req_cancelled; return 1; }
        name=$REQ_REPLY
    fi
    if [[ -n $pfile ]]; then
        req_project_add_dir "$pfile" "$name" || return 1
        base=$(cd -P "$(dirname "$pfile")" && pwd)
        REQ_LAST_DIR=$base/$name
    else
        req_valid_name "$name" || {
            req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
            return 1; }
        [[ ! -e $parent/$name ]] || { req_err "$parent/$name already exists"; return 1; }
        mkdir "$parent/$name" 2>/dev/null || { req_err "cannot create $parent/$name"; return 1; }
        REQ_LAST_DIR=$parent/$name
    fi
    printf 'Created directory %s\n' "$REQ_LAST_DIR"
}

# req_wizard_rename_dir <directory> <.req file> [name] - renames a directory (the
# last component of its path); the name is asked for unless given. When the .req
# lists the directory, its entry is updated too (relative when the directory is
# under the .req, absolute otherwise). Returns 0 after renaming; REQ_LAST_DIR is the
# new path. An unchanged name returns 1 without touching anything.
req_wizard_rename_dir() {
    local dir=${1%/} pfile=$2 name=${3-} target base entry listed=0
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    if [[ -z $name ]]; then
        req_ask_name "${dir##*/}" "New directory name" || { req_cancelled; return 1; }
        name=$REQ_REPLY
    fi
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    dir=$(req_abs_path "$dir")
    target=${dir%/*}/$name
    if [[ $target == "$dir" ]]; then
        printf 'Name unchanged.\n'
        return 1
    fi
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    req_project_has_entry "$pfile" "$dir" && listed=1
    mv -- "$dir" "$target" 2>/dev/null || { req_err "cannot rename $dir"; return 1; }
    if (( listed )); then
        base=$(cd -P "$(dirname "$pfile")" && pwd)
        entry=$target
        [[ $target == "$base"/* ]] && entry=${target#"$base"/}
        # The old path is gone, so the entry is found through the saved path.
        if ! req_project_replace_entry "$pfile" "$dir" "$entry"; then
            mv -- "$target" "$dir"
            req_err "could not update $pfile; the rename was undone"
            return 1
        fi
    fi
    REQ_LAST_DIR=$target
    printf 'Renamed %s to %s\n' "$dir" "$target"
}

# req_wizard_copy_dir <directory> <.req file> [name] - copies a directory with everything
# inside it, next to the original. The name is asked for (default <name>-copy) unless
# given. When the .req lists the original, the copy is listed too (relative when it is
# under the .req, absolute otherwise). Returns 0 after copying; REQ_LAST_DIR is the copy.
req_wizard_copy_dir() {
    local dir=${1%/} pfile=$2 name=${3-} target base entry listed=0
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    dir=$(req_abs_path "$dir")
    if [[ -z $name ]]; then
        while :; do
            req_ask_name "${dir##*/}-copy" "Name of the copy" || { req_cancelled; return 1; }
            [[ ! -e ${dir%/*}/$REQ_REPLY ]] && break
            req_err "${dir%/*}/$REQ_REPLY already exists"
        done
        name=$REQ_REPLY
    fi
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    target=${dir%/*}/$name
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    req_project_has_entry "$pfile" "$dir" && listed=1
    cp -RP -- "$dir" "$target" 2>/dev/null || {
        rm -rf -- "$target"; req_err "cannot copy $dir"; return 1; }
    if (( listed )); then
        base=$(cd -P "$(dirname "$pfile")" && pwd)
        entry=$target
        [[ $target == "$base"/* ]] && entry=${target#"$base"/}
        req_project_append_entry "$pfile" "$entry" 2>/dev/null || {
            rm -rf -- "$target"; req_err "could not update $pfile; the copy was removed"; return 1; }
    fi
    REQ_LAST_DIR=$target
    printf 'Copied %s to %s\n' "$dir" "$target"
}
