#!/usr/bin/env bash
# nav.sh - interactive navigation: directory and request menu, details screen.
#
# The menu is redrawn in place (the cursor moves up and erases the previous
# block) without clearing the screen. A request's result stays visible and the
# menu is redrawn right below it. Outside a terminal nothing is erased (used by tests).
#
# Keys: up/down move the selection, Enter opens/runs, Esc goes back (does nothing at the root),
# ":" enters command mode (see cmd.sh).

REQ_RAW_MAX_LINES=15    # lines of raw_data shown on the details screen
REQ_ESC_TIMEOUT=0.05    # wait for bytes after ESC to tell an arrow key from a bare Esc
REQ_INPUT_FD=0          # descriptor the keys are read from
REQ_KEY=""              # last key read: up, down, enter, esc, or the character itself

REQ_SCREEN_LINES=()     # lines of the current block
REQ_SCREEN_DRAWN=0      # rows of the block already printed in the terminal
REQ_SCREEN_EXTRA=0      # rows beyond one per line, from long lines that wrap
REQ_BASE_EXTRA=0

REQ_NAV_ROOT=""         # the menu root: the workspace of the project (set only by req_nav_root)
REQ_CUR_DIR=""          # directory being shown ("" = project root)
REQ_STACK_DIR=()        # navigation stack: previous directories and selections
REQ_STACK_SEL=()
REQ_VIEW=list           # list | detail | help
REQ_DETAIL_FILE=""
REQ_DETAIL_VALID=0

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

# req_screen_erase - erases the last drawn block (terminal only).
req_screen_erase() {
    if [[ -t 1 && $REQ_SCREEN_DRAWN -gt 0 ]]; then
        printf '\033[%dA\r\033[J' "$REQ_SCREEN_DRAWN"
    fi
    REQ_SCREEN_DRAWN=0
}

# req_screen_draw - replaces the previous block with REQ_SCREEN_LINES.
req_screen_draw() {
    req_screen_erase
    printf '%s\n' "${REQ_SCREEN_LINES[@]}"
    [[ -t 1 ]] && REQ_SCREEN_DRAWN=$(( ${#REQ_SCREEN_LINES[@]} + REQ_SCREEN_EXTRA ))
    return 0
}

# req_screen_add_long <text> - appends a line that is never truncated (so it can be
# copied whole). If it wraps, the extra terminal rows are counted for the redraw.
req_screen_add_long() {
    local cols
    cols=$(req_term_cols)
    REQ_SCREEN_LINES+=("$1")
    (( ${#1} > cols )) && REQ_SCREEN_EXTRA=$(( REQ_SCREEN_EXTRA + (${#1} - 1) / cols ))
    return 0
}

# req_marker - selection indicator.
req_marker() {
    if req_utf8; then printf '▸'; else printf '>'; fi
}

# --- data -----------------------------------------------------------------

# req_nav_rel <path> - path relative to the menu root (the workspace), when possible.
req_nav_rel() {
    printf '%s' "${1#"$REQ_NAV_ROOT"/}"
}

# req_nav_root <.req file> - decides the directory the menu starts in and never leaves:
# the project's workspace (REQ_NAV_ROOT). The single place that knows where the root is.
# Fails, with the reason already printed, when the workspace is not valid.
req_nav_root() {
    REQ_NAV_ROOT=$(req_project_workspace "$1") || { REQ_NAV_ROOT=""; return 1; }
}

# req_nav_load - loads the items of the current directory; at the root ("") they are
# the items of the workspace: its directories and its requests.
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

# req_nav_init <.req file> - sets the state up at the project root.
req_nav_init() {
    local pfile=$1
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    req_nav_root "$pfile" || return 1
    REQ_CUR_DIR=""; REQ_STACK_DIR=(); REQ_STACK_SEL=()
    REQ_VIEW=list; REQ_DETAIL_FILE=""; REQ_DETAIL_VALID=0
    REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""; REQ_STATUS=""; REQ_QUIT=0; REQ_NAV_DIRTY=1
    req_nav_load
}

# req_nav_refresh <path> - reloads the current directory (or the project root) and
# selects <path> in it, if present.
req_nav_refresh() {
    local want=$1 i
    req_nav_load
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$want" ]] && REQ_SEL=$i
    done
}

# --- screen building --------------------------------------------------

# req_nav_crumb - current path ("/" at the root).
req_nav_crumb() {
    if [[ -z $REQ_CUR_DIR ]]; then printf '/'; else printf '/%s' "$(req_nav_rel "$REQ_CUR_DIR")"; fi
}

# req_nav_build_list - builds REQ_SCREEN_LINES with the current directory's list.
req_nav_build_list() {
    local n=${#REQ_ITEM_KIND[@]} cols rows visible i end width pos
    local c_dim c_bold c_reset c_sel arrows hint tag label
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    pos=""
    (( n > 0 )) && pos=" ($((REQ_SEL + 1))/$n)"
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} $(req_trunc "$(req_nav_crumb)" $((cols - 5 - ${#pos})))${c_dim}${pos}${c_reset}")

    if (( n == 0 )); then
        REQ_SCREEN_LINES+=("  ${c_dim}(empty)${c_reset}")
    else
        visible=$(( rows - 4 )); (( visible < 3 )) && visible=3
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

    if req_utf8; then arrows="↑↓"; else arrows="up/down"; fi
    hint="$arrows move   Enter open   : commands   :h help"
    [[ ${#REQ_STACK_DIR[@]} -gt 0 ]] && hint+="   Esc back"
    REQ_SCREEN_LINES+=("${c_dim}$(req_trunc "$hint" $((cols - 1)))${c_reset}")
}

# req_nav_build_detail - builds REQ_SCREEN_LINES with the open request's details.
# Invalid requests show their problems instead of the fields and do not run.
req_nav_build_detail() {
    local f=$REQ_DETAIL_FILE abs cols width c_dim c_bold c_reset problems line
    cols=$(req_term_cols); width=$(( cols - 4 ))
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    if ! problems=$(req_request_check "$f" 2>&1); then
        REQ_DETAIL_VALID=0
        abs=$(req_abs_path "$f")
        REQ_SCREEN_LINES+=("$(req_color err)Invalid request:${c_reset}")
        req_screen_add_long "$abs"      # whole and on its own line, ready to copy
        while IFS= read -r line; do
            line=${line#"req: error: $abs: "}
            line=${line#"req: error: "}
            REQ_SCREEN_LINES+=("  $(req_trunc "$line" "$width")")
        done <<<"$problems"
        REQ_SCREEN_LINES+=("${c_dim}Fix the file and open it again.   Esc back${c_reset}")
        return 0
    fi

    REQ_DETAIL_VALID=1
    req_request_fields "$f"
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

    REQ_SCREEN_LINES+=("${c_dim}Enter run   : commands   :h help   Esc back${c_reset}")
}

# req_nav_build_help - builds REQ_SCREEN_LINES with the help screen, from REQ_HELP_ROWS.
req_nav_build_help() {
    local cols row keys w=0 c_dim c_bold c_reset
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for row in "${REQ_HELP_ROWS[@]}"; do
        [[ $row == *'|'* ]] && { keys=${row%%|*}; (( ${#keys} > w )) && w=${#keys}; }
    done
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} help")
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=$(printf '%-*s' "$w" "${row%%|*}")
            REQ_SCREEN_LINES+=("  $(req_trunc "$keys  ${row#*|}" $((cols - 3)))")
        else
            REQ_SCREEN_LINES+=("${c_dim}${row}${c_reset}")
        fi
    done
    REQ_SCREEN_LINES+=("${c_dim}Press any key to go back${c_reset}")
}

# req_nav_detail_section <title> <width> [line...]
# Appends the title and the given lines; does nothing if there are no lines.
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

# req_nav_open - Enter on the list: enters the directory or opens the request's details.
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

# req_nav_back - Esc on the list: goes up one directory; does nothing at the root.
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
    req_screen_erase
    req_run_request "$REQ_DETAIL_FILE"
    return 0
}

# req_nav_handle <key> - applies a key to the current state.
req_nav_handle() {
    local key=$1 n=${#REQ_ITEM_KIND[@]}
    REQ_NAV_DIRTY=1
    if (( REQ_CMD_ACTIVE )); then
        req_cmd_key "$key"
        return 0
    fi
    if [[ $REQ_VIEW == help ]]; then
        REQ_VIEW=$REQ_HELP_BACK     # any key closes the help
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
            esc)   REQ_VIEW=list ;;
        esac
    else
        case $key in
            up)    (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + n - 1) % n )) ;;
            down)  (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + 1) % n )) ;;
            enter) (( n > 0 )) && req_nav_open ;;
            esc)   req_nav_back ;;
        esac
    fi
    return 0
}

# req_nav_overlay - puts the command prompt and the one-shot status on the screen.
req_nav_overlay() {
    local last=$(( ${#REQ_SCREEN_LINES[@]} - 1 )) cursor='_'
    req_utf8 && cursor='█'
    (( REQ_CMD_ACTIVE )) && REQ_SCREEN_LINES[last]=":${REQ_CMD_BUF}${cursor}"
    if [[ -n $REQ_STATUS ]]; then
        REQ_SCREEN_LINES+=("$(req_color dim)${REQ_STATUS}$(req_color reset)")
        REQ_STATUS=""
    fi
}

# req_nav_run <.req file> - main loop; ends at end of input or on :q.
req_nav_run() {
    req_nav_init "$1" || return 1
    [[ -t 1 ]] && printf '\033[?25l'
    [[ -t 0 ]] && stty -echo 2>/dev/null
    while :; do
        if (( REQ_NAV_DIRTY )); then
            case $REQ_VIEW in
                detail) req_nav_build_detail ;;
                help)   req_nav_build_help ;;
                *)      req_nav_build_list ;;
            esac
            REQ_BASE_LINES=("${REQ_SCREEN_LINES[@]}"); REQ_BASE_EXTRA=$REQ_SCREEN_EXTRA
            REQ_NAV_DIRTY=0
        else
            REQ_SCREEN_LINES=("${REQ_BASE_LINES[@]}"); REQ_SCREEN_EXTRA=$REQ_BASE_EXTRA
        fi
        req_nav_overlay
        req_screen_draw
        req_read_key || break
        req_nav_handle "$REQ_KEY"
        (( REQ_QUIT )) && break
    done
    [[ -t 0 ]] && stty echo 2>/dev/null
    [[ -t 1 ]] && printf '\033[?25h'
    return 0
}

# req_nav_start - interactive entry point: uses the .req of the current directory.
# Without one, offers to initialize a project right here.
req_nav_start() {
    local pfile
    [[ -t 0 && -t 1 ]] || req_die "interactive mode needs a terminal (use 'req run <file>' in scripts)"
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
    req_project_activate "$(dirname "$pfile")"
    req_nav_run "$pfile"
}
