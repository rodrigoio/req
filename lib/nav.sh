#!/usr/bin/env bash
# nav.sh - interactive navigation: directory and request menu, details screen.
#
# The menu is redrawn in place (the cursor moves up and erases the previous block) without clearing the screen: a
# request's result stays visible and the menu is redrawn right below it; the screen is cleared only when the menu starts
# and on Ctrl-L. Outside a terminal nothing is erased (tests).
# Keys: up/down move the selection, Enter opens/runs, Esc and q go back (at the root Esc does nothing and q quits),
# Ctrl-L clears the screen, h opens the help, v shows the last response in a pager, ":" enters command mode (cmd.sh).
# The environment menu (:env) is a view of its own with its own keys: up/down, Enter, Esc and q.

REQ_RAW_MAX_LINES=15    # lines of raw_data shown on the details screen
REQ_PROBLEMS_MAX_LINES=10   # problems listed on the details of an invalid request
REQ_ESC_TIMEOUT=0.05    # wait for bytes after ESC to tell an arrow key from a bare Esc
REQ_INPUT_FD=0          # descriptor the keys are read from
REQ_KEY=""              # last key read: up, down, enter, esc, or the character itself

REQ_SCREEN_LINES=()     # lines of the current block
REQ_SCREEN_DRAWN=0      # rows of the block already printed in the terminal
REQ_SCREEN_EXTRA=0      # rows beyond one per line, from long lines that wrap
REQ_BASE_EXTRA=0

REQ_NAV_PROJECT=""      # name of the project (the folder of the .req), shown in the header
REQ_NAV_ROOT=""         # the menu root: the workspace of the project (set only by req_nav_root)
REQ_CUR_DIR=""          # directory being shown ("" = project root)
REQ_STACK_DIR=()        # navigation stack: previous directories and selections
REQ_STACK_SEL=()
REQ_VIEW=list           # list | detail | help | config | env
REQ_DETAIL_FILE=""
REQ_DETAIL_VALID=0
REQ_ENV_SEL=0           # selected row of the environment menu, an index of REQ_ENV_CHOICES
REQ_ENV_TOP=0           # first row of the environment menu that is shown
REQ_ENV_BACK=list       # the view the environment menu returns to (list or detail)
REQ_ENV_NEW_LABEL="+ new environment"     # the last row of the environment menu

REQ_ITEM_KIND=()        # d | r, per item of the current list
REQ_ITEM_LABEL=()
REQ_ITEM_METHOD=()
REQ_ITEM_PATH=()
REQ_SEL=0
REQ_TOP=0

REQ_NAV_DIRTY=1         # 1 when the screen must be rebuilt (0 while only the prompt changes)
REQ_BASE_LINES=()       # last built screen, reused while nothing but the prompt changes

# req_read_key - reads a key into REQ_KEY. Fails (status 1) at end of input.
req_read_key() {
    local k rest=""
    REQ_KEY=""
    IFS= read -rsn1 -u "$REQ_INPUT_FD" k || return 1
    case $k in
        ''|$'\r') REQ_KEY=enter ;;
        $'\177'|$'\b') REQ_KEY=backspace ;;
        $'\e')
            IFS= read -rsn2 -t "$REQ_ESC_TIMEOUT" -u "$REQ_INPUT_FD" rest
            case $rest in
                '[A'|'OA') REQ_KEY=up ;;
                '[B'|'OB') REQ_KEY=down ;;
                '')        REQ_KEY=esc ;;
                *)         REQ_KEY=other ;;
            esac ;;
        *) REQ_KEY=$k ;;
    esac
    return 0
}

# --- screen ------------------------------------------------------------------

req_screen_erase() {
    if [[ -t 1 && $REQ_SCREEN_DRAWN -gt 0 ]]; then
        printf '\033[%dA\r\033[J' "$REQ_SCREEN_DRAWN"
    fi
    REQ_SCREEN_DRAWN=0
}

# req_nav_clear_screen - Ctrl-L: clears the visible screen (the scrollback is kept, as in a shell), so the
# next draw puts the menu at the top. REQ_SCREEN_DRAWN goes to 0: the rows the erase would move up over are
# gone. Nothing is printed outside a terminal.
req_nav_clear_screen() {
    [[ -t 1 ]] && printf '\033[H\033[2J'
    REQ_SCREEN_DRAWN=0
    return 0
}

req_screen_draw() {
    req_screen_erase
    printf '%s\n' "${REQ_SCREEN_LINES[@]}"
    [[ -t 1 ]] && REQ_SCREEN_DRAWN=$(( ${#REQ_SCREEN_LINES[@]} + REQ_SCREEN_EXTRA ))
    return 0
}

# req_screen_add_long <text> - appends a line that is never truncated (so it can be copied whole); the extra
# terminal rows of a wrap are counted for the redraw.
req_screen_add_long() {
    local cols
    cols=$(req_term_cols)
    REQ_SCREEN_LINES+=("$1")
    (( ${#1} > cols )) && REQ_SCREEN_EXTRA=$(( REQ_SCREEN_EXTRA + (${#1} - 1) / cols ))
    return 0
}

req_marker() {
    if req_utf8; then printf '▸'; else printf '>'; fi
}

# --- data -----------------------------------------------------------------

req_nav_rel() {
    printf '%s' "${1#"$REQ_NAV_ROOT"/}"
}

# req_nav_root <.req file> - sets REQ_NAV_ROOT, the workspace: the directory the menu starts in and never
# leaves, and the single place that knows where the root is. Fails, with the reason already printed, when
# the workspace is not valid.
req_nav_root() {
    REQ_NAV_ROOT=$(req_project_workspace "$1") || { REQ_NAV_ROOT=""; return 1; }
}

req_nav_load() {
    local kind a b c
    REQ_ITEM_KIND=(); REQ_ITEM_LABEL=(); REQ_ITEM_METHOD=(); REQ_ITEM_PATH=()
    while IFS=$'\t' read -r kind a b c; do
        REQ_ITEM_KIND+=("$kind"); REQ_ITEM_LABEL+=("$a")
        if [[ $kind == d ]]; then
            REQ_ITEM_METHOD+=(""); REQ_ITEM_PATH+=("$b")
        else
            REQ_ITEM_METHOD+=("$b"); REQ_ITEM_PATH+=("$c")
        fi
    done < <(req_list_dir "${REQ_CUR_DIR:-$REQ_NAV_ROOT}")
    REQ_SEL=0
    REQ_TOP=0
}

req_nav_init() {
    local pfile=$1
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    req_nav_root "$pfile" || return 1
    REQ_NAV_PROJECT=$(req_abs_path "$(dirname "$pfile")"); REQ_NAV_PROJECT=${REQ_NAV_PROJECT##*/}
    REQ_CUR_DIR=""; REQ_STACK_DIR=(); REQ_STACK_SEL=()
    REQ_VIEW=list; REQ_DETAIL_FILE=""; REQ_DETAIL_VALID=0
    REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""; REQ_QUIT=0; REQ_NAV_DIRTY=1
    # shellcheck disable=SC2034  # REQ_STATUS is read by req_notification_status_lines (notification.sh)
    REQ_STATUS=""
    req_notification_register root req_notification_root_check     # a persistent notice, only for root
    req_nav_load
}

# req_nav_save_cursor - saves the menu position (directory and selected item, relative to the workspace) in
# the project's cursor file. Nothing without a registered project; a write that fails is ignored, the cursor
# is only a convenience.
req_nav_save_cursor() {
    local dir="" item=""
    [[ -n $REQ_PROJECT_ID && -n $REQ_NAV_ROOT ]] || return 0
    [[ -z $REQ_CUR_DIR ]] || dir=$(req_nav_rel "$REQ_CUR_DIR")
    (( ${#REQ_ITEM_PATH[@]} > REQ_SEL )) && item=$(req_nav_rel "${REQ_ITEM_PATH[REQ_SEL]}")
    req_cursor_save "$REQ_PROJECT_ID" "$dir" "$item" 2>/dev/null || true
    return 0
}

# req_nav_cursor_path_ok <relative path> - succeeds for "" or a plain relative path (no leading or trailing
# slash, no empty, "." or ".." component), so a hand-edited cursor file cannot lead outside the workspace.
req_nav_cursor_path_ok() {
    local parts comp
    [[ -z $1 ]] && return 0
    [[ $1 != /* && $1 != */ ]] || return 1
    IFS=/ read -ra parts <<<"$1"
    for comp in "${parts[@]}"; do
        [[ -n $comp && $comp != . && $comp != .. ]] || return 1
    done
}

# req_nav_restore_cursor - puts the menu where the cursor file says (the Esc stack is rebuilt on the way
# down). A directory that is gone leads to its nearest existing ancestor, an item that is gone to the first
# one; a missing or invalid file, no project or restore_cursor=no leave the root. Never an error. Call it
# right after req_nav_init.
req_nav_restore_cursor() {
    local file dir item path comp i found parts
    [[ -n $REQ_PROJECT_ID && -n $REQ_NAV_ROOT ]] || return 0
    [[ $(req_config_get restore_cursor) == yes ]] || return 0
    file=$(req_cursor_file "$REQ_PROJECT_ID")
    [[ -f $file ]] || return 0
    dir=$(req_kv_get "$file" dir) || dir=""
    item=$(req_kv_get "$file" item) || item=""
    req_nav_cursor_path_ok "$dir" && req_nav_cursor_path_ok "$item" || return 0
    if [[ -n $dir ]]; then
        IFS=/ read -ra parts <<<"$dir"
        path=${REQ_CUR_DIR:-$REQ_NAV_ROOT}
        for comp in "${parts[@]}"; do
            path=$path/$comp; found=-1
            for i in "${!REQ_ITEM_PATH[@]}"; do
                [[ ${REQ_ITEM_KIND[i]} == d && ${REQ_ITEM_PATH[i]} == "$path" ]] && found=$i
            done
            if (( found < 0 )); then item=""; break; fi
            REQ_SEL=$found
            REQ_STACK_DIR+=("$REQ_CUR_DIR"); REQ_STACK_SEL+=("$REQ_SEL")
            REQ_CUR_DIR=$path
            req_nav_load
        done
    fi
    [[ -n $item ]] || return 0
    path=$REQ_NAV_ROOT/$item
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$path" ]] && REQ_SEL=$i
    done
    return 0
}

req_nav_refresh() {
    local want=$1 i
    req_nav_load
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$want" ]] && REQ_SEL=$i
    done
}

# --- screen building --------------------------------------------------

req_nav_crumb() {
    if [[ -z $REQ_CUR_DIR ]]; then printf '/'; else printf '/%s' "$(req_nav_rel "$REQ_CUR_DIR")"; fi
}

req_nav_build_list() {
    local n=${#REQ_ITEM_KIND[@]} cols rows visible i end width pos
    local c_dim c_bold c_reset c_sel tag label tail="" room
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    pos=""
    (( n > 0 )) && pos=" ($((REQ_SEL + 1))/$n)"
    # The project and the environment in use go after the position, when there is room. The logo takes 8 columns
    # (`{❯} Req ` with the space after it), and one stays free so the line never wraps.
    room=$(( cols - 9 - ${#pos} ))
    if [[ -n $REQ_NAV_PROJECT ]]; then
        tail="  $REQ_NAV_PROJECT @ ${REQ_ENV:-default}"
        if (( room - ${#tail} >= 12 )); then room=$(( room - ${#tail} )); else tail=""; fi
    fi
    [[ -n $REQ_LOGO ]] || req_logo
    REQ_SCREEN_LINES+=("${REQ_LOGO} $(req_trunc "$(req_nav_crumb)" "$room")${c_dim}${pos}${tail}${c_reset}")

    if (( n == 0 )); then
        REQ_SCREEN_LINES+=("  ${c_dim}(empty)${c_reset}")
    else
        # the bars at the top (REQ_NOTIFICATION_LINES, notification.sh) take rows from the list, and so does the header
        # (it carries the logo); one row stays free for the command prompt, which is drawn under the list
        visible=$(( rows - 3 - ${#REQ_NOTIFICATION_LINES[@]} )); (( visible < 3 )) && visible=3
        (( n < visible )) && visible=$n
        (( REQ_SEL < REQ_TOP )) && REQ_TOP=$REQ_SEL
        (( REQ_SEL >= REQ_TOP + visible )) && REQ_TOP=$(( REQ_SEL - visible + 1 ))
        end=$(( REQ_TOP + visible ))
        width=$(( cols - 10 ))
        for (( i = REQ_TOP; i < end; i++ )); do
            if [[ ${REQ_ITEM_KIND[i]} == d ]]; then
                tag="dir   "; label=$(req_trunc "${REQ_ITEM_LABEL[i]}/" "$width")
            else
                tag=$(printf '%-6s' "${REQ_ITEM_METHOD[i]}"); label=$(req_trunc "${REQ_ITEM_LABEL[i]}" "$width")
            fi
            if (( i == REQ_SEL )); then
                # The whole selected row is highlighted, which replaces the method color.
                REQ_SCREEN_LINES+=("${c_sel}$(req_marker) ${tag} ${label}${c_reset}")
            elif [[ ${REQ_ITEM_KIND[i]} == d ]]; then
                REQ_SCREEN_LINES+=("  ${c_dim}${tag}${c_reset} ${c_bold}${label}${c_reset}")
            else
                REQ_SCREEN_LINES+=("  $(req_method_color "${REQ_ITEM_METHOD[i]}")${tag}${c_reset} ${label}")
            fi
        done
    fi
}

# req_nav_build_detail - the open request's details; an invalid request shows its problems instead of the
# fields and does not run.
req_nav_build_detail() {
    local f=$REQ_DETAIL_FILE abs cols width c_dim c_bold c_reset problems line i
    local -a plist=()
    cols=$(req_term_cols); width=$(( cols - 4 ))
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    if ! problems=$(req_request_check "$f" 2>&1); then
        REQ_DETAIL_VALID=0
        abs=$(req_abs_path "$f")
        while IFS= read -r line; do
            line=${line#"req: error: $abs: "}
            line=${line#"req: error: "}
            plist+=("$line")
        done <<<"$problems"
        # pinned at the top: the first problem and how many more there are
        REQ_SCREEN_LINES+=("$(req_notification_bar "$(req_notification_more "invalid request: ${plist[0]}" $(( ${#plist[@]} - 1 )))")")
        REQ_SCREEN_LINES+=("$(req_color err)Invalid request:${c_reset}")
        req_screen_add_long "$abs"      # whole and on its own line, ready to copy
        for (( i = 0; i < ${#plist[@]} && i < REQ_PROBLEMS_MAX_LINES; i++ )); do
            REQ_SCREEN_LINES+=("  $(req_trunc "${plist[i]}" "$width")")
        done
        (( ${#plist[@]} > REQ_PROBLEMS_MAX_LINES )) &&
            REQ_SCREEN_LINES+=("  ... ($(( ${#plist[@]} - REQ_PROBLEMS_MAX_LINES )) more)")
        REQ_SCREEN_LINES+=("${c_dim}Fix the file and open it again.${c_reset}")
        return 0
    fi

    REQ_DETAIL_VALID=1
    req_request_fields "$f"
    # pinned at the top while the request is open: the address is not usable (placeholders are tolerated)
    if ! req_url_check "$REQ_F_URL"; then
        REQ_SCREEN_LINES+=("$(req_notification_bar "invalid address in the url: $REQ_URL_PROBLEM")")
    fi
    REQ_SCREEN_LINES+=("$(req_method_color "$REQ_F_METHOD")$(printf '%-6s' "$REQ_F_METHOD")${c_reset} ${c_bold}$(req_trunc "$REQ_F_NAME" $((cols - 9)))${c_reset}")
    REQ_SCREEN_LINES+=("  ${c_dim}url${c_reset}  $(req_trunc "$REQ_F_URL" $((width - 5)))")
    if [[ -n $REQ_F_DESC ]]; then
        REQ_F_DESC=${REQ_F_DESC//$'\n'/ }
        REQ_SCREEN_LINES+=("  ${c_dim}desc${c_reset} $(req_trunc "$REQ_F_DESC" $((width - 5)))")
    fi

    req_nav_detail_section "Headers" "$width" "${REQ_F_HEADERS[@]}"
    req_nav_detail_section "Query" "$width" "${REQ_F_QUERY[@]}"
    local sends_body=1 raw_title="Raw data" params_title="Parameters" raw_lines=()
    case $REQ_F_METHOD in POST|PUT|PATCH) ;; *) sends_body=0 ;; esac
    if (( ! sends_body )); then
        raw_title="Raw data (not sent with $REQ_F_METHOD)"
        params_title="Parameters (not sent with $REQ_F_METHOD)"
    elif (( REQ_F_RAW_SET )); then
        params_title="Parameters (not sent: raw data takes precedence)"
    fi
    req_nav_detail_section "$params_title" "$width" "${REQ_F_PARAMS[@]}"
    if (( REQ_F_RAW_SET )); then
        mapfile -t raw_lines <<<"$REQ_F_RAW"
        if (( ${#raw_lines[@]} > REQ_RAW_MAX_LINES )); then
            local more=$(( ${#raw_lines[@]} - REQ_RAW_MAX_LINES ))
            raw_lines=("${raw_lines[@]:0:REQ_RAW_MAX_LINES}" "... ($more more lines)")
        fi
        req_nav_detail_section "$raw_title" "$width" "${raw_lines[@]}"
    fi
}

# req_nav_build_help - the help screen, from REQ_HELP_ROWS. The key column of each section is as wide as its own
# longest key, so the long command rows do not squeeze the descriptions of the keys.
req_nav_build_help() {
    local cols row keys sec=0 c_dim c_bold c_reset
    local -a keyw=(0)
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=${row%%|*}; (( ${#keys} > keyw[sec] )) && keyw[sec]=${#keys}
        else
            (( sec++ )); keyw[sec]=0
        fi
    done
    sec=0
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} help")
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=$(printf '%-*s' "${keyw[sec]}" "${row%%|*}")
            REQ_SCREEN_LINES+=("  $(req_trunc "$keys  ${row#*|}" $((cols - 3)))")
        else
            (( sec++ ))
            REQ_SCREEN_LINES+=("${c_dim}${row}${c_reset}")
        fi
    done
}

# req_nav_build_config - the settings screen (:config): every known key with its effective value, default
# and description; "project" marks the values set by the project's file.
req_nav_build_config() {
    local cols key w=0 value def src c_dim c_bold c_reset
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for key in "${REQ_CONFIG_KEYS[@]}"; do (( ${#key} > w )) && w=${#key}; done
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} settings   ${c_dim}$(req_config_file)${c_reset}")
    [[ -z $REQ_PROJECT_ID ]] || REQ_SCREEN_LINES+=("${c_dim}project settings   $(req_config_local_file)${c_reset}")
    for key in "${REQ_CONFIG_KEYS[@]}"; do
        value=$(req_config_get "$key"); def=${REQ_CONFIG_DEFAULT[$key]}
        src=""; [[ -z ${REQ_CONFIG_LOCAL[$key]+x} ]] || src="project"
        REQ_SCREEN_LINES+=("  $(req_trunc "$(printf '%-*s  %-4s  default %-4s  %-7s  %s' "$w" "$key" "$value" "$def" "$src" "${REQ_CONFIG_DESC[$key]}")" $((cols - 3)))")
    done
    REQ_SCREEN_LINES+=("${c_dim}Change one with :config key=value (:config -g key=value for the global file)${c_reset}")
}

# req_nav_build_env - the environment menu (:env): the environments of REQ_ENV_CHOICES with the one in use
# marked, and "+ new environment" as the last row; the selected row is highlighted like the list's and the
# rows scroll in a window sized like the list's.
req_nav_build_env() {
    local total=$(( ${#REQ_ENV_CHOICES[@]} + 1 )) cols rows visible i end width label inuse current=${REQ_ENV:-default}
    local c_dim c_bold c_reset c_sel
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} environments${c_dim}$(req_trunc "  $REQ_NAV_PROJECT  (in use: $current)" $(( cols - 16 )))${c_reset}")

    visible=$(( rows - 3 - ${#REQ_NOTIFICATION_LINES[@]} )); (( visible < 3 )) && visible=3
    (( total < visible )) && visible=$total
    (( REQ_ENV_SEL < REQ_ENV_TOP )) && REQ_ENV_TOP=$REQ_ENV_SEL
    (( REQ_ENV_SEL >= REQ_ENV_TOP + visible )) && REQ_ENV_TOP=$(( REQ_ENV_SEL - visible + 1 ))
    end=$(( REQ_ENV_TOP + visible ))
    width=$(( cols - 16 ))
    for (( i = REQ_ENV_TOP; i < end; i++ )); do
        inuse=""
        if (( i < total - 1 )); then
            label=$(req_trunc "${REQ_ENV_CHOICES[i]}" "$width")
            [[ ${REQ_ENV_CHOICES[i]} == "$current" ]] && inuse=" (in use)"
        else
            label=$REQ_ENV_NEW_LABEL
        fi
        if (( i == REQ_ENV_SEL )); then
            REQ_SCREEN_LINES+=("${c_sel}$(req_marker) ${label}${inuse}${c_reset}")
        elif (( i == total - 1 )); then
            REQ_SCREEN_LINES+=("  ${c_dim}${label}${c_reset}")
        else
            REQ_SCREEN_LINES+=("  ${label}${c_dim}${inuse}${c_reset}")
        fi
    done
}

# req_nav_env_key <key> - a key on the environment menu: up and down move the selection (wrapping around,
# the last row being "+ new environment"), Enter acts on the row (req_nav_env_enter), Esc and q go back to the
# view the menu was opened from changing nothing.
req_nav_env_key() {
    local total=$(( ${#REQ_ENV_CHOICES[@]} + 1 ))
    case $1 in
        up)    REQ_ENV_SEL=$(( (REQ_ENV_SEL + total - 1) % total )) ;;
        down)  REQ_ENV_SEL=$(( (REQ_ENV_SEL + 1) % total )) ;;
        esc|q) REQ_VIEW=$REQ_ENV_BACK ;;
        enter) req_nav_env_enter ;;
    esac
    return 0
}

# req_nav_env_enter - Enter on the environment menu: on an environment it switches to it (req_env_use ...
# now) and goes back; on "+ new environment" it is req_nav_env_new.
req_nav_env_enter() {
    if (( REQ_ENV_SEL < ${#REQ_ENV_CHOICES[@]} )); then
        REQ_VIEW=$REQ_ENV_BACK
        req_env_use "${REQ_ENV_CHOICES[REQ_ENV_SEL]}" now
    else
        req_nav_env_new
    fi
}

# req_nav_env_new - "+ new environment": asks for the name (a slug; empty or end of input cancels and the
# menu stays), then creates the environment if it does not exist, switches to it and loads its variables
# (req_env_use ... now). A name that already exists is only switched to.
req_nav_env_new() {
    req_nav_prompt_begin
    if req_ask_name "" "Environment name" "staging"; then
        REQ_VIEW=$REQ_ENV_BACK
        req_env_use "$REQ_REPLY" now
    else
        req_cancelled
    fi
    req_nav_prompt_end
}

# req_nav_detail_section <title> <width> [line...] - appends the title and the lines; nothing without lines.
req_nav_detail_section() {
    local title=$1 width=$2 line
    shift 2
    (( $# > 0 )) || return 0
    REQ_SCREEN_LINES+=("  $(req_color dim)${title}$(req_color reset)")
    for line in "$@"; do
        line=${line//$'\n'/ }
        REQ_SCREEN_LINES+=("    $(req_trunc "$line" $((width - 2)))")
    done
}

# --- state transitions --------------------------------------------------

req_nav_open() {
    local i=$REQ_SEL
    if [[ ${REQ_ITEM_KIND[i]} == d ]]; then
        REQ_STACK_DIR+=("$REQ_CUR_DIR"); REQ_STACK_SEL+=("$REQ_SEL")
        REQ_CUR_DIR=${REQ_ITEM_PATH[i]}
        req_nav_load
    else
        REQ_DETAIL_FILE=${REQ_ITEM_PATH[i]}
        REQ_VIEW=detail
    fi
}

req_nav_back() {
    local last=$(( ${#REQ_STACK_DIR[@]} - 1 )) sel
    (( last >= 0 )) || return 0
    REQ_CUR_DIR=${REQ_STACK_DIR[last]}
    sel=${REQ_STACK_SEL[last]}
    unset "REQ_STACK_DIR[last]" "REQ_STACK_SEL[last]"
    req_nav_load
    REQ_SEL=$sel
}

# req_nav_execute - Enter on the details: erases the menu, runs and leaves the result on screen.
req_nav_execute() {
    local errs=""
    req_screen_erase
    # In the menu what the run writes to stderr (a key with no value, a file that cannot be read,
    # a failure of curl) becomes one warning at the top, instead of text in the terminal.
    [[ ${REQ_NOTIFICATION_ACTIVE-0} == 1 ]] && errs=$(mktemp 2>/dev/null)
    if [[ -n $errs ]]; then
        req_run_request "$REQ_DETAIL_FILE" 2>"$errs"
        req_notification_warn_file "$errs"
        rm -f "$errs"
    else
        req_run_request "$REQ_DETAIL_FILE"
    fi
    return 0
}

# req_nav_view_result - "v": the last response in the pager, full screen. The menu is erased first and drawn
# again when the pager returns.
req_nav_view_result() {
    req_result_check || return 0
    req_nav_prompt_begin
    req_result_view || true
    req_nav_prompt_end
    return 0
}

req_nav_handle() {
    local key=$1 n=${#REQ_ITEM_KIND[@]}
    REQ_NAV_DIRTY=1
    if [[ $key == $'\f' ]]; then     # Ctrl-L works in every view and while a command is typed, and changes nothing else
        req_nav_clear_screen
        return 0
    fi
    if (( REQ_CMD_ACTIVE )); then
        req_cmd_key "$key"
        return 0
    fi
    if [[ $REQ_VIEW == help || $REQ_VIEW == config ]]; then
        REQ_VIEW=$REQ_HELP_BACK     # any key closes the help and the settings
        return 0
    fi
    if [[ $REQ_VIEW == env ]]; then
        req_nav_env_key "$key"      # the environment menu has its own keys, and ":" is not one of them
        return 0
    fi
    if [[ $key == : ]]; then
        REQ_CMD_ACTIVE=1; REQ_CMD_BUF=""
        REQ_NAV_DIRTY=0
        return 0
    fi
    if [[ $REQ_VIEW == detail ]]; then
        case $key in
            enter) (( REQ_DETAIL_VALID )) && req_nav_execute ;;
            esc|q) REQ_VIEW=list ;;
            h)     req_nav_help ;;
            v)     req_nav_view_result ;;
        esac
    else
        case $key in
            up)    (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + n - 1) % n )) ;;
            down)  (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + 1) % n )) ;;
            enter) (( n > 0 )) && req_nav_open ;;
            esc)   req_nav_back ;;
            q)     if (( ${#REQ_STACK_DIR[@]} > 0 )); then req_nav_back; else REQ_QUIT=1; fi ;;
            h)     req_nav_help ;;
            v)     req_nav_view_result ;;
        esac
    fi
    return 0
}

# req_nav_overlay - what goes under the screen at each draw: the command prompt while a command is typed (one more
# line, the list keeps a row free for it).
req_nav_overlay() {
    local cursor='_'
    req_utf8 && cursor='█'
    (( REQ_CMD_ACTIVE )) && REQ_SCREEN_LINES+=(":${REQ_CMD_BUF}${cursor}")
}

# req_nav_run <.req file> - the main loop; ends at end of input or on :q, saving the menu position (also
# when the process is signaled).
# shellcheck disable=SC2034  # REQ_EXIT_HOOK is read by req_on_exit (core.sh)
req_nav_run() {
    req_nav_init "$1" || return 1
    req_nav_restore_cursor
    req_logo
    REQ_EXIT_HOOK=req_nav_save_cursor      # a signal ends the process: save the cursor then too
    [[ -t 1 ]] && printf '\033[?25l'
    [[ -t 0 ]] && stty -echo 2>/dev/null
    while :; do
        req_notification_collect        # the bars of this draw, before the list is sized
        if (( REQ_NAV_DIRTY )); then
            case $REQ_VIEW in
                detail) req_nav_build_detail ;;
                help)   req_nav_build_help ;;
                config) req_nav_build_config ;;
                env)    req_nav_build_env ;;
                *)      req_nav_build_list ;;
            esac
            REQ_BASE_LINES=("${REQ_SCREEN_LINES[@]}"); REQ_BASE_EXTRA=$REQ_SCREEN_EXTRA
            REQ_NAV_DIRTY=0
        else
            REQ_SCREEN_LINES=("${REQ_BASE_LINES[@]}"); REQ_SCREEN_EXTRA=$REQ_BASE_EXTRA
        fi
        req_nav_overlay
        req_notification_overlay        # the bars go above everything else
        req_screen_draw
        req_read_key || break
        req_nav_handle "$REQ_KEY"
        (( REQ_QUIT )) && break
    done
    req_nav_save_cursor; REQ_EXIT_HOOK=""      # :q and the end of the input
    [[ -t 0 ]] && stty echo 2>/dev/null
    [[ -t 1 ]] && printf '\033[?25h'
    return 0
}

# req_nav_start - interactive entry point: the .req of the current directory; without one it offers to
# initialize a project right here. The screen is cleared once, before anything is printed.
req_nav_start() {
    local pfile status
    [[ -t 0 && -t 1 ]] || req_die "interactive mode needs a terminal (use 'req run <file>' in scripts)"
    req_nav_clear_screen
    if ! pfile=$(req_project_find .); then
        printf 'No %s file found in %s.\n' "$REQ_PROJECT_FILE" "$PWD"
        if ! req_confirm "Initialize a req project here?"; then
            printf "Nothing created. Run 'req init' whenever you want to start a project.\n"
            return 1
        fi
        req_project_init . || return 1
        printf 'Created %s (workspace: .)\nUse :n to create a new request.\n' "$REQ_PROJECT_FILE"
        pfile=$(req_project_find .) || return 1
    fi
    REQ_NOTIFICATION_ACTIVE=1          # from here a warning goes to the bar at the top, not to the terminal
    req_project_activate "$(dirname "$pfile")"
    req_config_load_local || true      # the project's settings win over the global ones
    req_nav_run "$pfile"; status=$?
    REQ_NOTIFICATION_ACTIVE=0
    return "$status"
}
