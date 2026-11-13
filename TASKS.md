# Plano de tarefas — `req` (interactive request tool para terminal)

## Context
O `manifest` descreve o `req`: um utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON num diretório de projeto. O repositório está vazio (só `manifest`, `LICENSE`, `.gitignore`). Este plano organiza o manifest em fases incrementais, cada uma entregando uma estrutura ou feature verificável.

Nota: o `manifest` é local e não deve ser versionado; a linha `manifest` do `.gitignore` permanece.

## Estado atual (para retomar)
- Feito: Fases 0 a 4 e a T5.1. Próxima tarefa: **TR.4** (Revisão 1: `raw_data` no formato e no envio). TR.1 a TR.3 estão feitas. A Fase 5 é retomada na **T5.2** depois da TR.15.
- Suíte: `make check` com 479 asserts, 0 falhas, e `shellcheck` 0.9.0 limpo em `bin/`, `lib/` e `tests/` (`make lint`).
- A seção "Revisão 1" (TR.1 a TR.15) reúne os achados confirmados na primeira validação de uso e vem antes da Fase 5. A TR.14 está adiada: confirmar com o usuário antes de implementar.
- Pendências ainda não confirmadas estão na seção "Adicionais" (TA.2 a TA.13), antes da Fase 8.
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
- **Campos da request:** obrigatórios `name`, `method` e `url` (a `url` pode usar `${chave}`); opcionais `description`, `headers`, `query`, `parameters` e `raw_data`. `parameters` é o novo nome de `data_parameter` (feito na TR.3).
- **Nome slug:** `name` é um slug (minúsculas, números e hífens, ex.: `listar-usuarios`), idêntico ao nome do arquivo (`<slug>.<método>.json`) e usado como rótulo no menu.
- **Validação estrita:** campo desconhecido ou com tipo errado invalida a request e é indicado ao usuário; o arquivo nunca é alterado.
- **Headers genéricos:** qualquer nome de header válido, com valor texto, número ou booleano.
- **Corpo (Revisão 1, vale a partir das TR.3 e TR.4):** enviado apenas em POST, PUT e PATCH (GET e DELETE não levam corpo). `parameters` são campos de formulário (chave e valor simples), sempre enviados url-encoded. `raw_data` é o corpo bruto: JSON nativo (objeto ou lista) quando o texto é JSON, string nos demais formatos; string vazia ou campo ausente significa sem corpo bruto. `raw_data` preenchido tem precedência sobre `parameters`. JSON sem header `Content-Type` sai com `application/json`; texto livre não ganha header automático.
- **Nomes antigos:** arquivos com `data_parameter` ou `data_string` não são migrados; a validação indica o nome novo.
- **Editor externo:** `raw_data` é editado no editor do usuário, como o git faz: `$VISUAL`, `$EDITOR`, `vim`, `vi`. Sem nenhum deles, vale um prompt de uma linha.
- **Comandos de diretório:** `:ed [nome]` renomeia e `:c [nome]` copia com tudo dentro o diretório sob o cursor. `:rm` remove a request ou o diretório inteiro sob o cursor, sempre com confirmação `[y/N]`; para diretório o aviso é em vermelho e só se apaga dentro do projeto.
- **Ajuda:** `:h` lista todas as teclas e comandos; todo comando novo entra nela.
- **Erro de dependências:** só nomeia os pacotes faltantes, em laranja, sem comandos de instalação.
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

### Revisão 1 — achados da validação de uso (antes da Fase 5)
Primeira sessão de uso real, em 2026-11-13. Os achados ficaram no arquivo local `reviews` (não versionado, como o `manifest`); o resumo abaixo é o registro no repositório. Ordem de execução: primeiro o que a revisão trata como obrigatório (R7, R5, R6), depois os casos raros de diretório (R2 a R4); o R1 foi adiado.

Achados:
- **R1** Ao executar, o resultado aparece acima dos dados da request; com resposta grande fica difícil comparar. Sugestão: dados da request acima, resposta abaixo.
- **R2** Não há como renomear um diretório existente. Sugestão: `:ed` com o diretório sob o cursor.
- **R3** Não há como duplicar um diretório com tudo dentro. Sugestão: `:c` com o diretório sob o cursor.
- **R4** Não há como remover um diretório, inclusive recursivamente. Sugestão: `:rm`, com aviso em vermelho e confirmação sim ou não.
- **R5** Falta um menu de ajuda com todas as opções: `:h`.
- **R6** Deve ser possível enviar um POST com JSON digitado pelo usuário, com a opção no menu de edição; havendo `vim` ou `vi`, chamar o editor no meio do programa, como o git, e voltar ao fluxo.
- **R7** O erro de dependências não deve trazer comandos `sudo` ou `install`; só indicar os pacotes faltantes em outra cor (laranja).

Tarefas:
- [x] TR.1 (R7) Erro de dependências: uma linha que só nomeia os pacotes faltantes, em laranja, sem `sudo` nem `install`.
- [x] TR.2 (R5) `:h` (alias `:help`): tela de ajuda com todas as teclas e comandos, a partir de uma tabela única; qualquer tecla volta. O aviso de comando desconhecido e os rodapés passam a apontar para `:h`.
- [x] TR.3 (R6) Renomear `data_parameter` para `parameters`, sem mudar o envio; o nome antigo vira erro de validação que indica o novo.
- TR.4 (R6) `raw_data` no formato e no envio: objeto, lista ou string; precedência sobre `parameters`, que passa a ser sempre formulário url-encoded; JSON sem `Content-Type` sai com `application/json`.
- TR.5 (R6) Tela de detalhes mostra o `raw_data` (JSON indentado ou texto, com teto de linhas) e avisa quando `parameters` não é enviado.
- TR.6 (R6) Helper de editor externo (`req_editor`, `req_edit_text`): `$VISUAL`, `$EDITOR`, `vim`, `vi`, em arquivo temporário, como o git. Infraestrutura, commit próprio.
- TR.7 (R6) Menu de edição: a opção `8) raw data` abre o editor com o JSON; JSON válido é gravado nativo, texto que não é JSON oferece editar de novo ou guardar como texto; sem editor, prompt de uma linha.
- TR.8 (R6) `:n` com preset de formato (json, text, html) oferece o corpo bruto no editor em vez de pedir `parameters`.
- TR.9 (R2 a R4) Helpers do `.req`: localizar, trocar, remover e acrescentar uma entrada, preservando comentários e ordem. Infraestrutura, commit próprio.
- TR.10 (R2) `:ed [nome]` renomeia o diretório sob o cursor; na raiz atualiza a entrada do `.req`.
- TR.11 (R3) `:c [nome]` copia o diretório sob o cursor com tudo dentro (padrão `<nome>-copy`); na raiz lista a cópia no `.req`.
- TR.12 (R4, TA.1) `:rm` em request: confirmação `[y/N]` e remoção, na lista e na tela de detalhes; vale também para request inválida.
- TR.13 (R4) `:rm` em diretório: aviso em vermelho com o caminho e a contagem do conteúdo, confirmação `[y/N]`, remoção recursiva só dentro do projeto; na raiz tira a entrada do `.req`.
- TR.14 (R1) **Adiada: confirmar com o usuário antes de implementar.** Ao executar, os dados da request ficam acima e a resposta abaixo. Desenho preferido para o rodapé: compacto (nome da request e teclas), com Enter executando de novo.
- TR.15 Verificação da revisão: fluxo integrado pelo laço principal, demonstração em terminal real (pty) e revisão final do README e do `DEVELOPMENT.md`.

### Fase 5 — Ambientes e secrets
- [x] T5.1 Leitura de `~/.req/env/<env>/secrets.json` via jq; JSON inválido apenas indica o erro.
- T5.2 Resolução de uma chave: variável `<ENV>_<CHAVE>` precede o arquivo.
- T5.3 Substituição de `${chave}` em um texto (função pura), com erro amigável que lista as chaves ausentes e orienta o usuário.
- T5.4 Aplicar a substituição a url, headers, query, `parameters` e `raw_data` (incluindo as strings dentro do JSON nativo) antes de executar.
- T5.5 Ambiente ativo (`REQ_ENV`, padrão `default`) exibido no cabeçalho do menu.
- T5.6 `:env <nome>` troca o ambiente na sessão e valida ambiente inexistente; entra na ajuda `:h`.
- T5.7 Mascaramento de valores secretos (função e testes), para uso em logs, no verbose e na linha `MÉTODO url` mostrada ao executar.
- T5.8 Verificação da fase e documentação dos ambientes.

### Fase 6 — Logs e verbose
- T6.1 Configuração global (`~/.req/config`) e local (no projeto): formato, nomes dos arquivos e precedência (local vence).
- T6.2 Log da requisição enviada, com timestamp, em arquivo.
- T6.3 Log da resposta recebida, no mesmo arquivo.
- T6.4 Verbose: dados enviados (`parameters` ou `raw_data`) com `>>` no terminal.
- T6.5 Verbose: resposta (incluindo headers) com `<<` no terminal.
- T6.6 `:log` e `:v` alternam logs e verbose na sessão; entram na ajuda `:h`.
- T6.7 Verificação da fase e documentação.

### Fase 7 — Portabilidade, qualidade e entrega
- T7.1 Validação em container debian com bash 4+ (`make check`), incluindo o editor externo (`vi`), `cp -R`, `rm -rf` e `mktemp -d`.
- T7.2 Validação em containers centos e rhel, com os mesmos pontos.
- [x] T7.3 `shellcheck`: corrigir os avisos (feito: `make lint` limpo em `bin/`, `lib/` e `tests/`).
- T7.4 Documentação de uso.
- T7.5 Documentação do formato de arquivos (`parameters`, `raw_data`) e dos ambientes.
- T7.6 Teste ponta a ponta do fluxo completo.

### Adicionais — pendências e ajustes pós-validação (antes da Fase 8)
Reúne o que ficou em aberto até aqui. As tarefas de navegação dependem das validações com usuários: confirmar a necessidade antes de implementar. O que uma validação confirma sai daqui e vira tarefa de uma seção de revisão (ver "Revisão 1"). Origem de cada ponto em `DEVELOPMENT.md`, seção "Open items to validate with users".
- ~~TA.1~~ Confirmada pela Revisão 1 (R4): virou as TR.12 (`:rm` em request) e TR.13 (`:rm` em diretório).
- TA.2 Mover request ou diretório para outro diretório (por exemplo `:mv`). Renomear diretório foi para a TR.10; renomear request segue pelo campo `name` do menu de edição.
- TA.3 Esc cancela os prompts dos assistentes (`:n`, `:e`, `:d`, `:nd`) e as confirmações novas (`:ed`, `:c`, `:rm`). Hoje só nome vazio ou Ctrl-D cancelam.
- TA.4 Rever o Enter em duas etapas e a seleção que substitui a cor do método na linha destacada, conforme as validações (podem virar opção). A ordem entre request e resposta ao executar é a TR.14.
- TA.5 Histórico e Tab no modo comando.
- TA.6 Decidir se requests podem ser criadas na raiz do projeto (hoje só dentro de diretórios; `:n` na raiz explica e sugere `:nd`).
- TA.7 Redimensionamento do terminal: o menu não trata `SIGWINCH`; verificar o redesenho e o apagamento ao redimensionar. Inclui telas mais altas que o terminal (ajuda, detalhes com `raw_data` longo).
- TA.8 Código de saída de `req run` para respostas 4xx e 5xx (hoje 0; só falha em erro de transporte). Decisão pendente.
- TA.9 Teste em pseudo-terminal dentro da suíte (init, navegação, `:n`, `:q` e a chamada do editor externo), hoje só feito à mão; requer `python3` e é pulado sem ele.
- TA.10 `REQ_ESC_TIMEOUT` (50 ms) em conexões lentas, como SSH: validar e documentar o ajuste.
- TA.11 Validar em terminais reais sem UTF-8 e com `NO_COLOR`; os fallbacks existem, mas só foram testados em teste automatizado.
- TA.12 Descrição com várias linhas na tela de detalhes (hoje as quebras viram espaço).
- TA.13 Decidir se o próprio `TASKS.md` é traduzido para inglês (pergunta em aberto desde a tradução do projeto).

### Fase 8 — Extras (a detalhar ao final do projeto)
- T8.1 `timeout` por request.
- T8.2 `follow_redirects` por request.
- T8.3 `insecure` por request.
- ~~T8.4~~ Substituída pela TR.4: `raw_data` entra no lugar de `data_string`, com a regra de precedência sobre `parameters`.
- T8.5 Envio de arquivos.
- T8.6 Valores aninhados em `query`.
- ~~T8.7~~ Removida: JSON aninhado vai em `raw_data`; `parameters` fica plano (campos de formulário).

## Arquivos críticos (a criar)
`bin/req`, `lib/{core,ui,store,http,nav,cmd,wizard,env,log}.sh`, `tests/*`, `README.md`, `TASKS.md`.

## Verificação
Cada fase termina com seus testes passando e uma demonstração manual: Fase 2 dispara uma request real e mostra tempos; Fase 3 navega com setas/Enter/Esc; Fase 4 cria, edita e duplica requests geradas em disco; Revisão 1 mostra a ajuda `:h`, envia um POST com JSON editado no vim e renomeia, copia e remove diretórios conferindo o `.req`; Fase 5 troca de ambiente com `:env` e resolve secrets; Fase 6 gera log e verbose com `>>`/`<<`; Fase 7 roda em containers debian/centos.
