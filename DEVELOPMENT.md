# Development notes

How the code is built now, to pick the project up again without the conversation history.
User documentation is in [README.md](README.md); roadmap, decisions and open questions are in
[TASKS.md](TASKS.md). Working rules and the style guide are in `guideline.md`.

## Current state

The plan is complete: Phases 0 to 9 and Reviews 1 to 3 are done, except TR.14 (postponed by the
user) and T7.1/T7.2 (tests directly in the real debian, centos and rhel environments). No task is
pending. Next: a review session of questions Q1 to Q11 (TASKS.md, "Agenda for the next session") and
a new plan from the answers. The items in "Open items to validate with users" below wait for
usability sessions. The suite size and lint status are in TASKS.md, "Current state". Per-task history
is in TASKS.md and `git log`.

## Scope of use and the `.req`

`req` lives **outside** a development project: the project directory holds only `req` things, and the
menu lists every non-hidden item of its working directory, without filters. The `.req` file marks "a
req project was initialized here" and carries `workspace` (`key=value`): the working directory, a path
relative to the `.req`'s folder or `.` (the default). `req` sees only the workspace; the menu root is
the workspace and its items are read dynamically. Old one-directory-per-line entries are ignored.
`req init` (and the init offered by the menu) only writes the `.req` (a comment and `workspace=.`) and
prints `Use :n to create a new request.`

`req_project_workspace <.req>` (`lib/home.sh`) prints the absolute workspace path, or fails with a
reason that names the `.req`. The value (default `.`, also when the key is absent or the `.req` is
empty) must be relative, exist and be a plain directory inside the project folder, with no `..` that
leaves it and no symbolic link in any component. Components are checked in order, including those a
later `..` cancels, so `link/../x` is refused. A directory cannot be hard linked on Linux, so refusing
non-plain components is the whole check for "hard" links. The project folder itself may be reached
through a link: only the workspace part is checked.

## Architecture

`bin/req` is a thin entrypoint: it resolves its own directory (following symlinks), sources the
modules and dispatches (`req`, `req init`, `req run <file>`). Everything else is functions in `lib/`,
all prefixed `req_`.

| Module | Responsibility |
|---|---|
| `core.sh` | version, dependency checks, `req_err`/`req_warn`/`req_die`, `req_trim`, `req_abs_path`, terminal restore and traps, external editor helpers |
| `ui.sh` | colors (`req_color`), terminal size, `req_trunc`, `req_rule`, `req_confirm`, `req_prompt` |
| `store.sh` | request format and validation (`REQ_SCHEMA_JQ`), writing, listing (`req_list_dir`), `REQ_JQ_LEAVES` (flattens nested `query` values for the schema check, the details screen and the url) |
| `home.sh` | `~/.req`: `key=value` helpers, central directory, project registration, `req_project_workspace` |
| `http.sh` | builds the curl command, runs it, prints the response, the timing profile and the verbose output |
| `nav.sh` | the interactive menu: state, screen building, keys, main loop, init prompt, cursor save and restore |
| `cmd.sh` | command mode (`:n :nd :ed :cp :rm :e :d :env :config :log :v :h :q`) on top of `nav.sh` |
| `wizard.sh` | the prompts behind `:n`, `:e`, `:d`, `:nd`, `:ed`, `:cp` and `:rm` |
| `config.sh` | the settings (below) |
| `env.sh` | variables, key resolution and `${key}` substitution (below) |
| `log.sh` | the project log (below) |

Data flow of a run: `req_nav_run` loops build screen → draw → read key → handle key. Running a request:
`req_run_request` → `req_request_check` (validate) → `req_vars_load` and `req_subst_json` (environment
`REQ_ENV`, default `default`) → `req_build_curl_args` (one jq call) → `req_curl_exec` → print the
response and the profile. It sets `REQ_REQUEST_DIR`, so relative paths in `files` start at the request's folder.

**Settings (`config.sh`).** One table of known keys (`REQ_CONFIG_KEYS`, `_TYPE`, `_DEFAULT`, `_DESC`):
`time_stats`, `time_stat_total`, `restore_cursor`, `log`, `log_request_limit`, `max_redirects`.
`req_config_load` fills `REQ_CONFIG` from the global `~/.req/config` and then layers
`projects/<id>/config` over it (`req_config_load_local`, which also fills `REQ_CONFIG_LOCAL`).
Unknown keys, bad values and bad lines are warnings with path and line, never errors;
`req_config_get` falls back to the default. The project is activated after the first load, so
`req_nav_start` and `req run` call `req_config_load_local`. `:config key=value` writes the project's file
(the default: whoever uses `req` works on one project), `:config -g key=value` the global one.

**Variables (`env.sh`).** `req_vars_load <env> [id]` fills `REQ_VARS` from `projects/<id>/vars` and
`env/<env>`, the environment winning; the old `secrets.json` only gets a warning. `req_resolve_key
<env> <key>`: the process variable `<ENV>_<KEY>` first (`req_env_var_name`; hyphens become
underscores; a set but empty variable counts), then `REQ_VARS`. `req_subst <text> <env> [id]` puts the
text with every `${key}` replaced in `REQ_SUBST_OUT` (no subshell, so trailing line breaks survive) or
fails listing every missing key once, with the variable and files that define it. There is no escape for
a literal `${key}` yet (TA.14). `req_subst_json <request json> <env> [id]` does the same for a request:
it only touches the string values of `url`, `headers`, `query`, `parameters`, `raw_data` and `files`
(walking native JSON too) and keeps the result valid JSON. `req run` looks up the project of the
current folder without registering it. `req_env_list [id]` lists `projects/<id>/env/`;
`req_env_exists <env> [id]` is true for those and for `default`; `:env <name>` (`req_cmd_env`) validates
with it and sets `REQ_ENV` for the session only. Nothing is masked: the url shown, verbose and the log
carry the real values.

**Log and verbose (`log.sh`, `http.sh`).** The log is `projects/<id>/req.log`, written only with `log=yes`
(or `:log` for the session, `REQ_LOG_SESSION`, which wins) and a project open. `req_log_write <event>
<text>` is the single writer: `<ISO timestamp> <EVENT> <text>` on one line (line breaks become `\n`; an
unwritable file is one warning). `req_log_request <file> <env>` writes REQUEST (file, env, method, url,
` | header: ...`, ` | form: ...`, ` | file: field=path`, ` | body: ...`), `req_log_response` writes
RESPONSE from `REQ_RESP_*` (status, type, total time, ` | body: ...`) and `req_log_failure <code>` an
ERROR line. `req_log_trim` keeps the last `log_request_limit` lines. Verbose is `REQ_VERBOSE` (0 or 1,
toggled by `:v`): `req_verbose_request` prints `>>` lines right after `METHOD url`, and
`req_verbose_response` the status line and headers with `<<`. `req_curl_exec` runs curl with `-D -` and
`req_split_headers` fills `REQ_RESP_STATUSLINE`, `REQ_RESP_HEADERS` and the body, skipping `1xx` blocks
and, with `follow_redirects`, the `3xx` blocks of the hops.

### Request file format

`<slug>.<method>.json` (GET, POST, PUT, PATCH, DELETE); `name` equals the slug and is the menu label.
Required: `name`, `method`, `url`. Optional: `description`, `headers`, `query`, `parameters` (objects of
simple values; `query` may nest, see `REQ_JQ_LEAVES`: `f[a]=1`, `t[]=x`), `raw_data` (object, list or
string), `timeout` (positive number of seconds, `--max-time`, instead of `REQ_TIMEOUT`),
`follow_redirects` (boolean, `-L --max-redirs <max_redirects>`), `insecure` (boolean, `-k`) and `files`
(`{"field": "path"}`, sent as `multipart/form-data` with `-F field=@"path"`, `parameters` as
`--form-string`; refused together with `raw_data`; an unreadable file stops the run). Unknown or
mistyped fields invalidate the request; invalid files are reported, never rewritten. The old names
`data_parameter` and `data_string` are validation errors that point to `parameters` and `raw_data`.

The body is only sent with POST, PUT and PATCH. A non-empty `raw_data` is the body and wins over
`parameters`, which are always an url-encoded form. An object or list is sent as compact JSON, with
`Content-Type: application/json` only when the request has no `Content-Type` header; a string is sent
as it is with no automatic header (curl's default one is removed with `-H "Content-Type:"`).

The details screen shows `raw_data` under "Raw data" (indented JSON, or the text as it is), capped at
`REQ_RAW_MAX_LINES` (15) lines with a "... (N more lines)" marker. `parameters` is flagged "not sent"
when `raw_data` takes precedence, and both are flagged with GET and DELETE. The per-request extra fields
(`timeout`, `follow_redirects`, `insecure`, `files`) are not shown there nor asked by the wizards (Q7).

External editor (`lib/core.sh`): `req_editor` prints `$VISUAL`, `$EDITOR`, `vim` or `vi` (first that
exists; the variables may carry arguments, run through `sh -c`). `req_edit_text <text> [suffix]` edits
the text in `<tmpdir>/raw_data<suffix>` and fills `REQ_EDIT_TEXT` (trailing line breaks removed). Status
0 edited, 1 the editor failed (original text kept), 2 no editor (the caller falls back to a one-line
prompt). The caller hands the terminal over first (`req_nav_prompt_begin`); the helper does not.

Raw data editing (`req_ask_raw_data` in `lib/wizard.sh`): the edit menu's `8)` opens the text in the
editor (`.json` suffix). An empty text removes the field; an object or list is stored as native JSON;
other text is stored as a string after a "1) edit again 2) keep as text 3) discard" question, which is
skipped when the request has a `Content-Type` without `json`. `:n` reuses it: after a json, text or html
preset on POST, PUT or PATCH it asks "Write the body in your editor?" (default yes) and only asks for
`parameters` when declined. Without an editor, a one-line prompt (`-` clears) is used. The wizard
tests replace the editor with small `sh` scripts (`fake_editor`) or override `req_editor`.

### Navigation and item commands

Root (`lib/nav.sh`): `req_nav_root <.req>` is the single place that decides the menu root; it sets
`REQ_NAV_ROOT` from `req_project_workspace`, and `req_nav_init` fails (reason printed) when the workspace
is invalid. `REQ_CUR_DIR=""` means "the root", and `req_nav_load` lists `${REQ_CUR_DIR:-$REQ_NAV_ROOT}`
with `req_list_dir` (directories first). Labels and the breadcrumb are relative to the workspace
(`req_nav_rel`). The list header adds `<project> @ <environment>` after the position (`REQ_NAV_PROJECT`
is the folder of the `.req`; the environment is `${REQ_ENV:-default}`); it is dropped when fewer than 12
columns would be left for the path. Nothing but `workspace` is read from the `.req`.

`:nd` and `:n` create their directory or request in the item list's current directory (the workspace at
the root). The commands act on the item under the cursor according to its type:
- `:ed [name]` (`req_wizard_rename_dir`) renames a directory (last path component, `mv`); on a request
  it points to `:e`.
- `:cp [name]` (`req_wizard_copy_dir`, `req_wizard_copy_request`) copies with `cp -RP` next to the
  original, default name `<name>-copy` (asked again while taken), asking for the name right away; it does
  not open the edit menu.
- `:rm` on a request (`req_wizard_remove_request`) shows the full path, asks `[y/N]` (default no, end
  of input means no) and removes the file; it works for invalid requests, from the list and from the
  details screen, and keeps the selection near the removed row.
- `:rm` on a directory (`req_wizard_remove_dir`) shows a red warning with the full path and the count
  of files and subdirectories, asks `[y/N]`, then `rm -rf`. Only a directory **strictly inside** the
  workspace (physical path, `cd -P`) that is **not a symbolic link** is deleted; the workspace, its
  parents, outside directories and links are refused.

### Central directory (`lib/home.sh`)

`key=value` files: everything in `~/.req` is made of them. `req_kv_get`, `req_kv_list`, `req_kv_check`,
`req_kv_set` and `req_kv_unset` take the file as the first argument. One `key=value` per line, key
`[A-Za-z_][A-Za-z0-9_]*`, value = the rest after the first `=` (it may contain `=`), trimmed, one line,
no quotes. Blank lines and `#` lines are ignored; a duplicated key is won by its first line and
`req_kv_set` keeps only that one. Writes keep comments, blank lines and order, rewrite the file in place
(mode and symlinks survive) and create new files as 0600 inside 0700 directories. `req_kv_check` reports
bad lines with absolute path and line number; get and list silently skip them, so callers that want to
complain call check first.

Layout: `req_config_dir` (`$REQ_CONFIG_DIR` or `~/.req`), `req_projects_dir`, `req_project_state_dir
<id> [subpath]`. A project is registered by `req_project_create <dir>`, which makes `projects/<id>/` with
a `project` file (`name=` and `path=`, the physical absolute path) and prints the id;
`req_project_find_id <dir>` finds the id by that path (symbolic links and `..` resolve first). The id is
the slug of the folder name (`req_project_slug`), with `-2`, `-3`... when another path already uses it.
The project in use is `~/.req/current` (`project=<id>`): `req_current_get` returns nothing when the file
is missing, the id is not a slug or its directory is gone; `req_current_set` refuses unknown projects.
Files per project: `config` (`config.sh`), `vars` and `env/<env>` (`env.sh`), `req.log` (`log.sh`) and
`cursor`.

Registration: `req_project_activate <dir>` finds or creates the project and makes it the current one,
setting `REQ_PROJECT_ID`. It runs on `req init` and whenever the menu opens a `.req` (`req_nav_start`),
not on `req run`. If `~/.req` cannot be written it prints one `req: warning:` line (`req_warn`) and
returns 1; `req init` and the menu carry on without saved state.

Cursor: `req_nav_save_cursor` writes `dir` and `item` (relative to the workspace) to `cursor` on `:q`, at
the end of the input and on a signal (through `REQ_EXIT_HOOK`, which the EXIT trap `req_on_exit` runs).
`req_nav_restore_cursor` (called by `req_nav_run` right after `req_nav_init`) rebuilds the Esc stack down
to the saved directory and selects the item; a gone directory falls back to its nearest ancestor, a gone
item to the first, and a missing or invalid file (including `..`, absolute or empty components), no
project or `restore_cursor=no` mean the root.

## Testing

`make test` (or `tests/run.sh`) runs every `tests/test_*.sh` in its own bash; `make check` adds
`make lint`. Plain bash, no framework (`tests/helpers.sh`: `assert_eq`, `assert_contains`,
`test_summary`). A full `make check` takes more than two minutes on the development VM (each `jq` call
costs about 55 ms); run the test files in parallel when iterating.

- Helpers export `NO_COLOR=1`; tests that need colors set `REQ_COLORS=1` explicitly. Outside a terminal
  nothing is erased and no colors are used, which is what the tests rely on.
- Interactive flows are driven through `REQ_INPUT_FD`: tests set it to 3 and feed answers with
  `3<<<$'...'` (use `3</dev/null` for end of input; `<<<""` is an empty line, not EOF). The menu loop is
  fed by piping keys (`keys up down enter ...`).
- `REQ_CONFIG_DIR` points the configuration (`~/.req`) at a temp directory.
- `tests/mock_server.py` is a local echo server for GET, POST, PUT, PATCH and DELETE, with `/sleep/<ms>`,
  `/redirect` and `/loop`; with `<cert> <key>` it serves https. It needs `python3` (tests that use it skip
  without it), must keep working with Python 3.6 (RHEL 8, so no `ThreadingHTTPServer`), and the https test
  needs `openssl`.
- `tests/test_e2e.sh` drives the real `bin/req` in a pseudo-terminal through `tests/pty_run.py <chunk>...
  -- <command>` (each chunk is typed, then the driver waits for the output to go quiet for 0.5 s; Enter is
  `\r`; escape sequences are stripped), because `bin/req` refuses a stdin that is not a terminal. It
  skips without python3. Doing a pty run by hand: start the child in a scratch directory with `HOME`
  pointing to it (without a `.req` the init prompt appears and answering it creates files), and match the
  output after stripping ANSI codes (`req` and the path are separated by bold codes). The real `vim` as
  `$VISUAL` was also checked this way.
- Tests that feed a bare Esc through a pipe are timing sensitive: after a slow redraw (or with the
  machine under load) the reader sees the next bytes already in the pipe and takes them as part of the
  key sequence. Avoid a bare Esc in piped flows (`test_review_flow` is ordered so it needs none); the pty
  run is the place to exercise Esc.
- Tests that depend on file permissions avoid being fooled by root (the suite may run as root).

## Gotchas

- **jq 1.6**: `$label` is a reserved word; a syntax error in the input exits with a non-2 status (detect
  `parse error` in the message instead); every call costs about 55 ms on the development VM, so batch
  work into one call. Several modules do that by emitting `tag NUL value NUL` records and reading them
  with `read -r -d ''`, which also preserves newlines inside values.
- `read -s` restores echo between reads, so the menu session runs with `stty -echo` and the prompts
  switch it back on (`req_nav_prompt_begin` / `_end`).
- Esc versus arrow keys is told apart by waiting `REQ_ESC_TIMEOUT` (50 ms) for the rest of the sequence.
- curl: `--data-urlencode` encodes a space as `%20` or `+` depending on the version; the JSON body goes
  through stdin and the form uses `key=value` so a value starting with `@` is never read as a file.
- `make lint` runs `shellcheck` (0.9.0) over `bin/`, `lib/` and `tests/`. It follows every `source`, and
  the cost grows fast with the size of `lib/cmd.sh`: `tests/test_nav.sh` sources ten libraries and ran
  out of memory (the VM has 960 MB), so it does not follow them (`# shellcheck source=/dev/null`) and
  disables SC2034 for the file; keep that when adding libraries. It runs without `-x` on purpose: no
  config file is needed and each file is analysed on its own, so cross-module globals are not seen as
  used and carry `# shellcheck disable=SC2034` with the reason. The jq programs are single-quoted on
  purpose (`SC2016` disabled where they are declared).
- Only tested with bash 5.2, jq 1.6 and a recent curl; debian, centos and rhel coverage is T7.1 and
  T7.2. The code uses `declare -g` and other bash 4.2 constructs (Q6).
- curl changes the method (POST becomes GET) on 301, 302 and 303 redirects (Q8).

## Open items to validate with users

The navigation was built from the manifest plus assumptions. These are the points worth observing in
usability sessions; each one is cheap to change. Confirmed ones become tasks in TASKS.md.

1. **Enter in two steps**: Enter on a request opens the details and a second Enter runs it (TA.4).
2. **Selection highlight** replaces the method color on the selected row (bold bright green) (TA.4).
3. **Up/Down wrap around** at the ends of a list.
4. **Esc** does nothing at the root and there is no key to quit besides `:q` and Ctrl-C. Esc does not
   cancel inside the wizard prompts (an empty name or Ctrl-D does) (TA.3).
5. **Command mode**: no tab completion or history; unknown commands only show a one-line status
   message; `:q` never asks for confirmation (TA.5).
6. **Moving** a request or directory elsewhere does not exist (TA.2); `:e` renames a request only by
   changing its name field.
7. **Directory names are slugs** (no uppercase, dots or underscores), same as requests.
8. **Edit menu** is numbered fields (`1`-`8`, `s`, `q`) and is redrawn after each field; long
   header/query sets are edited one `key: value` line at a time.
9. **Long lists and long names**: scrolling is by window and names are truncated with `…`; very long
   names or paths on narrow terminals deserve a look.
10. **Non-UTF-8 terminals** fall back to ASCII (`>`, `#`, `~`); worth a quick check (TA.11).
