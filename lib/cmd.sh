#!/usr/bin/env bash
# cmd.sh - command mode (":") for the interactive menu.
#
# Commands:
#   :n            new request in the current directory (wizard)
#   :nd [name]    new directory (alias :mkdir); at the root it is also listed in the .req
#   :ed [name]    rename the selected directory
#   :cp [name]    copy the selected directory or request, asking for the new name (default <name>-copy)
#   :rm           remove the selected request or directory (with its contents), after a [y/N] confirmation
#   :e            edit the selected request (alias :edit)
#   :d            duplicate the selected request and edit the copy (alias :dup)
#   :q            quit without asking (alias :quit)
#   :env [name]   show the project's environments, or switch the session to one
#   :log [yes|no] switch the log of requests and responses for this session
#   :v [yes|no]   switch the verbose mode (>> and <<) for this session
#   :config [-g] [k=v] show the settings, or set one for the project or, with -g, globally (~/.req/config)
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
    ":ed [name]|rename the directory under the cursor (a request is edited with :e)"
    ":cp [name]|copy the directory (with its contents) or request under the cursor"
    ":rm|remove the selected request or directory, with a y/N question first"
    ":e|edit the selected request (alias :edit)"
    ":d|duplicate the selected request (alias :dup)"
    ":env [name]|show the environments of the project, or switch to one (REQ_ENV)"
    ":log [yes|no]|switch the log of requests and responses in this session (setting: log)"
    ":v [yes|no]|switch the verbose mode (>> sent, << received) in this session (REQ_VERBOSE)"
    ":config [-g] [key=value]|show the settings, or change one (this project's; -g: global ~/.req/config)"
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
        cp)           req_cmd_copy "$arg" ;;
        rm)           req_cmd_remove ;;
        e|edit)       req_cmd_edit ;;
        d|dup)        req_cmd_dup ;;
        env)          req_cmd_env "$arg" ;;
        config)       req_cmd_config "$arg" ;;
        log)          req_cmd_log "$arg" ;;
        v|verbose)    req_cmd_verbose "$arg" ;;
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
    if ! dir=$(req_nav_selected_dir); then
        if req_nav_selected_request >/dev/null; then
            REQ_STATUS=":ed renames a directory; edit a request with :e"
        else
            REQ_STATUS="select a directory on the list first"
        fi
        return 0
    fi
    req_nav_prompt_begin
    if req_wizard_rename_dir "$dir" "$1"; then
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="renamed to ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

# req_cmd_copy [name] - :cp on the item under the cursor: a directory is copied with its
# contents, a request is copied as it is; the new name is asked for, no edit menu follows.
req_cmd_copy() {
    local target
    if target=$(req_nav_selected_request); then
        req_nav_prompt_begin
        if req_wizard_copy_request "$target" "$1"; then
            [[ $REQ_VIEW == detail ]] && REQ_VIEW=list
            req_nav_refresh "$REQ_LAST_FILE"
            REQ_STATUS="copied to ${REQ_LAST_FILE##*/}"
        fi
        req_nav_prompt_end
    elif target=$(req_nav_selected_dir); then
        req_nav_prompt_begin
        if req_wizard_copy_dir "$target" "$1"; then
            req_nav_refresh "$REQ_LAST_DIR"
            REQ_STATUS="copied to ${REQ_LAST_DIR##*/}"
        fi
        req_nav_prompt_end
    else
        REQ_STATUS="select a request or a directory first"
    fi
}

req_cmd_remove() {
    local target sel=$REQ_SEL kind=request
    if target=$(req_nav_selected_request); then :
    elif target=$(req_nav_selected_dir); then kind=directory
    else REQ_STATUS="select a request or a directory first"; return 0
    fi
    req_nav_prompt_begin
    if [[ $kind == directory ]]; then
        req_wizard_remove_dir "$target" "$REQ_NAV_ROOT" && REQ_LAST_FILE=$REQ_LAST_DIR || REQ_LAST_FILE=""
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

# req_cmd_config [-g] [key=value] - :config. Without an argument it opens the settings screen
# (every known key, its value and its default). With key=value it checks the key and the
# value against the table (req_config_valid) and writes the open project's file, which is
# where settings belong by default; with -g it writes the global file (~/.req/config)
# instead. The project's file wins over the global one.
req_cmd_config() {
    local arg=$1 key value file scope=project
    if [[ $arg == -g || $arg == "-g "* ]]; then
        scope=global; arg=$(req_trim "${arg#-g}")
    fi
    if [[ -z $arg && $scope == project ]]; then
        req_config_load 2>/dev/null
        REQ_HELP_BACK=$REQ_VIEW; REQ_VIEW=config
        return 0
    fi
    if [[ $arg != *=* ]]; then
        REQ_STATUS="usage: :config [-g] [key=value] (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if [[ $scope == project && -z $REQ_PROJECT_ID ]]; then
        REQ_STATUS="no project is open: use :config -g key=value to change the global setting"
        return 0
    fi
    key=$(req_trim "${arg%%=*}"); value=$(req_trim "${arg#*=}")
    if ! req_config_known "$key"; then
        REQ_STATUS="unknown setting \"$key\" (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if ! req_config_valid "$key" "$value"; then
        REQ_STATUS="$key must be $(req_config_expect "$key"), not \"$value\""
        return 0
    fi
    if [[ $scope == project ]]; then file=$(req_config_local_file); else file=$(req_config_file); fi
    if req_kv_set "$file" "$key" "$value" 2>/dev/null; then
        req_config_load 2>/dev/null
        REQ_STATUS="$key=$value saved in $file"
    else
        REQ_STATUS="cannot write $file"
    fi
    return 0
}

# req_cmd_switch <yes|no|""> <current: yes|no> - prints the new value: the argument
# (also on|off), or the opposite of the current one. Fails for any other argument.
req_cmd_switch() {
    case $1 in
        yes|on)  printf yes ;;
        no|off)  printf no ;;
        '')      [[ $2 == yes ]] && printf no || printf yes ;;
        *)       return 1 ;;
    esac
}

# shellcheck disable=SC2034  # REQ_LOG_SESSION is read by req_log_enabled
# req_cmd_log [yes|no] - :log. Switches the log of requests and responses for this
# session (the "log" setting is not changed); it needs an open project to keep the log in.
req_cmd_log() {
    local now=no new
    if [[ -z $REQ_PROJECT_ID ]]; then
        REQ_STATUS="no project is open, so there is no log to switch"
        return 0
    fi
    req_log_enabled && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        REQ_STATUS="usage: :log [yes|no]"
        return 0
    fi
    REQ_LOG_SESSION=$new
    if [[ $new == yes ]]; then REQ_STATUS="log on for this session: $(req_log_file)"
    else REQ_STATUS="log off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_VERBOSE is read by the verbose functions in http.sh
# req_cmd_verbose [yes|no] - :v. Switches the verbose mode for this session.
req_cmd_verbose() {
    local now=no new
    req_verbose_on && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        REQ_STATUS="usage: :v [yes|no]"
        return 0
    fi
    if [[ $new == yes ]]; then REQ_VERBOSE=1; REQ_STATUS="verbose on for this session (>> sent, << received)"
    else REQ_VERBOSE=0; REQ_STATUS="verbose off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_ENV is read by req_run_request and the header
# req_cmd_env [name] - :env. Without an argument it lists the project's environments and
# the one in use. With a name it switches the session to that environment (REQ_ENV, shown
# in the header and used by the next request) when the project has a file for it
# ("default" always works); otherwise it says which ones exist and where to create it.
req_cmd_env() {
    local name=$1 current=${REQ_ENV:-default} list
    list=$(req_env_list | tr '\n' ' '); list=${list% }
    if [[ -z $name ]]; then
        if [[ -n $list ]]; then
            REQ_STATUS="environments: ${list// /, } (in use: $current)"
        else
            REQ_STATUS="no environments yet (in use: $current); add a file in $(req_project_state_dir "${REQ_PROJECT_ID:-<project>}" env)"
        fi
        return 0
    fi
    if ! req_valid_name "$name"; then
        REQ_STATUS="invalid environment name \"$name\" (use a slug: lowercase letters, digits and hyphens)"
    elif ! req_env_exists "$name"; then
        REQ_STATUS="unknown environment \"$name\""
        [[ -z $list ]] || REQ_STATUS+=" (known: ${list// /, })"
        if [[ -n $REQ_PROJECT_ID ]]; then
            REQ_STATUS+="; create it with a file at $(req_env_file "$REQ_PROJECT_ID" "$name")"
        else
            REQ_STATUS+="; the project state in $(req_config_dir) is not available"
        fi
    else
        REQ_ENV=$name
        REQ_STATUS="environment: $name"
    fi
    return 0
}
