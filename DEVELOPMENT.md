# Development notes

Handoff document: everything needed to pick the project up again without the
conversation history. User-facing documentation is in [README.md](README.md); the
roadmap and task status are in [TASKS.md](TASKS.md) (written in Portuguese).

## Scope of use

`req` is meant, for now, to live **outside** a development project: the project directory holds
only `req` things (requests and their directories). Using it at the root of a code repository is
not a goal, so the menu lists every non-hidden item of its working directory without filters.
The `.req` file marks "a req project was initialized here" and carries the variable `workspace`
(`key=value`): the working directory, a path relative to the `.req`'s folder or `.` (the default,
the folder itself). `req` sees only the workspace; the menu root is the workspace and its items are
read dynamically, so the old one-directory-per-line entries are ignored (R11, decided; tasks TR3.1
to TR3.7 in TASKS.md; `req init` and the init offered by the menu already write only the `.req` (comment and
`workspace=.`, no `requests/`, `REQ_PROJECT_DEFAULT_DIR` is gone) and print `Use :n to create a new
request.`. The menu root is dynamic since TR3.3).

`req_project_workspace <.req>` (`lib/home.sh`, TR3.1) prints the absolute workspace path and fails with a
reason that names the `.req`. Rules: the value (default `.`, also when the key is absent or the `.req`
is empty or holds old entries) must be relative, exist and be a plain directory inside the project
folder, with no `..` that leaves it and no symbolic link in any component. Components are checked in
order, including those a later `..` cancels, so `link/../x` is refused. A directory cannot be hard
linked on Linux, so refusing non-plain components is the whole check for "hard" links. The project
folder itself may be reached through a link: only the workspace part is checked.

## Status

| Phase | State |
|---|---|
| 0 Foundation, 1 Data model, 2 curl execution, 3 Navigation, 4 Command mode | done |
| Review 1, usability findings (TR.1 to TR.15) | done, except TR.14 (postponed, needs the user's decision) |
| Review 3, R11 (`.req` with `workspace`, dynamic root; TR3.1 to TR3.7) | TR3.1 to TR3.7 done |
| Review 2, R8 to R10 (central project control in `~/.req`, `:config`, cursor; TR2.1 to TR2.10) | done |
| 5 Environments and variables | T5.1 replaced by TR2.4 (loading `vars` and `env/<env>`); T5.2 to T5.6 done; T5.7 dropped (no masking); T5.8 done |
| 6 Logs and verbose, 7 Portability and delivery, 8 Extras | pending |

Next task: **T6.1** (Phase 6; ask the user about the configuration options before implementing it; Phase 5 is done, T5.7 was dropped). Reviews 1 (except TR.14, postponed: it waits for the user's answer), 2 and 3 are done. See "Review 1 findings" below and TASKS.md, section "Fase 6".

Work rules agreed with the user (also in TASKS.md, "Decisões fechadas"):
- One task = one behavior, about 100 to 200 lines including tests, one commit.
  Helpers go in their own commit before the feature that uses them.
- What is already implemented counts as done; do not re-validate it.
- Everything in the repository is in English (code, messages, comments, tests,
  README). The conversation is in Portuguese, and so is TASKS.md.
- The `manifest` file is the user's and is git-ignored; never commit it.
- Nothing is committed by the assistant unless asked; the user commits.

## Architecture

`bin/req` is a thin entrypoint: it resolves its own directory (following symlinks),
sources the modules and dispatches (`req`, `req init`, `req run <file>`). Everything
else is functions in `lib/`, all prefixed `req_`.

| Module | Responsibility |
|---|---|
| `core.sh` | version, dependency checks, `req_err`/`req_die`, `req_trim`, `req_abs_path`, terminal restore and traps |
| `ui.sh` | colors (`req_color`), terminal size, `req_trunc`, `req_rule`, `req_confirm`, `req_prompt` |
| `store.sh` | request format and validation, writing, listing, `.req` project file, `req_project_init` |
| `http.sh` | builds the curl command, runs it, prints the response and the timing profile |
| `nav.sh` | the interactive menu: state, screen building, keys, main loop, init prompt |
| `cmd.sh` | command mode (`:n :nd :ed :cp :rm :e :d :config :h :q`) on top of `nav.sh` |
| `wizard.sh` | the prompts behind `:n`, `:e`, `:d` and `:nd` |
| `config.sh` | the global `~/.req/config`: one table of known keys (`REQ_CONFIG_KEYS`, `_TYPE`, `_DEFAULT`, `_DESC`), `req_config_load` (or `req_config_load_file <file>`) fills `REQ_CONFIG` (unknown keys, bad values and bad lines are warnings with path and line, never errors), `req_config_get` falls back to the default |
| `env.sh` | variable loading (`req_vars_load <env> [id]` fills `REQ_VARS` from `projects/<id>/vars` and `env/<env>`, the environment winning; the old `secrets.json` only gets a warning) and key resolution (`req_resolve_key <env> <key>`: process variable `<ENV>_<KEY>` (`req_env_var_name`, hyphens become underscores), then `REQ_VARS`; a set but empty process variable counts) and substitution (`req_subst <text> <env> [id]` puts the text with every `${key}` replaced in `REQ_SUBST_OUT`, with no subshell so trailing line breaks survive, or fails listing every missing key once with the variable and files that define it; there is no escape for a literal `${key}` yet, see TA.14) and `req_subst_json <request json> <env> [id]`, the same for a request: it only touches the string values of `url`, `headers`, `query`, `parameters` and `raw_data` (walking native JSON too) with jq, resolves every key first so the error lists them all, and keeps the result valid JSON. `req_run_request` calls `req_vars_load` and `req_subst_json` (environment `REQ_ENV`, default `default`) before building the curl command; `req run` looks up the project of the current folder without registering it; `req_env_list [id]` lists the files of `projects/<id>/env/` with a slug name and `req_env_exists <env> [id]` is true for those and for `default`, which `:env <name>` (`req_cmd_env` in `cmd.sh`) uses to validate before setting `REQ_ENV`; the choice lasts only for the session |

Data flow of a run: `req_nav_run` loops build screen → draw → read key → handle key.
Running a request: `req_run_request` → `req_request_check` (validate) →
`req_build_curl_args` (one jq call) → `req_curl_exec` → print body and profile.

### Request file format

`<slug>.<method>.json` (GET, POST, PUT, PATCH, DELETE); `name` equals the slug and is
the menu label. Required: `name`, `method`, `url`. Optional: `description`, `headers`,
`query`, `parameters` (objects of simple values), `raw_data` (object, list or string). Unknown or mistyped fields
invalidate the request; invalid files are reported, never rewritten. The body is only
sent with POST, PUT and PATCH. A non-empty `raw_data` is the body and wins over
`parameters`, which are always an url-encoded form (TR.4). An object or list is sent as
compact JSON, with `Content-Type: application/json` only when the request has no
`Content-Type` header; a string is sent as it is with no automatic header (curl's
default one is removed with `-H "Content-Type:"`). The old names `data_parameter` and
`data_string` are validation errors that point to `parameters` and `raw_data`; files are
not migrated.

The details screen shows `raw_data` under "Raw data" (indented JSON, or the text as it is),
capped at `REQ_RAW_MAX_LINES` (15) lines with a "... (N more lines)" marker. `parameters`
is flagged "not sent" when `raw_data` takes precedence, and both are flagged with GET and DELETE.

External editor (`lib/core.sh`, TR.6): `req_editor` prints `$VISUAL`, `$EDITOR`, `vim` or `vi`
(first that exists; the variables may carry arguments, run through `sh -c`).
`req_edit_text <text> [suffix]` edits the text in `<tmpdir>/raw_data<suffix>` and fills
`REQ_EDIT_TEXT` (trailing line breaks removed). Status 0 edited, 1 the editor failed
(original text kept), 2 no editor (the caller falls back to a one-line prompt). The
caller hands the terminal over first (`req_nav_prompt_begin`); the helper does not.

Raw data editing (`req_ask_raw_data` in `lib/wizard.sh`, TR.7 and TR.8): the edit menu's `8)` opens
the text in the editor (`.json` suffix). An empty text removes the field; an object or list
is stored as native JSON; other text is stored as a string after a "1) edit again 2) keep as
text 3) discard" question, which is skipped when the request has a `Content-Type` without
`json` (the user is clearly writing text or html). `:n` reuses it: after a json, text or html
preset on POST, PUT or PATCH it asks "Write the body in your editor?" (default yes) and only
asks for `parameters` when declined; the JSON question applies to the json preset only.
Without an editor, a one-line prompt (`-` clears) is used. An editor that fails leaves the
field untouched. The wizard tests replace the editor with small `sh` scripts (`fake_editor`)
or override `req_editor`.

Dynamic root (`lib/nav.sh`, TR3.3): `req_nav_root <.req>` is the single place that decides the menu root; it sets
`REQ_NAV_ROOT` from `req_project_workspace` and `req_nav_init` fails (reason printed) when the workspace is
invalid. `REQ_CUR_DIR=""` still means "the root", and `req_nav_load` lists `${REQ_CUR_DIR:-$REQ_NAV_ROOT}` with
`req_list_dir`, so the root shows the workspace's directories and requests like any directory (sorted:
directories first). Labels and the breadcrumb are relative to the workspace (`req_nav_rel`). The list header
adds `<project> @ <environment>` after the position (T5.5): `REQ_NAV_PROJECT` is the folder of the `.req`, set by
`req_nav_init`, and the environment is `${REQ_ENV:-default}`; it is dropped when fewer than 12 columns would be left
for the path. `REQ_NAV_ROOTS` and
the reading of `.req` lines are gone from the menu; `:nd` and `:n` at the root create
their directory or request in the workspace (TR3.4; `req_project_add_dir` and the `pfile` argument of
`req_wizard_mkdir` are gone) and nothing touches the `.req`. The `.req` entry helpers (TR.9) and the legacy
`.req` handling in the wizard were removed (TR3.5, TR3.6); the `.req` is only read for `workspace`
(`req_project_workspace`).

Directory rename (`req_wizard_rename_dir`, `:ed`, TR.10): renames the last path component with
`mv`; nothing else is touched.

Copy (`req_wizard_copy_dir` and `req_wizard_copy_request`, `:cp`, TR.11 and TR3.5): `cp -RP` next to the
original, default name `<name>-copy` (asked again while taken); it works on a directory or a request, asks
for the name right away and does not open the edit menu. `:c` no longer exists.

Request removal (`req_wizard_remove_request`, `:rm`, TR.12): shows the full path, asks `[y/N]` (default no,
end of input means no) and removes the file. It works for invalid requests, from the list and from the
details screen; afterwards the list is shown with the selection kept near the removed row.

Directory removal (`req_wizard_remove_dir`, TR.13): red warning with the full path and the count of
files and subdirectories, `[y/N]` (default no), then `rm -rf`. The safety rule: only a directory
**strictly inside** the folder of the `.req` (physical path, `cd -P`) that is **not a symbolic link**
is deleted; the project folder, its parents, outside directories and links never are. A listed
outside directory or link can only be unlisted. A listed directory loses its `.req` entry.
Descendants listed in the `.req` are not cleaned up (same limit as the rename).

## Conventions


- Functions return status codes; results travel in globals named `REQ_*`
  (`REQ_REPLY`, `REQ_LAST_FILE`, `REQ_SCREEN_LINES`, ...) because bash cannot return
  arrays or values without a subshell.
- Messages: `req_err "..."` for errors (always `req: error: ...` on stderr), plain
  `printf` for notices. Error messages about a file carry its **absolute path**.
- Names of requests, directories and environments are slugs (`^[a-z0-9]+(-[a-z0-9]+)*$`).
- Colors are decided **once** when `ui.sh` is loaded (`REQ_COLORS`). A per-call `-t 1`
  check breaks inside `$(...)`, where stdout is a pipe.
- The menu is redrawn in place: it erases the last block by moving the cursor up
  `REQ_SCREEN_DRAWN` rows. Never print inside the menu loop without
  `req_screen_erase` first. Lines that can wrap (the absolute path of an invalid
  request) must go through `req_screen_add_long` so the extra rows are counted.
- Outside a terminal nothing is erased and no colors are used, which is what the
  tests rely on.

`key=value` files (`lib/home.sh`, TR2.1): everything in `~/.req` is made of them. `req_kv_get`,
`req_kv_list`, `req_kv_check`, `req_kv_set` and `req_kv_unset` take the file as the first argument.
One `key=value` per line, key `[A-Za-z_][A-Za-z0-9_]*`, value = the rest after the first `=` (it may
contain `=`), trimmed, one line, no quotes. Blank lines and `#` lines are ignored; a duplicated
key is won by its first line and `req_kv_set` keeps only that one. Writes keep comments, blank
lines and order, rewrite the file in place (mode and symlinks survive) and create new files as
0600 inside 0700 directories. `req_kv_check` reports bad lines with absolute path and line number;
get and list silently skip them, so callers that want to complain call check first.

Central directory (`lib/home.sh`, TR2.2): `req_config_dir` (`$REQ_CONFIG_DIR` or `~/.req`, moved
here from `env.sh`), `req_projects_dir`, `req_project_state_dir <id> [subpath]`. A project is
registered by `req_project_create <dir>`, which makes `projects/<id>/` with a `project` file
(`name=` and `path=`, the physical absolute path) and prints the id; `req_project_find_id <dir>`
finds the id by that path (symbolic links and `..` resolve first). The id is the slug of the folder
name (`req_project_slug`), with `-2`, `-3`... when another path already uses it. The project in use
is `~/.req/current` (`project=<id>`): `req_current_get` returns nothing when the file is missing,
the id is not a slug or its directory is gone; `req_current_set` refuses unknown projects. The
files `vars` and `env/<env>` are read by `lib/env.sh` (TR2.4), `config` by `lib/config.sh` and `cursor` is written by the menu on exit (`req_nav_save_cursor`, TR2.8: `dir` and `item`, relative to the workspace, saved on `:q`, at the end of the input and on a signal through `REQ_EXIT_HOOK`, which the EXIT trap `req_on_exit` runs); `req_nav_restore_cursor` (TR2.9, called by `req_nav_run` right after `req_nav_init`) rebuilds the Esc stack down to the saved directory and selects the item; a gone directory falls back to its nearest ancestor, a gone item to the first, and a missing or invalid file (including `..`, absolute or empty components), no project or `restore_cursor=no` mean the root.

Registration (TR2.3): `req_project_activate <dir>` finds or creates the project and makes it the
current one, setting `REQ_PROJECT_ID`. It runs on `req init` and whenever the menu opens a `.req`
(`req_nav_start`), not on `req run`. If `~/.req` cannot be written it prints one `req: warning:`
line (`req_warn` in `core.sh`) and returns 1; `req init` and the menu carry on without saved state.

## Testing

`make test` (or `tests/run.sh`) runs every `tests/test_*.sh` in its own bash; `make check`
adds `make lint`. Plain bash, no framework (`tests/helpers.sh`: `assert_eq`,
`assert_contains`, `test_summary`). 1117 asserts at the time of writing.

- Helpers export `NO_COLOR=1`; tests that need colors set `REQ_COLORS=1` explicitly.
- Interactive flows are driven through `REQ_INPUT_FD`: tests set it to 3 and feed
  answers with `3<<<$'...'` (use `3</dev/null` for end of input; `<<<""` is an empty
  line, not EOF). The menu loop is fed by piping keys (`keys up down enter ...`).
- `tests/mock_server.py` is a local echo server (needs `python3`; those tests skip
  without it). It answers GET, POST, PUT, PATCH and DELETE.
- `REQ_CONFIG_DIR` points the configuration (`~/.req`) at a temp directory.
- A real terminal is not covered by the unit tests. The flows were verified by
  driving `bin/req` through a pty (`python3` + `pty.fork`), including the real `vim`
  as `$VISUAL` (TR.15: help, `:n` with a body typed in vim, details, `:c`, `:ed`, `:rm`,
  quit; echo, cursor and exit status were checked after the editor and after quitting).
  When doing that, always start the child in a scratch directory with `HOME` pointing
  to it: without a `.req` the init prompt appears and answering it creates files. Match
  the output after stripping ANSI codes (`req` and the path are separated by bold codes).
- Tests that feed a bare Esc through a pipe are timing sensitive: after a slow redraw (or
  with the machine under load) the reader sees the next bytes already in the pipe and takes
  them as part of the key sequence. Avoid a bare Esc in piped flows (`test_review_flow`
  is ordered so it needs none); the pty demo is the place to exercise Esc.
- A full `make check` takes more than two minutes on the development VM (each `jq` call
  costs about 55 ms); run the test files in parallel when iterating.

## Gotchas found so far

- **jq 1.6**: `$label` is a reserved word; a syntax error in the input exits with a
  non-2 status (detect `parse error` in the message instead); every call costs
  about 55 ms on the development VM, so batch work into one call. Several modules
  do that by emitting `tag NUL value NUL` records and reading them with
  `read -r -d ''`, which also preserves newlines inside values.
- `read -s` restores echo between reads, so the menu session runs with `stty -echo`
  and the prompts switch it back on (`req_nav_prompt_begin` / `_end`).
- Esc versus arrow keys is told apart by waiting `REQ_ESC_TIMEOUT` (50 ms) for the
  rest of the sequence.
- curl: `--data-urlencode` encodes a space as `%20` or `+` depending on the version;
  the JSON body goes through stdin and the form uses `key=value` so a value starting
  with `@` is never read as a file.
- `make lint` runs `shellcheck` (0.9.0) over `bin/`, `lib/` and `tests/` and is clean.
  `shellcheck` follows every `source`, and the cost grows fast with the size of `lib/cmd.sh`: `tests/test_nav.sh`
  sources ten libraries and ran out of memory (the VM has 960 MB), so it does not follow them
  (`# shellcheck source=/dev/null`) and disables SC2034 for the file. Keep that when adding libraries.
  It runs without `-x` on purpose: no config file is needed, and each file is analysed
  on its own. For that reason, cross-module globals are not seen as used, so they carry
  `# shellcheck disable=SC2034` with the reason; a new global shared between modules
  needs the same. The jq programs are single-quoted on purpose
  (`SC2016` disabled where they are declared).
- Only tested with bash 5.2, jq 1.6 and a recent curl; CentOS/RHEL/Debian stable
  coverage is Phase 7.

## Open items to validate with users

The navigation was built from the manifest plus assumptions. These are the points
worth observing in usability sessions; each one is cheap to change.

1. **Enter in two steps**: Enter on a request opens the details and a second Enter
   runs it. Is the extra step welcome or annoying?
2. **Selection highlight** replaces the method color on the selected row (bold bright
   green). Is losing the method color on that row a problem?
3. **Up/Down wrap around** at the ends of a list.
4. **Esc** does nothing at the root and there is no key to quit besides `:q` and
   Ctrl-C. Esc does **not** cancel inside the wizard prompts (an empty name or Ctrl-D does).
5. **Command mode**: no tab completion or history; unknown commands only show a
   one-line status message; `:q` never asks for confirmation.
6. **Deleting and renaming** came from the first usage review: `:rm`, `:ed` and `:cp` exist
   now (TR.10 to TR.13, TR3.5). Still open: moving a request or directory elsewhere (TA.2); `:e`
   renames a request only by changing its name field.
7. **Requests at the root**: answered. The root is the workspace and lists requests too (TR3.3);
   `:n` creates a request there (TR3.4).
8. **Directory names are slugs** (no uppercase, dots or underscores), same as requests.
9. **Edit menu** is numbered fields (`1`-`8`, `s`, `q`) and is redrawn after each
   field; long header/query sets are edited one `key: value` line at a time.
10. **Long lists and long names**: scrolling is by window and names are truncated with
    `…`; very long names or paths on narrow terminals deserve a look.
11. **Non-UTF-8 terminals** fall back to ASCII (`>`, `#`, `~`); worth a quick check.

Record findings as new tasks in TASKS.md rather than changing behavior ad hoc. What a
session confirms becomes a task in a review section (see "Review 1 findings" below);
what is still unconfirmed stays in "Adicionais" (TA.2 to TA.13). Items 1, 2, 4, 5, 7
and 11 above have a task there (TA.3 to TA.6 and TA.11), and so does the moving part
of item 6 (TA.2).

## Review 1 findings (2026-11-13)

First usability session. The notes are in the local `reviews` file (git-ignored, like
`manifest`); TASKS.md, section "Revisão 1", keeps the summary and the tasks.

| Finding | Outcome |
|---|---|
| R1 the result is shown above the request data | TR.14, postponed by the user: confirm before implementing. Preferred design: request data above, response below, compact footer |
| R2 no way to rename a directory | TR.9 (`.req` helpers), TR.10 `:ed [name]` |
| R3 no way to duplicate a directory with its contents | TR.11 `:c [name]` |
| R4 no way to remove a directory, even recursively | TR.12 `:rm` on a request, TR.13 `:rm` on a directory (red warning, `[y/N]`) |
| R5 no help listing every option | TR.2 `:h` |
| R6 POST with JSON typed by the user, through vim | TR.3 to TR.8: `parameters`, `raw_data`, external editor |
| R7 dependency error with `sudo` and `install` commands | TR.1 |

Decisions taken with the user (also in TASKS.md, "Decisões fechadas"):
- `data_parameter` is renamed `parameters`: form fields (key and value), always sent
  url-encoded.
- `raw_data` is the raw body, edited in the user's editor like git does (`$VISUAL`,
  `$EDITOR`, `vim`, `vi`; a one-line prompt when there is none). It is stored as native
  JSON (object or array) when the text is JSON and as a string otherwise. A non-empty
  `raw_data` wins over `parameters`. JSON without a `Content-Type` header is sent as
  `application/json`; free text gets no automatic header.
- Files using the old field names are not migrated; validation names the new field.
- `:rm` removes the request or the whole directory under the cursor, only inside the
  project, always after a `[y/N]` confirmation.

Open item 6 above is answered by these tasks and item 5 partly (`:h`); the others are
still open. TR.1 to TR.13 and TR.15 are done; TR.14 (R1) waits for the user.

## Roadmap

Review 1 (done except TR.14): TR.1 dependency error, TR.2 `:h`, TR.3 rename to
`parameters`, TR.4 `raw_data` format and sending, TR.5 `raw_data` on the details
screen, TR.6 external editor helper, TR.7 `8) raw data` in the edit menu, TR.8 raw
body in `:n`, TR.9 `.req` entry helpers, TR.10 `:ed`, TR.11 `:c`, TR.12 `:rm` on a
request, TR.13 `:rm` on a directory, TR.14 (postponed), TR.15 verification.

Review 2 (R8 to R10, in TASKS.md) goes before Phase 5: TR2.1 `key=value` helpers, TR2.2 central
directory and pointer, TR2.3 project registration, TR2.4 per-project environments (replaces the
`secrets.json` loader in `lib/env.sh`), TR2.5 to TR2.7 global config, `:config` and the
`time_stats` keys, TR2.8 and TR2.9 cursor save and restore, TR2.10 verification.

Phase 5: T5.2 key resolution, T5.3 pure `${key}` substitution with a friendly error
that lists the missing keys and tells how to fix them, T5.4 apply it to url, headers,
query, `parameters` and `raw_data`, T5.5 active environment (`REQ_ENV`, default
`default`) in the menu header, T5.6 `:env <name>`, T5.7 dropped (no secret masking, see TASKS.md), T5.8
verification and docs.
Environment variable names are `<ENV>_<KEY>` in upper case (`${url}` in `dev` is
`DEV_URL`); the variable wins over the environment file, which wins over the project variables.
Then Phase 6 (logs, verbose with `>>` and `<<`), Phase 7 (portability, docs), the
"Adicionais" section of TASKS.md (TA.2 to TA.13: everything still unconfirmed, mostly
navigation changes) and Phase 8 (per-request options, file upload, nested query
values).
