#!/usr/bin/env bash
# cmd.sh - command mode (":") for the interactive menu. The commands are listed in REQ_HELP_ROWS (the :h screen) and
# dispatched by req_cmd_run. Esc leaves command mode; Backspace on an empty line does too.

# shellcheck disable=SC2034  # the REQ_* state below is shared with nav.sh

REQ_CMD_ACTIVE=0        # 1 while a command is being typed
REQ_CMD_BUF=""          # the command typed so far
REQ_STATUS=""           # one-shot message of a command (a confirmation); req_notification_status_lines draws it in a bar
REQ_QUIT=0              # set by :q, ends the main loop

# The help screen (h, :h) is built from this single table, "keys|description"; a line without "|" is a section
# title. It is the only place that lists the keys (the screens have no hint line), so every new key or command gets
# a row here, and a description that is to be read whole is at most 64 characters (the key column is as wide as
# the longest key of its section, and a row is cut at the width of the terminal).
REQ_HELP_ROWS=(
    "Keys"
    "up/down|move the selection (wraps around)"
    "Enter|open a directory or request; run it on the details; pick in :env"
    "Esc / q|go back one level; at the root q quits, Esc does nothing"
    "h|this help (same as :h)"
    "v|show the last response in a pager; q leaves it (Esc does not)"
    "Ctrl-L|clear the screen; the menu is drawn again at the top"
    "Ctrl-C|quit"
    ":|command mode (Esc cancels)"
    "any key|closes this help and the settings screen (:config)"
    "Commands"
    ":n|new request in the current directory"
    ":nd [name]|new directory (alias :mkdir)"
    ":ed [name]|rename the directory under the cursor (a request is edited with :e)"
    ":cp [name]|copy the directory (with its contents) or request under the cursor"
    ":rm|remove the selected request or directory, with a y/N question first"
    ":e|edit the selected request (alias :edit)"
    ":d|duplicate the selected request (alias :dup)"
    ":env [name]|menu to pick or create one, or jump to <name>"
    ":vars|edit the variables of the environment in use (alias :var)"
    ":log [yes|no]|switch the log of requests and responses in this session (setting: log)"
    ":v [yes|no]|switch the verbose mode (>> sent, << received) in this session (REQ_VERBOSE)"
    ":config [-g] [key=value]|show the settings, or change one (this project's; -g: global ~/.req/config)"
    ":h|this help (alias :help)"
    ":q|quit (alias :quit)"
    "Outside the menu"
    "req log|follow the project's log from another terminal (tail -F)"
)
REQ_HELP_BACK=list      # view to return to when the help screen closes

# req_nav_help - opens the help screen (the key h and the command :h); any key goes back to the view it came from.
req_nav_help() {
    REQ_HELP_BACK=$REQ_VIEW
    REQ_VIEW=help
}

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
        var|vars)     req_cmd_vars "$arg" ;;
        config)       req_cmd_config "$arg" ;;
        log)          req_cmd_log "$arg" ;;
        v|verbose)    req_cmd_verbose "$arg" ;;
        h|help)       req_nav_help ;;
        *)            req_notification_warn "unknown command :$cmd (:h lists the commands)" ;;
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

# req_nav_selected_request - the request file the commands act on: the open one on the details, or the
# selected one on the list.
req_nav_selected_request() {
    if [[ $REQ_VIEW == detail ]]; then
        printf '%s' "$REQ_DETAIL_FILE"
    elif (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == r ]]; then
        printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
    else
        return 1
    fi
}

req_nav_selected_dir() {
    [[ $REQ_VIEW == list ]] && (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == d ]] || return 1
    printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
}

req_cmd_rename_dir() {
    local dir
    if ! dir=$(req_nav_selected_dir); then
        if req_nav_selected_request >/dev/null; then
            req_notification_warn ":ed renames a directory; edit a request with :e"
        else
            req_notification_warn "select a directory on the list first"
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
        req_notification_warn "select a request or a directory first"
    fi
}

req_cmd_remove() {
    local target sel=$REQ_SEL kind=request
    if target=$(req_nav_selected_request); then :
    elif target=$(req_nav_selected_dir); then kind=directory
    else req_notification_warn "select a request or a directory first"; return 0
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
    file=$(req_nav_selected_request) || { req_notification_warn "select a request first"; return 0; }
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
    file=$(req_nav_selected_request) || { req_notification_warn "select a request first"; return 0; }
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

# req_cmd_config [-g] [key=value] - :config. Without an argument it opens the settings screen. With
# key=value it checks the key and the value against the table (req_config_valid) and writes the open
# project's file, or the global one with -g (the project's file wins).
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
        req_notification_warn "usage: :config [-g] [key=value] (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if [[ $scope == project && -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "no project is open: use :config -g key=value to change the global setting"
        return 0
    fi
    key=$(req_trim "${arg%%=*}"); value=$(req_trim "${arg#*=}")
    if ! req_config_known "$key"; then
        req_notification_warn "unknown setting \"$key\" (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if ! req_config_valid "$key" "$value"; then
        req_notification_warn "$key must be $(req_config_expect "$key"), not \"$value\""
        return 0
    fi
    if [[ $scope == project ]]; then file=$(req_config_local_file); else file=$(req_config_file); fi
    if req_kv_set "$file" "$key" "$value" 2>/dev/null; then
        req_config_load 2>/dev/null
        REQ_STATUS="$key=$value saved in $file"
    else
        req_notification_warn "cannot write $file"
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
# req_cmd_log [yes|no] - :log. Switches the log for this session (the "log" setting is not changed); needs
# an open project.
req_cmd_log() {
    local now=no new
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "no project is open, so there is no log to switch"
        return 0
    fi
    req_log_enabled && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        req_notification_warn "usage: :log [yes|no]"
        return 0
    fi
    REQ_LOG_SESSION=$new
    if [[ $new == yes ]]; then REQ_STATUS="log on for this session: $(req_log_file)"
    else REQ_STATUS="log off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_VERBOSE is read by the verbose functions in http.sh
req_cmd_verbose() {
    local now=no new
    req_verbose_on && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        req_notification_warn "usage: :v [yes|no]"
        return 0
    fi
    if [[ $new == yes ]]; then REQ_VERBOSE=1; REQ_STATUS="verbose on for this session (>> sent, << received)"
    else REQ_VERBOSE=0; REQ_STATUS="verbose off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_ENV is read by req_run_request and the header
# req_env_activate <name> [file just made] - makes <name> the environment of the session (REQ_ENV) and loads
# its variables right away (req_vars_load), so a broken file is reported now and not only when a request
# runs: the problems go to the warning bar and the switch stands, with no variables loaded; nothing is
# fixed. The status says how many variables were loaded and, for an environment just made, where its file
# is. They are loaded again at every request, so a file edited while req is open is read as it is then.
req_env_activate() {
    local name=$1 made=${2-} errs ok=1 note n
    REQ_ENV=$name
    if errs=$(mktemp 2>/dev/null); then
        req_vars_load "$name" 2>"$errs" || ok=0
        req_notification_warn_file "$errs"
        rm -f "$errs"
    else
        req_vars_load "$name" 2>/dev/null || { ok=0; req_notification_warn "cannot load the variables of environment \"$name\""; }
    fi
    if (( ok )); then
        n=${#REQ_VARS[@]}
        case $n in
            0) note="no variables" ;;
            1) note="1 variable" ;;
            *) note="$n variables" ;;
        esac
    else
        note="variables not loaded"
    fi
    REQ_STATUS="environment: $name${made:+, created in $made} ($note)"
}

# req_env_use <name> [ask|now] - switches the session to an environment (req_env_activate). One of the
# project, or "default", is switched to at once; one that does not exist is created: with "ask" (the
# default) after a [Y/n] question, with "now" straight away (the caller has asked). A name that is not a
# slug, no project state, answering no or a file that cannot be made is a warning and changes nothing.
# Always succeeds, like the commands.
req_env_use() {
    local name=$1 mode=${2:-ask} file err
    if ! req_valid_name "$name"; then
        req_notification_warn "invalid environment name \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 0
    fi
    if req_env_exists "$name"; then
        req_env_activate "$name"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "unknown environment \"$name\"; the project state in $(req_config_dir) is not available"
        return 0
    fi
    if [[ $mode == ask ]]; then
        req_nav_prompt_begin
        req_confirm "Create environment \"$name\"?" y || {
            req_nav_prompt_end
            REQ_STATUS="environment \"$name\" not created (in use: ${REQ_ENV:-default})"
            return 0; }
        req_nav_prompt_end
    fi
    file=$(req_env_file "$REQ_PROJECT_ID" "$name")
    if ! err=$(req_env_create "$name" 2>&1); then
        req_notification_warn "${err#req: error: }"
        return 0
    fi
    req_env_activate "$name" "$(req_abs_path "$file")"
    return 0
}

# req_cmd_env [name] - :env. With a name it switches to that environment (req_env_use). Without one it opens
# the environment menu (the view env, req_nav_build_env) with the one in use selected, and it goes back to
# the view it was opened from. With no project state only "default" can be used.
req_cmd_env() {
    local name=$1 current=${REQ_ENV:-default} i
    if [[ -n $name ]]; then
        req_env_use "$name"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "the project state in $(req_config_dir) is not available, so only the default environment can be used (in use: $current)"
        return 0
    fi
    req_env_choices
    REQ_ENV_SEL=0; REQ_ENV_TOP=0
    for i in "${!REQ_ENV_CHOICES[@]}"; do
        [[ ${REQ_ENV_CHOICES[i]} == "$current" ]] && REQ_ENV_SEL=$i
    done
    REQ_ENV_BACK=$REQ_VIEW; REQ_VIEW="env"
    return 0
}

# shellcheck disable=SC2016  # the $-words in the quotes are text for the user, not expansions
# req_vars_howto <abs path> <env> - what the user sees when there is no editor for :vars: where the variables
# of the environment are and how to write them, on their own lines so the path can be copied. Waits for Enter.
req_vars_howto() {
    printf 'No editor found (tried $VISUAL, $EDITOR, vim and nano).\n'
    printf 'The variables of environment %s are in:\n\n  %s\n\n' "$2" "$1"
    printf 'Add one per line, as key=value, for example:\n\n  host=https://api.example.com\n\n'
    printf 'and use it in a request as ${host}. Set $EDITOR, or install vim or nano, to edit them with :vars.\n\n'
    req_prompt "Press Enter to go back" "" || true
}

# req_cmd_vars [arg] - :var and :vars. Opens the `vars` file of the environment in use in $VISUAL, $EDITOR,
# vim or nano, making the file first when it is missing (req_vars_create). When the editor closes the
# variables of that environment are loaded again (req_env_activate), so a bad line is reported at once, with
# its path and line. With no editor the file is still made and req_vars_howto says where it is. An argument,
# or no project state, is a warning. Always succeeds, like the commands.
req_cmd_vars() {
    local env=${REQ_ENV:-default} file abs err status
    if [[ -n $1 ]]; then
        req_notification_warn "usage: :vars (no argument: it opens the variables of the environment in use)"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "the project state in $(req_config_dir) is not available, so there are no variables to edit"
        return 0
    fi
    if ! err=$(req_vars_create "$env" 2>&1); then
        req_notification_warn "${err#req: error: }"
        return 0
    fi
    file=$(req_env_file "$REQ_PROJECT_ID" "$env")
    abs=$(req_abs_path "$file")
    req_nav_prompt_begin
    req_edit_file "$file" vim nano; status=$?
    (( status == 2 )) && req_vars_howto "$abs" "$env"
    req_nav_prompt_end
    case $status in
        0) req_env_activate "$env" ;;
        1) req_notification_warn "the editor failed; $abs is as the editor left it" ;;
    esac
    return 0
}
