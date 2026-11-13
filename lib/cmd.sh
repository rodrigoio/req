#!/usr/bin/env bash
# cmd.sh - command mode (":") for the interactive menu.
#
# Commands:
#   :n            new request in the current directory (wizard)
#   :nd [name]    new directory (alias :mkdir); at the root it is also listed in the .req
#   :ed [name]    rename the selected directory (also updates the .req entry)
#   :c [name]     copy the selected directory with its contents (default <name>-copy)
#   :rm           remove the selected request or directory (with its contents), after a [y/N] confirmation
#   :e            edit the selected request (alias :edit)
#   :d            duplicate the selected request and edit the copy (alias :dup)
#   :q            quit without asking (alias :quit)
#   :h            help: every key and command (alias :help)
# Esc leaves command mode; Backspace on an empty line does too.

# shellcheck disable=SC2034  # the REQ_* state below is shared with nav.sh

REQ_CMD_ACTIVE=0        # 1 while a command is being typed
REQ_CMD_BUF=""          # the command typed so far
REQ_STATUS=""           # one-shot message shown under the menu
REQ_QUIT=0              # set by :q, ends the main loop

# The help screen (:h) is built from this single table, "keys|description"; a line
# without "|" is a section title. Every new key or command gets a row here.
REQ_HELP_ROWS=(
    "Keys"
    "up/down|move the selection (wraps around)"
    "Enter|open a directory or request; on the details, run it"
    "Esc|go back (details, then list, then parent directory)"
    ":|command mode (Esc cancels)"
    "Commands"
    ":n|new request in the current directory"
    ":nd [name]|new directory (alias :mkdir)"
    ":ed [name]|rename the directory under the cursor"
    ":c [name]|copy the directory under the cursor, with its contents"
    ":rm|remove the selected request or directory, with a y/N question first"
    ":e|edit the selected request (alias :edit)"
    ":d|duplicate the selected request (alias :dup)"
    ":h|this help (alias :help)"
    ":q|quit (alias :quit)"
)
REQ_HELP_BACK=list      # view to return to when the help screen closes

# req_cmd_key <key> - handles one key while in command mode.
req_cmd_key() {
    local key=$1 line
    case $key in
        esc)
            REQ_CMD_ACTIVE=0; REQ_CMD_BUF="" ;;
        enter)
            line=$REQ_CMD_BUF
            REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""
            req_cmd_run "$line" ;;
        backspace)
            if [[ -z $REQ_CMD_BUF ]]; then
                REQ_CMD_ACTIVE=0
            else
                REQ_CMD_BUF=${REQ_CMD_BUF%?}
                REQ_NAV_DIRTY=0     # only the prompt line changes
            fi ;;
        up|down|other) REQ_NAV_DIRTY=0 ;;
        *)
            if (( ${#key} == 1 )); then
                REQ_CMD_BUF+=$key
                REQ_NAV_DIRTY=0
            fi ;;
    esac
    return 0
}

# req_cmd_run <line> - runs one command line.
req_cmd_run() {
    local line cmd arg
    line=$(req_trim "$1")
    cmd=${line%%[[:space:]]*}
    arg=$(req_trim "${line#"$cmd"}")
    case $cmd in
        '')           ;;
        q|quit)       REQ_QUIT=1 ;;
        n|new)        req_cmd_new ;;
        nd|mkdir)     req_cmd_mkdir "$arg" ;;
        ed)           req_cmd_rename_dir "$arg" ;;
        c)            req_cmd_copy_dir "$arg" ;;
        rm)           req_cmd_remove ;;
        e|edit)       req_cmd_edit ;;
        d|dup)        req_cmd_dup ;;
        h|help)       REQ_HELP_BACK=$REQ_VIEW; REQ_VIEW=help ;;
        *)            REQ_STATUS="unknown command :$cmd (:h lists the commands)" ;;
    esac
    return 0
}

# req_nav_prompt_begin / req_nav_prompt_end - hand the terminal over to the
# prompts (menu erased, cursor and echo on) and take it back afterwards.
req_nav_prompt_begin() {
    req_screen_erase
    [[ -t 1 ]] && printf '\033[?25h'
    [[ -t 0 ]] && stty echo 2>/dev/null
    return 0
}

req_nav_prompt_end() {
    [[ -t 0 ]] && stty -echo 2>/dev/null
    [[ -t 1 ]] && printf '\033[?25l'
    REQ_SCREEN_DRAWN=0
    return 0
}

# req_nav_selected_request - prints the request file the commands act on: the open
# one on the details screen, or the selected request on the list.
req_nav_selected_request() {
    if [[ $REQ_VIEW == detail ]]; then
        printf '%s' "$REQ_DETAIL_FILE"
    elif (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == r ]]; then
        printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
    else
        return 1
    fi
}

# req_nav_selected_dir - prints the directory under the cursor on the list.
req_nav_selected_dir() {
    [[ $REQ_VIEW == list ]] && (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == d ]] || return 1
    printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
}

req_cmd_rename_dir() {
    local dir
    dir=$(req_nav_selected_dir) || { REQ_STATUS="select a directory on the list first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_rename_dir "$dir" "$REQ_NAV_BASE/$REQ_PROJECT_FILE" "$1"; then
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="renamed to ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_copy_dir() {
    local dir
    dir=$(req_nav_selected_dir) || { REQ_STATUS="select a directory on the list first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_copy_dir "$dir" "$REQ_NAV_BASE/$REQ_PROJECT_FILE" "$1"; then
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="copied to ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_remove() {
    local target sel=$REQ_SEL kind=request
    if target=$(req_nav_selected_request); then :
    elif target=$(req_nav_selected_dir); then kind=directory
    else REQ_STATUS="select a request or a directory first"; return 0
    fi
    req_nav_prompt_begin
    if [[ $kind == directory ]]; then
        req_wizard_remove_dir "$target" "$REQ_NAV_BASE/$REQ_PROJECT_FILE" && REQ_LAST_FILE=$REQ_LAST_DIR || REQ_LAST_FILE=""
    else
        req_wizard_remove_request "$target" || REQ_LAST_FILE=""
    fi
    if [[ -n $REQ_LAST_FILE ]]; then
        REQ_VIEW=list
        req_nav_refresh ""
        # Stay near where the removed row was.
        (( sel >= ${#REQ_ITEM_KIND[@]} )) && sel=$(( ${#REQ_ITEM_KIND[@]} - 1 ))
        (( sel < 0 )) && sel=0
        REQ_SEL=$sel
        REQ_STATUS="removed ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_new() {
    req_nav_prompt_begin
    printf 'New request in %s\n' "$(req_nav_crumb)"
    if req_wizard_new "${REQ_CUR_DIR:-$REQ_NAV_ROOT}"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="created ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_mkdir() {
    req_nav_prompt_begin
    if req_wizard_mkdir "${REQ_CUR_DIR:-$REQ_NAV_ROOT}" "$1"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="created directory ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_edit() {
    local file
    file=$(req_nav_selected_request) || { REQ_STATUS="select a request first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_edit "$file"; then
        [[ $REQ_VIEW == detail ]] && REQ_DETAIL_FILE=$REQ_LAST_FILE
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="saved ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_dup() {
    local file
    file=$(req_nav_selected_request) || { REQ_STATUS="select a request first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_duplicate "$file"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="duplicated as ${REQ_LAST_FILE##*/}"
    elif [[ -f $REQ_LAST_FILE && $REQ_LAST_FILE != "$file" ]]; then
        # The copy was created even though its edit was cancelled.
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
    fi
    req_nav_prompt_end
}
