# req

The interactive request tool for your terminal. Utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON.

> Em desenvolvimento. O plano de trabalho está em [TASKS.md](TASKS.md).

## Requisitos

- bash 4+
- curl
- jq

## Uso

```sh
bin/req --version
```

## Estrutura

```
bin/req        entrypoint fino (resolve o diretório e chama main)
lib/core.sh    dependências, erros e restauração do terminal
lib/ui.sh      cores ANSI e formatação por método HTTP
tests/         testes em bash puro (sem dependências)
```

Todo o código é organizado em funções dentro de `lib/`.

## Testes

```sh
tests/run.sh
```

Cada `tests/test_*.sh` é executado isoladamente; o runner falha se qualquer assert falhar.
