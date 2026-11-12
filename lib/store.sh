#!/usr/bin/env bash
# store.sh - persistência de requests (<nome>.<método>.json) e do arquivo .req.
#
# Formato de uma request:
#   {"name": "listar-usuarios", "method": "GET", "url": "https://api/users",
#    "description": "...", "headers": {}, "query": {}, "data_parameter": {}}
#
# - `name` é um slug (minúsculas, números e hífens) e é idêntico ao nome do
#   arquivo; é também o rótulo exibido no menu.
# - `name`, `method` e `url` são obrigatórios; os demais campos são opcionais.
# - headers, query e data_parameter são objetos de valores simples (texto,
#   número ou booleano).
# Qualquer campo desconhecido ou com tipo errado invalida a request; o arquivo
# nunca é alterado, o erro apenas é indicado.

REQ_METHODS=(GET POST PUT PATCH DELETE)
REQ_PROJECT_FILE=.req

# Verificação de conteúdo (independe do nome do arquivo): imprime um problema por linha.
REQ_SCHEMA_JQ='
def scalar: type == "string" or type == "number" or type == "boolean";
def check_map($lbl; $item):
    if type != "object" then "campo \"\($lbl)\" deve ser um objeto"
    else to_entries[] | select((.value | scalar) | not)
         | "\($item) \"\(.key)\": o valor deve ser texto, número ou booleano" end;
["name", "method", "url", "description", "headers", "query", "data_parameter"] as $allowed
| if type != "object" then "a raiz deve ser um objeto"
  else
    (keys[] | select(. as $k | $allowed | index($k) | not)
        | if . == "data_string" then "campo \"data_string\" ainda não é suportado"
          else "campo desconhecido \"\(.)\" (permitidos: \($allowed | join(", ")))" end),
    (if (.name | type) != "string" then "campo \"name\" obrigatório (texto)"
     elif (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)
         then "campo \"name\" deve ser um slug: minúsculas, números e hífens (ex.: listar-usuarios)"
     else empty end),
    (if (.method | type) != "string" then "campo \"method\" obrigatório (texto)" else empty end),
    (if (.url | type) != "string" or .url == "" then "campo \"url\" obrigatório (texto)" else empty end),
    (if has("description") and (.description | type) != "string"
         then "campo \"description\" deve ser texto" else empty end),
    (if has("headers") then
        (.headers | check_map("headers"; "header")),
        (if (.headers | type) == "object" then
            .headers | to_entries[]
            | if (.key | test("^[A-Za-z0-9!#$%&*+.^_|~-]+$") | not)
                  then "header \"\(.key)\": nome inválido"
              elif (.value | type) == "string" and (.value | test("[\r\n]"))
                  then "header \"\(.key)\": o valor não pode conter quebra de linha"
              else empty end
         else empty end)
     else empty end),
    (if has("query") then (.query | check_map("query"; "query")) else empty end),
    (if has("data_parameter") then (.data_parameter | check_map("data_parameter"; "data_parameter")) else empty end)
  end'

# req_valid_method <método> - sucesso se for um método suportado (qualquer caixa).
req_valid_method() {
    local m
    for m in "${REQ_METHODS[@]}"; do
        [[ ${1^^} == "$m" ]] && return 0
    done
    return 1
}

# req_valid_name <nome> - slug: minúsculas, números e hífens (ex.: listar-usuarios).
req_valid_name() {
    [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# req_request_filename <nome> <método> - imprime "<nome>.<método em minúsculas>.json".
req_request_filename() {
    printf '%s.%s.json' "$1" "${2,,}"
}

# req_parse_filename <arquivo> - imprime "<nome>\t<MÉTODO>" ou falha se o
# arquivo não segue o padrão <slug>.<método>.json com método suportado.
req_parse_filename() {
    local base=${1##*/} stem method
    [[ $base == *.*.json ]] || return 1
    stem=${base%.json}
    method=${stem##*.}
    req_valid_method "$method" || return 1
    req_valid_name "${stem%.*}" || return 1
    printf '%s\t%s\n' "${stem%.*}" "${method^^}"
}

# req_json_validate <arquivo> - sucesso se o arquivo for JSON válido; caso
# contrário só indica o erro (nunca altera o arquivo).
req_json_validate() {
    local err
    if ! err=$(jq empty "$1" 2>&1); then
        req_err "$1: JSON inválido: $err"
        return 1
    fi
}

# req_request_check <arquivo> - valida JSON, campos, tipos e coerência com o
# nome do arquivo. Imprime cada problema em stderr; sucesso se não houver nenhum.
req_request_check() {
    local file=$1 problems line parsed stem fmethod jname jmethod
    req_json_validate "$file" || return 1
    problems=$(jq -r "$REQ_SCHEMA_JQ" "$file") || return 1

    if [[ $problems != *"a raiz deve ser"* ]]; then
        jname=$(jq -r '.name | strings' "$file")
        jmethod=$(jq -r '.method | strings' "$file")
        if [[ -n $jmethod ]] && ! req_valid_method "$jmethod"; then
            problems+=${problems:+$'\n'}"método \"$jmethod\" não suportado (use ${REQ_METHODS[*]})"
        fi
        if parsed=$(req_parse_filename "$file"); then
            stem=${parsed%%$'\t'*}
            fmethod=${parsed#*$'\t'}
            if [[ -n $jname && $jname != "$stem" ]]; then
                problems+=${problems:+$'\n'}"campo \"name\" (\"$jname\") difere do nome do arquivo (\"$stem\")"
            fi
            if [[ -n $jmethod ]] && req_valid_method "$jmethod" && [[ $fmethod != "${jmethod^^}" ]]; then
                problems+=${problems:+$'\n'}"método \"$jmethod\" difere do nome do arquivo ($fmethod)"
            fi
        else
            problems+=${problems:+$'\n'}"nome de arquivo fora do padrão <slug>.<método>.json"
        fi
    fi

    [[ -z $problems ]] && return 0
    while IFS= read -r line; do
        req_err "$file: $line"
    done <<<"$problems"
    return 1
}

# req_request_template <nome> <método> <url> - imprime uma request nova em JSON.
req_request_template() {
    jq -n --arg name "$1" --arg method "${2^^}" --arg url "$3" '{
        name: $name, method: $method, url: $url, description: "",
        headers: {}, query: {}, data_parameter: {}
    }'
}

# req_request_write <diretório> <nome> <método> <url> [json]
# Grava a request de forma atômica como JSON válido e imprime o caminho criado.
# [json] traz os campos opcionais (description, headers, query, data_parameter);
# name, method e url vêm dos argumentos e prevalecem. Se o resultado não passar
# na validação, nada é gravado.
req_request_write() {
    local dir=$1 name=$2 method=$3 url=$4 json=${5-} target tmp problems line
    req_valid_name "$name" || {
        req_err "nome inválido: \"$name\" (use slug: minúsculas, números e hífens)"; return 1; }
    req_valid_method "$method" || {
        req_err "método inválido: \"$method\" (use ${REQ_METHODS[*]})"; return 1; }
    [[ -n $url ]] || { req_err "a url é obrigatória"; return 1; }
    [[ -d $dir ]] || { req_err "diretório inexistente: $dir"; return 1; }

    [[ -n $json ]] || json=$(req_request_template "$name" "$method" "$url")
    target=$dir/$(req_request_filename "$name" "$method")
    tmp=$(mktemp "$dir/.req.XXXXXX") || { req_err "não foi possível gravar em $dir"; return 1; }
    if ! jq --arg name "$name" --arg method "${method^^}" --arg url "$url" \
            '. + {name: $name, method: $method, url: $url}' <<<"$json" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        req_err "JSON da request \"$name\" é inválido; nada foi gravado"
        return 1
    fi
    problems=$(jq -r "$REQ_SCHEMA_JQ" "$tmp") || {
        rm -f "$tmp"; req_err "falha ao validar a request \"$name\""; return 1; }
    if [[ -n $problems ]]; then
        rm -f "$tmp"
        while IFS= read -r line; do
            req_err "request \"$name\": $line"
        done <<<"$problems"
        return 1
    fi
    mv "$tmp" "$target" && printf '%s\n' "$target"
}

# req_request_get <arquivo> <campo> - imprime o valor de um campo (texto cru).
# Campos ausentes viram {} (headers, query, data_parameter) ou vazio (demais).
req_request_get() {
    case $2 in
        headers|query|data_parameter) jq -c --arg f "$2" '.[$f] // {}' "$1" ;;
        *) jq -r --arg f "$2" '.[$f] // ""' "$1" ;;
    esac
}

# req_project_find [diretório] - imprime o caminho do .req no diretório (padrão: atual).
req_project_find() {
    local file=${1:-.}/$REQ_PROJECT_FILE
    [[ -f $file ]] || return 1
    printf '%s\n' "$file"
}

# req_project_dirs <arquivo .req> - imprime os diretórios do projeto, um por linha.
# Formato do .req: um diretório por linha, relativo ao próprio .req; linhas em
# branco e iniciadas por # são ignoradas. Entradas inexistentes geram erro em
# stderr, são puladas e o status final é 1.
req_project_dirs() {
    local file=$1 base line dir status=0
    [[ -f $file ]] || { req_err "arquivo de projeto não encontrado: $file"; return 1; }
    base=$(cd -P "$(dirname "$file")" && pwd)
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line || $line == \#* ]] && continue
        line=${line%/}
        [[ $line == /* ]] && dir=$line || dir=$base/$line
        if [[ -d $dir ]]; then
            printf '%s\n' "$dir"
        else
            req_err "$file: diretório listado não existe: $line"
            status=1
        fi
    done <"$file"
    return "$status"
}

# req_list_dir <diretório> - lista o conteúdo, subdiretórios primeiro e depois
# requests, cada grupo em ordem alfabética. Uma entrada por linha, separada por TAB:
#   d  <nome>             <caminho>
#   r  <nome>  <MÉTODO>   <caminho>
# Itens ocultos e arquivos fora do padrão <slug>.<método>.json são ignorados.
req_list_dir() {
    local dir=${1%/} entry name parsed
    [[ -d $dir ]] || { req_err "diretório inexistente: $dir"; return 1; }
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
