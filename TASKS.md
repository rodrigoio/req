# Plano de tarefas — `req` (interactive request tool para terminal)

## Context
O `manifest` descreve o `req`: um utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON num diretório de projeto. O repositório está vazio (só `manifest`, `LICENSE`, `.gitignore`). Este plano organiza o manifest em fases incrementais, cada uma entregando uma estrutura ou feature verificável.

Nota: o `manifest` é local e não deve ser versionado; a linha `manifest` do `.gitignore` permanece.

## Estado atual (para retomar)
- Feito: Fases 0 a 4 e a T5.1. Próxima tarefa: **T5.2** (resolução de uma chave: a variável `<ENV>_<CHAVE>` precede o arquivo).
- Suíte: `make check` com 458 asserts, 0 falhas, e `shellcheck` 0.9.0 limpo em `bin/`, `lib/` e `tests/` (`make lint`).
- Pendências abertas e ajustes pós-validação estão na seção "Adicionais" (TA.1 a TA.13), antes da Fase 8.
- Arquitetura, convenções, armadilhas já encontradas e a lista de pontos de navegação a validar com usuários estão em `DEVELOPMENT.md` (em inglês). Achados das validações entram aqui como novas tarefas.

## Decisões fechadas
- **Shell:** bash 4+. **Dependências:** apenas `curl` e `jq`.
- **Código:** organizado em funções, sem scripts procedurais soltos (boas práticas do manifest).
- **Ambientes:** troca interativa via `:env <nome>`.
- **Precedência:** variável de ambiente vence o arquivo de secrets.
- **Placeholder ausente:** `${chave}` sem valor gera erro amigável que indica ao usuário como proceder (arquivo e variável esperados, ex.: definir `DEV_URL` ou adicionar `url` em `~/.req/env/dev/secrets.json`); a requisição não é enviada.
- **JSON válido:** requests e secrets são sempre gravados como JSON válido. Se o usuário o invalidar manualmente, o `req` apenas indica o erro (arquivo e detalhe do jq), sem tentar corrigir nem sobrescrever.
- **Git:** `manifest` permanece no `.gitignore`.
- **Enter em duas etapas:** o 1º Enter em uma request abre os detalhes (url, params), o 2º dispara; Esc volta. Assim o usuário confere antes de executar.
- **Ambiente padrão:** `default`, usado quando `REQ_ENV` não está definido; troca em sessão via `:env <nome>`.
- **Campos da request:** obrigatórios `name`, `method` e `url` (a `url` pode usar `${chave}`); opcionais `description`, `headers`, `query` e `data_parameter`.
- **Nome slug:** `name` é um slug (minúsculas, números e hífens, ex.: `listar-usuarios`), idêntico ao nome do arquivo (`<slug>.<método>.json`) e usado como rótulo no menu.
- **Validação estrita:** campo desconhecido ou com tipo errado invalida a request e é indicado ao usuário; o arquivo nunca é alterado.
- **Headers genéricos:** qualquer nome de header válido, com valor texto, número ou booleano.
- **Corpo (por ora):** apenas `data_parameter` com valores simples, enviado apenas em POST, PUT e PATCH (GET e DELETE não levam corpo); `data_string` fica reservado para a Fase 8.
- **Métodos:** GET (verde), POST (azul), PUT (laranja), PATCH (marrom), DELETE (vermelho).
- **Secrets:** arquivo `~/.req/env/<env>/secrets.json` ou variáveis de ambiente com prefixo, `${url}` resolve para `DEV_URL` (ambiente `dev`, chave em maiúsculas).
- **Tarefas prontas:** o que já está implementado conta como feito, sem nova validação; o trabalho segue apenas com o que falta.
- **Tamanho das tarefas (revisão):** cada tarefa entrega um único comportamento, em cerca de 100 a 200 linhas contando os testes, e vira um commit. Infraestrutura (helpers) entra em commit próprio, antes da feature que a usa. Cada tarefa leva só os testes do seu comportamento; os cenários integrados ficam numa tarefa de verificação no fim da fase. Se uma tarefa estourar o tamanho, ela é dividida antes de commitar.

## Fases

### Fase 0 — Fundação do projeto
- [x] T0.1 Layout: `bin/req` (entrypoint fino), `lib/*.sh` (módulos de funções), `tests/`.
- [x] T0.2 Checagem de dependências na inicialização (bash >= 4, curl, jq) com mensagem de erro clara.
- [x] T0.3 Módulo utilitário: cores ANSI (verde GET, azul POST, laranja PUT, vermelho DELETE), mensagens de erro, restauração do terminal (`trap`).
- [x] T0.4 README mínimo, manter `.gitignore` como está (ignora `manifest`), definir framework de testes (bats ou script próprio sem dependência).

### Extra — Makefile (feito antes da Fase 2)
- [x] `make test`, `make lint`, `make check`, `make install` e `make uninstall` (link simbólico em `~/.local/bin`, configurável via `PREFIX`/`BINDIR`).

### Extra — Inicialização e idioma (feito antes da Fase 4)
- [x] `req init` cria `.req` e `requests/`; sem `.req` no diretório, o modo interativo oferece inicializar o projeto (`[Y/n]`).
- [x] Todo o código, mensagens, comentários, testes e README foram traduzidos para o inglês (idioma único do projeto).
- `shellcheck` é só ferramenta de desenvolvimento (`make lint`), não é dependência de runtime.

### Fase 1 — Modelo de dados e persistência
- [x] T1.1 Formato `<nome>.<method>.json` com campos `name`, `method`, `url`, `headers`, `query`, `data_parameter`, `data_string` (`url` e `description` acrescentados; ver Decisões fechadas). PATCH incluído, na cor marrom; `data_string` removido por ora.
- [x] T1.2 Funções de leitura/escrita/validação do JSON via jq (o exemplo do manifest não tem vírgulas; o JSON gravado deve ser válido) e detecção de JSON inválido por edição manual, apenas reportando o erro.
- [x] T1.3 Arquivo `.req` do projeto: lista de diretórios que compõem o projeto; parser e localização no diretório atual.
- [x] T1.4 Listagem de um diretório distinguindo subdiretórios reais de arquivos de request.
- [x] T1.5 Testes das funções de persistência e listagem.

### Fase 2 — Execução de requisições (núcleo curl)
- [x] T2.1 Montar o comando curl a partir da request (url, querystring com encode, headers, body em `data_parameter` ou `data_string`).
- [x] T2.2 Executar e exibir resposta no terminal sem gravar arquivos (stdout/pipe), com formatação para JSON, texto e HTML.
- [x] T2.3 Perfil de tempo por etapa via `curl -w` (DNS, conexão, TLS, TTFB, total) exibido em barra horizontal por etapa.
- [x] T2.4 Separador visual (`---` ou `===`) entre resultado e o menu remontado.
- [x] T2.5 Testes com servidor local simples ou mock.

### Fase 3 — Navegação interativa
- [x] T3.1 Loop infinito de menu: setas cima/baixo, Enter, Esc (captura de sequências de escape com `read -rsn`).
- [x] T3.2 Menu raiz com os diretórios do `.req`; entrar em diretório lista subdiretórios e requests, com ícone/rótulo distinguindo cada um.
- [x] T3.3 Tela de detalhes da request (url, description, params, headers); Enter dispara, Esc volta; na raiz Esc não faz nada.
- [x] T3.4 Cores por método na listagem e nos detalhes.

### Fase 4 — Modo comando e gestão de requests e diretórios
- [x] T4.1 Helpers de entrada: `req_trim`, `req_prompt` (uma linha, com padrão) e `req_confirm` com padrão `[y/N]`.
- [x] T4.2 Modo comando: `:` abre o prompt no rodapé, digitação, Backspace, Esc cancela, comando vazio ou desconhecido mostra mensagem de status.
- [x] T4.3 `:q` sai sem pedir confirmação, restaurando o terminal.
- [x] T4.4 `req_project_add_dir`: cria o diretório e o lista no `.req` (função e testes, sem UI).
- [x] T4.5 `:nd [nome]` (alias `:mkdir`): na raiz cria e lista no `.req`; dentro de um diretório cria um subdiretório real; atualiza a lista e seleciona o novo.
- [x] T4.6 `:n` mínimo: pergunta nome (slug), método e url e cria a request no diretório atual; erro amigável na raiz.
- [x] T4.7 `:n` campos opcionais simples: description, querystring e parâmetros (só POST, PUT e PATCH).
- [x] T4.8 `:n` headers: presets json, text e html e pares `chave: valor`.
- [x] T4.9 `:e` campos simples: menu para name, method, url e description, com renomeio do arquivo e proteção contra sobrescrita.
- [x] T4.10 `:e` coleções: headers, query e parâmetros (par `chave=valor` define, `-chave` remove).
- [x] T4.11 `:d`: duplica a request selecionada e abre o menu de edição na cópia.
- [x] T4.13 Caminho absoluto em requests inválidas: a tela de detalhes e as mensagens de validação mostram o caminho completo, em linha própria e sem truncar, para copiar e corrigir em outro terminal.
- [x] T4.12 Verificação da fase: fluxo integrado pelo laço principal, demonstração em terminal real e seção de comandos no README.

### Fase 5 — Ambientes e secrets
- [x] T5.1 Leitura de `~/.req/env/<env>/secrets.json` via jq; JSON inválido apenas indica o erro.
- T5.2 Resolução de uma chave: variável `<ENV>_<CHAVE>` precede o arquivo.
- T5.3 Substituição de `${chave}` em um texto (função pura), com erro amigável que lista as chaves ausentes e orienta o usuário.
- T5.4 Aplicar a substituição a url, headers, query e parâmetros antes de executar.
- T5.5 Ambiente ativo (`REQ_ENV`, padrão `default`) exibido no cabeçalho do menu.
- T5.6 `:env <nome>` troca o ambiente na sessão e valida ambiente inexistente.
- T5.7 Mascaramento de valores secretos (função e testes), para uso em logs e verbose.
- T5.8 Verificação da fase e documentação dos ambientes.

### Fase 6 — Logs e verbose
- T6.1 Configuração global (`~/.req/config`) e local (no projeto): formato, nomes dos arquivos e precedência (local vence).
- T6.2 Log da requisição enviada, com timestamp, em arquivo.
- T6.3 Log da resposta recebida, no mesmo arquivo.
- T6.4 Verbose: parâmetros enviados com `>>` no terminal.
- T6.5 Verbose: resposta (incluindo headers) com `<<` no terminal.
- T6.6 `:log` e `:v` alternam logs e verbose na sessão.
- T6.7 Verificação da fase e documentação.

### Fase 7 — Portabilidade, qualidade e entrega
- T7.1 Validação em container debian com bash 4+ (`make check`).
- T7.2 Validação em containers centos e rhel.
- [x] T7.3 `shellcheck`: corrigir os avisos (feito: `make lint` limpo em `bin/`, `lib/` e `tests/`).
- T7.4 Documentação de uso.
- T7.5 Documentação do formato de arquivos e dos ambientes.
- T7.6 Teste ponta a ponta do fluxo completo.

### Adicionais — pendências e ajustes pós-validação (antes da Fase 8)
Reúne o que ficou em aberto até aqui. As tarefas de navegação dependem das validações com usuários: confirmar a necessidade antes de implementar. Origem de cada ponto em `DEVELOPMENT.md`, seção "Open items to validate with users".
- TA.1 Apagar request ou diretório pelo menu (por exemplo `:rm`), com confirmação. Hoje não há como; o manifest não pede, mas é a lacuna mais provável.
- TA.2 Renomear ou mover request e diretório direto (por exemplo `:mv`), sem passar pelo campo `name` do menu de edição.
- TA.3 Esc cancela os prompts dos assistentes (`:n`, `:e`, `:d`, `:nd`). Hoje só nome vazio ou Ctrl-D cancelam.
- TA.4 Rever o Enter em duas etapas e a seleção que substitui a cor do método na linha destacada, conforme as validações (podem virar opção).
- TA.5 Histórico e Tab no modo comando.
- TA.6 Decidir se requests podem ser criadas na raiz do projeto (hoje só dentro de diretórios; `:n` na raiz explica e sugere `:nd`).
- TA.7 Redimensionamento do terminal: o menu não trata `SIGWINCH`; verificar o redesenho e o apagamento ao redimensionar.
- TA.8 Código de saída de `req run` para respostas 4xx e 5xx (hoje 0; só falha em erro de transporte). Decisão pendente.
- TA.9 Teste em pseudo-terminal dentro da suíte (init, navegação, `:n`, `:q`), hoje só feito à mão; requer `python3` e é pulado sem ele.
- TA.10 `REQ_ESC_TIMEOUT` (50 ms) em conexões lentas, como SSH: validar e documentar o ajuste.
- TA.11 Validar em terminais reais sem UTF-8 e com `NO_COLOR`; os fallbacks existem, mas só foram testados em teste automatizado.
- TA.12 Descrição com várias linhas na tela de detalhes (hoje as quebras viram espaço).
- TA.13 Decidir se o próprio `TASKS.md` é traduzido para inglês (pergunta em aberto desde a tradução do projeto).

### Fase 8 — Extras (a detalhar ao final do projeto)
- T8.1 `timeout` por request.
- T8.2 `follow_redirects` por request.
- T8.3 `insecure` por request.
- T8.4 `data_string` como corpo bruto, com a regra de precedência sobre `data_parameter`.
- T8.5 Envio de arquivos.
- T8.6 Valores aninhados em `query`.
- T8.7 Valores aninhados em `data_parameter`.

## Arquivos críticos (a criar)
`bin/req`, `lib/{core,ui,store,http,nav,cmd,env,log}.sh`, `tests/*`, `README.md`, `TASKS.md`.

## Verificação
Cada fase termina com seus testes passando e uma demonstração manual: Fase 2 dispara uma request real e mostra tempos; Fase 3 navega com setas/Enter/Esc; Fase 4 cria, edita e duplica requests geradas em disco; Fase 5 troca de ambiente com `:env` e resolve secrets; Fase 6 gera log e verbose com `>>`/`<<`; Fase 7 roda em containers debian/centos.
