#!/usr/bin/env bash
# store.sh - persistência de requests (<nome>.<método>.json) e do arquivo .req.
#
# Formato de uma request:
#   {"name": "...", "method": "GET", "headers": {}, "query": {},
#    "data_parameter": {}, "data_string": ""}
# `name` e `method` são obrigatórios; os demais campos são opcionais.

REQ_METHODS=(GET POST PUT DELETE)
REQ_PROJECT_FILE=.req

# req_valid_method <método> - sucesso se for um método suportado (qualquer caixa).
req_valid_method() {
    local m
    for m in "${REQ_METHODS[@]}"; do
        [[ ${1^^} == "$m" ]] && return 0
    done
    return 1
}

# req_valid_name <nome> - sem barras, sem ponto inicial, não vazio.
req_valid_name() {
    [[ -n $1 && $1 != .* && $1 != */* ]]
}

# req_request_filename <nome> <método> - imprime "<nome>.<método em minúsculas>.json".
req_request_filename() {
    printf '%s.%s.json' "$1" "${2,,}"
}

# req_parse_filename <arquivo> - imprime "<nome>\t<MÉTODO>" ou falha se o
# arquivo não segue o padrão <nome>.<método>.json com método suportado.
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

# req_request_check <arquivo> - valida JSON, campos e coerência com o nome do
# arquivo. Imprime cada problema encontrado em stderr; sucesso se não houver.
req_request_check() {
    local file=$1 problems parsed fname fmethod jmethod
    req_json_validate "$file" || return 1

    problems=$(jq -r '
        if type != "object" then "a raiz deve ser um objeto"
        else
            (if (.name | type) != "string" or .name == "" then "campo \"name\" obrigatório (texto)" else empty end),
            (if (.method | type) != "string" then "campo \"method\" obrigatório (texto)" else empty end),
            (.headers        // {} | if type != "object" then "campo \"headers\" deve ser objeto" else empty end),
            (.query          // {} | if type != "object" then "campo \"query\" deve ser objeto" else empty end),
            (.data_parameter // {} | if type != "object" then "campo \"data_parameter\" deve ser objeto" else empty end),
            (.data_string    // "" | if type != "string" then "campo \"data_string\" deve ser texto" else empty end)
        end' "$file") || return 1

    if [[ -z $problems ]]; then
        jmethod=$(jq -r '.method' "$file")
        if ! req_valid_method "$jmethod"; then
            problems="método \"$jmethod\" não suportado (use ${REQ_METHODS[*]})"
        elif parsed=$(req_parse_filename "$file"); then
            fmethod=${parsed#*$'\t'}
            [[ $fmethod == "${jmethod^^}" ]] ||
                problems="método \"$jmethod\" difere do nome do arquivo (${fmethod})"
        else
            problems="nome de arquivo fora do padrão <nome>.<método>.json"
        fi
    fi

    [[ -z $problems ]] && return 0
    while IFS= read -r fname; do
        req_err "$file: $fname"
    done <<<"$problems"
    return 1
}

# req_request_template <nome> <método> - imprime uma request vazia em JSON.
req_request_template() {
    jq -n --arg name "$1" --arg method "${2^^}" '{
        name: $name, method: $method,
        headers: {}, query: {}, data_parameter: {}, data_string: ""
    }'
}

# req_request_write <diretório> <nome> <método> [json]
# Grava a request de forma atômica como JSON válido e imprime o caminho criado.
# Sem [json], usa o modelo vazio. O JSON passa pelo jq antes de ser gravado.
req_request_write() {
    local dir=$1 name=$2 method=$3 json=${4-} target tmp
    req_valid_name "$name" || { req_err "nome de request inválido: \"$name\""; return 1; }
    req_valid_method "$method" || { req_err "método inválido: \"$method\""; return 1; }
    [[ -d $dir ]] || { req_err "diretório inexistente: $dir"; return 1; }

    [[ -n $json ]] || json=$(req_request_template "$name" "$method")
    target=$dir/$(req_request_filename "$name" "$method")
    tmp=$(mktemp "$dir/.req.XXXXXX") || { req_err "não foi possível gravar em $dir"; return 1; }
    if ! jq --arg name "$name" --arg method "${method^^}" \
            '. + {name: $name, method: $method}' <<<"$json" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        req_err "JSON da request \"$name\" é inválido; nada foi gravado"
        return 1
    fi
    mv "$tmp" "$target" && printf '%s\n' "$target"
}

# req_request_get <arquivo> <campo> - imprime o valor de um campo (texto cru).
# Campos ausentes viram {} (headers, query, data_parameter) ou vazio.
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
# Itens ocultos e arquivos fora do padrão <nome>.<método>.json são ignorados.
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
