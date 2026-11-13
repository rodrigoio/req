#!/usr/bin/env bash
# env.sh - environments and secrets.
#
# Secrets live in $REQ_CONFIG_DIR/env/<env>/secrets.json (REQ_CONFIG_DIR defaults
# to ~/.req), a flat JSON object of simple values: {"token": "abc", "port": 8080}.
# An invalid file is only reported, never fixed or overwritten.

# Checks a secrets file in a single jq call and emits "tag NUL a NUL b NUL" records:
# ["kv", key, value] per secret, or ["err", message, ""] per problem.
REQ_SECRETS_JQ='
def scalar: type == "string" or type == "number" or type == "boolean";
(if type != "object" then ["err", "the root must be an object", ""]
 else to_entries[]
      | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$") | not)
            then ["err", "secret \"\(.key)\": invalid name (use letters, digits and underscores)", ""]
        elif (.value | scalar | not)
            then ["err", "secret \"\(.key)\": the value must be a string, number or boolean", ""]
        else ["kv", .key, (.value | tostring)] end
 end)
| .[] | (., "\u0000")'

declare -gA REQ_SECRETS=()      # secrets of the last loaded environment (key -> value)

# req_env_secrets_file <env> - path of the secrets file of an environment.
req_env_secrets_file() {
    printf '%s/env/%s/secrets.json' "$(req_config_dir)" "$1"
}

# shellcheck disable=SC2034  # REQ_SECRETS is read by the callers
# req_secrets_load <env> - loads the environment's secrets into REQ_SECRETS. A missing
# file is not an error (the environment simply has no file secrets). If the file is
# invalid, every problem is reported with its absolute path, REQ_SECRETS stays empty
# and the status is 1.
req_secrets_load() {
    local env=$1 file abs tag a b out problems=0
    local -A loaded=()
    REQ_SECRETS=()
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    file=$(req_env_secrets_file "$env")
    [[ -f $file ]] || return 0
    abs=$(req_abs_path "$file")

    out=$(jq -r . "$file" 2>&1 >/dev/null) || {
        req_err "$abs: invalid JSON: $out"; return 1; }
    while IFS= read -r -d '' tag && IFS= read -r -d '' a && IFS= read -r -d '' b; do
        case $tag in
            kv)  loaded[$a]=$b ;;
            err) req_err "$abs: $a"; problems=1 ;;
        esac
    done < <(jq -j "$REQ_SECRETS_JQ" "$file")
    (( problems )) && return 1
    local k
    for k in "${!loaded[@]}"; do REQ_SECRETS[$k]=${loaded[$k]}; done
    return 0
}
