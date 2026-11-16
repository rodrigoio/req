# Task plan — `req` (interactive request tool for the terminal)

## Context
The `manifest` describes `req`: an interactive utility in bash + curl to register, browse and fire HTTP requests, with persistence in JSON files in a project directory. The repository was empty at the start (only `manifest`, `LICENSE`, `.gitignore`). This plan organizes the manifest in incremental phases, each delivering a verifiable structure or feature.

**Scope of use (project definition):** `req` is, initially, a solution to be used outside the scope of a development project: the `req` project directory holds only `req` things (requests and their directories). Using it at the root of a code repository is not a goal, and that is why the menu lists everything that is not hidden in the working directory, with no filters and no ignore list. When the folder has other content, the `workspace` variable of the `.req` (R11) points to the subdirectory that `req` sees.

## Current state (to resume)
- **Next session:** there is no pending task in the plan; review questions Q1 to Q11 (section "Questions for the final review", with the agenda) and make a new plan from the answers.
- Done: Phases 0 to 4, T5.1, Reviews 1 (TR.1 to TR.13 and TR.15; TR.14 stays postponed until the user decides), 2 (TR2.1 to TR2.10) and 3 (TR3.1 to TR3.7). Next task: **no pending task in the plan** (T9.1 and T9.2, the log and redirect limits, are done; Phase 8 is done, T8.1 to T8.6; the "Additional" items TA.2 to TA.14 depend on validation with users and questions Q1 to Q11 wait for the final review; Phase 7 is done, except T7.1 and T7.2, which wait for tests run directly in the real environments, without docker (T7.3 to T7.6 are done); Phase 6 is done, T6.1 to T6.7; Phase 5 is done, with T5.7 dropped).
- Agreed order: Phase 6 follows, since Phase 5 is done.
- Suite: `make check` with 1382 asserts, 0 failures, and `shellcheck` 0.9.0 clean in `bin/`, `lib/` and `tests/` (`make lint`).
- Pending items not yet confirmed are in the "Additional" section (TA.2 to TA.13), before Phase 8.
- Architecture, conventions, gotchas found so far and the list of navigation points to validate with users are in `DEVELOPMENT.md`. Findings from the validations enter here as new tasks.

## Closed decisions
- **Shell:** bash 4+. **Dependencies:** only `curl` and `jq`.
- **Code:** organized in functions, with no loose procedural scripts (manifest best practices).
- **Environments:** interactive switch with `:env <name>`.
- **Branches (decided):** one branch per task, with one or two slug-case terms plus a three-digit sequential number that never restarts (`log-request-001`, `log-response-002`, ...). The branch of each task starts from the branch of the previous task (the first one, from `main`); merges into `main` are done by another process, through pull requests. Details in `DEVELOPMENT.md`.
- **No docker (decided):** neither the tests nor the project operations use docker or any other container. The other environments (debian, centos, rhel) are tested directly in them, never simulated. No `tests/container.sh` and no `make container` target.
- **Local configuration by default (decided):** it is assumed that the user works on and configures a local project; so all configuration belongs to the project (`projects/<id>/config`) and `:config key=value` writes there. The global one (`~/.req/config`) is the exception and requires `-g`; the project's wins over the global one.
- **Precedence:** an environment variable wins over the environment file, which wins over the project variables (see "Central project control").
- **Missing placeholder:** `${key}` without a value gives a friendly error that tells the user how to proceed (expected file and variable, e.g. define `DEV_URL` or add `url=...` to the project's `dev` environment file); the request is not sent.
- **Valid JSON:** requests are always written as valid JSON. If the user invalidates it by hand, `req` only reports the error (file and jq detail), without trying to fix or overwrite it.
- **Git:** `manifest` stays in `.gitignore`.
- **`.req` and `workspace` (R11, decided):** the `.req` says that the project was initialized in the directory and carries the `workspace` variable (`key=value` format), the working directory of `req`: a path relative to the `.req` directory or `.` (the directory itself, the default). `req` only sees the `workspace`: the menu root is the workspace and directories are read dynamically, without the line mapping of the `.req`; old lines are ignored, with no migration. Validation (confirmed by the user): only a valid relative path that exists, is a directory and is inside the project directory; it refuses an absolute path, a `..` that leaves the project and any kind of link (symbolic or hard) in the path. This way the `:rm` protection keeps working. It replaces the mapping of TR.9 to TR.13 (marked as done, but part of the code goes away in Review 3).
- **Root lists everything (R11):** the menu lists all the items of the `workspace` with their type (directory or `.json` request), and the commands act according to the type of the item under the cursor. This closes TA.6: `:n` at the root creates the request there. **Item commands (decided in TR3.5):** `:ed` opens the edit mode to change the directory name (directories only; a request is edited with `:e`); `:cp` (formerly `:c`) copies the directory **or** the request and asks for the new name right away, without opening the edit mode; `:rm` removes either.
- **`req init` (R11):** only writes the `.req` (with `workspace=.`), without creating directories, and suggests that the user create a request: `Use :n to create a new request.`
- **Enter in two steps:** the 1st Enter on a request opens the details (url, params), the 2nd fires it; Esc goes back. This way the user checks before running.
- **Default environment:** `default`, used when `REQ_ENV` is not set; switch in the session with `:env <name>`.
- **Request fields:** required `name`, `method` and `url` (the `url` may use `${key}`); optional `description`, `headers`, `query`, `parameters` and `raw_data`. `parameters` is the new name of `data_parameter` (done in TR.3).
- **Slug name:** `name` is a slug (lowercase, digits and hyphens, e.g. `list-users`), identical to the file name (`<slug>.<method>.json`) and used as the label in the menu.
- **Strict validation:** an unknown field or a field with the wrong type invalidates the request and is reported to the user; the file is never changed.
- **Generic headers:** any valid header name, with a text, number or boolean value.
- **Body (Review 1, valid from TR.3 and TR.4):** sent only in POST, PUT and PATCH (GET and DELETE carry no body). `parameters` are form fields (simple key and value), always sent url-encoded. `raw_data` is the raw body: native JSON (object or list) when the text is JSON, a string in other formats; an empty string or a missing field means no raw body. A filled `raw_data` takes precedence over `parameters`. JSON without a `Content-Type` header goes out as `application/json`; free text gets no automatic header.
- **Old names:** files with `data_parameter` or `data_string` are not migrated; the validation points to the new name.
- **External editor:** `raw_data` is edited in the user's editor, as git does: `$VISUAL`, `$EDITOR`, `vim`, `vi`. With none of them, a one-line prompt is used.
- **Directory commands:** `:ed [name]` renames and `:cp [name]` (formerly `:c`) copies, with everything inside, the directory under the cursor; `:cp` also works for a request. `:rm` removes the request or the whole directory under the cursor, always with a `[y/N]` confirmation; for a directory the warning is in red and only things inside the project are deleted.
- **Help:** `:h` lists all keys and commands; every new command goes into it.
- **Dependency error:** only names the missing packages, in orange, with no install commands.
- **Methods:** GET (green), POST (blue), PUT (orange), PATCH (brown), DELETE (red).
- **Variables (formerly "secrets"):** a `key=value` file of the project environment (see below) or environment variables with a prefix; `${url}` resolves to `DEV_URL` (`dev` environment, key in uppercase). The old format `~/.req/env/<env>/secrets.json` (T5.1) is replaced by TR2.4, with no migration.
- **No secrets distinction, no masking (decided):** the variables of each project are physically isolated in `~/.req/projects/<id>/`, so all of them count as secret and there is no separate "secret" type, neither in the interpolation nor in the names (`req_vars_load`, `REQ_VARS`). The requests sent and the responses are known to whoever uses `req`, so nothing is masked: the url shown when running, the verbose output and the logs carry the real values. This drops T5.7.
- **Central project control (R10, from TR2.1):** everything that does not belong to the user's repository lives in `~/.req`, one directory per project. Everything is `key=value` text (blank lines and `#` ignored), since these are only simple flags and variables. Layout (confirmed in TR2.2):
  ```
  ~/.req/
    current                  pointer: id of the project in use
    config                   global settings
    projects/<id>/
      project                name=... and path=... (directory of the .req)
      config                 project settings (win over the global ones)
      vars                   project variables (valid in all environments)
      env/<environment>      environment variables (win over the project's)
      cursor                 last position in the menu (R8)
  ```
  The `<id>` is the slug of the project folder name (lowercase, digits and hyphens), with a `-2`, `-3`... suffix if it already exists for another path (confirmed with the user). The link with the project is the `path` of the `project` file; `current` holds `project=<id>`.
- **Configuration (R9):** `:config` lists the keys and `:config key=value` writes to `~/.req/config`; known keys live in a single table (type, default, description), like the `:h` help. An unknown key or an invalid value is refused with a message.
- **Cursor (R8):** on exit, `req` writes the directory and the selected item to `projects/<id>/cursor` and, on opening, goes back there; the `restore_cursor` key (default `yes`) turns it off.
- **Ready tasks:** what is already implemented counts as done, with no new validation; the work goes on only with what is missing.
- **Task size (review):** each task delivers a single behavior, in about 100 to 200 lines counting the tests, and becomes one commit. Infrastructure (helpers) goes in its own commit, before the feature that uses it. Each task carries only the tests of its own behavior; integrated scenarios go in a verification task at the end of the phase. If a task grows past that size, it is split before committing.

## Phases

### Phase 0 — Project foundation
- [x] T0.1 Layout: `bin/req` (thin entrypoint), `lib/*.sh` (function modules), `tests/`.
- [x] T0.2 Dependency check at startup (bash >= 4, curl, jq) with a clear error message.
- [x] T0.3 Utility module: ANSI colors (green GET, blue POST, orange PUT, red DELETE), error messages, terminal restore (`trap`).
- [x] T0.4 Minimal README, keep `.gitignore` as it is (it ignores `manifest`), define the test framework (bats or a dependency-free script of our own).

### Extra — Makefile (done before Phase 2)
- [x] `make test`, `make lint`, `make check`, `make install` and `make uninstall` (symbolic link in `~/.local/bin`, configurable through `PREFIX`/`BINDIR`).

### Extra — Initialization and language (done before Phase 4)
- [x] `req init` creates `.req` and `requests/`; without a `.req` in the directory, the interactive mode offers to initialize the project (`[Y/n]`).
- [x] All code, messages, comments, tests and README were translated to English (the project's only language). The project documents (`TASKS.md`, `DEVELOPMENT.md`) and `guideline.md` follow the same rule (see TA.13).
- `shellcheck` is only a development tool (`make lint`), not a runtime dependency.

### Phase 1 — Data model and persistence
- [x] T1.1 Format `<name>.<method>.json` with fields `name`, `method`, `url`, `headers`, `query`, `data_parameter`, `data_string` (`url` and `description` added; see Closed decisions). PATCH included, in brown; `data_string` removed for now.
- [x] T1.2 Functions to read/write/validate the JSON through jq (the manifest example has no commas; the written JSON must be valid) and detection of JSON invalidated by manual editing, only reporting the error.
- [x] T1.3 The project `.req` file: list of directories that make up the project; parser and lookup in the current directory.
- [x] T1.4 Listing of a directory, telling real subdirectories from request files.
- [x] T1.5 Tests of the persistence and listing functions.

### Phase 2 — Request execution (curl core)
- [x] T2.1 Build the curl command from the request (url, encoded querystring, headers, body in `data_parameter` or `data_string`).
- [x] T2.2 Run and show the response in the terminal without writing files (stdout/pipe), with formatting for JSON, text and HTML.
- [x] T2.3 Timing profile per stage through `curl -w` (DNS, connection, TLS, TTFB, total) shown as a horizontal bar per stage.
- [x] T2.4 Visual separator (`---` or `===`) between the result and the rebuilt menu.
- [x] T2.5 Tests with a simple local server or a mock.

### Phase 3 — Interactive navigation
- [x] T3.1 Infinite menu loop: up/down arrows, Enter, Esc (capture of escape sequences with `read -rsn`).
- [x] T3.2 Root menu with the directories of the `.req`; entering a directory lists subdirectories and requests, with an icon/label telling each one apart.
- [x] T3.3 Request details screen (url, description, params, headers); Enter fires, Esc goes back; at the root Esc does nothing.
- [x] T3.4 Colors per method in the listing and in the details.

### Phase 4 — Command mode and management of requests and directories
- [x] T4.1 Input helpers: `req_trim`, `req_prompt` (one line, with a default) and `req_confirm` with a `[y/N]` default.
- [x] T4.2 Command mode: `:` opens the prompt in the footer, typing, Backspace, Esc cancels, an empty or unknown command shows a status message.
- [x] T4.3 `:q` quits without asking for confirmation, restoring the terminal.
- [x] T4.4 `req_project_add_dir`: creates the directory and lists it in the `.req` (function and tests, no UI).
- [x] T4.5 `:nd [name]` (alias `:mkdir`): at the root creates it and lists it in the `.req`; inside a directory creates a real subdirectory; refreshes the list and selects the new one.
- [x] T4.6 Minimal `:n`: asks for name (slug), method and url and creates the request in the current directory; friendly error at the root.
- [x] T4.7 `:n` simple optional fields: description, querystring and parameters (POST, PUT and PATCH only).
- [x] T4.8 `:n` headers: presets json, text and html and `key: value` pairs.
- [x] T4.9 `:e` simple fields: menu for name, method, url and description, with file renaming and protection against overwriting.
- [x] T4.10 `:e` collections: headers, query and parameters (a `key=value` pair sets, `-key` removes).
- [x] T4.11 `:d`: duplicates the selected request and opens the edit menu on the copy.
- [x] T4.13 Absolute path in invalid requests: the details screen and the validation messages show the full path, on its own line and untruncated, to copy and fix in another terminal.
- [x] T4.12 Phase verification: integrated flow through the main loop, demonstration in a real terminal and a commands section in the README.

### Review 1 — findings from the usage validation (before Phase 5)
First real-use session, on 2026-11-13. The findings were kept in the local `reviews` file (not versioned, like `manifest`); the summary below is the record in the repository. Execution order: first what the review treats as mandatory (R7, R5, R6), then the rare directory cases (R2 to R4); R1 was postponed.

Findings:
- **R1** When running, the result shows above the request data; with a large response it is hard to compare. Suggestion: request data above, response below.
- **R2** There is no way to rename an existing directory. Suggestion: `:ed` with the directory under the cursor.
- **R3** There is no way to duplicate a directory with everything inside. Suggestion: `:c` with the directory under the cursor.
- **R4** There is no way to remove a directory, recursively included. Suggestion: `:rm`, with a red warning and a yes or no confirmation.
- **R5** A help menu with all the options is missing: `:h`.
- **R6** It must be possible to send a POST with JSON typed by the user, with the option in the edit menu; when `vim` or `vi` exists, call the editor in the middle of the program, like git, and go back to the flow.
- **R7** The dependency error must not carry `sudo` or `install` commands; it should only point out the missing packages in another color (orange).

Tasks:
- [x] TR.1 (R7) Dependency error: one line that only names the missing packages, in orange, with no `sudo` or `install`.
- [x] TR.2 (R5) `:h` (alias `:help`): help screen with all keys and commands, from a single table; any key goes back. The unknown-command notice and the footers now point to `:h`.
- [x] TR.3 (R6) Rename `data_parameter` to `parameters`, without changing what is sent; the old name becomes a validation error that points to the new one.
- [x] TR.4 (R6) `raw_data` in the format and in the sending: object, list or string; precedence over `parameters`, which is now always a url-encoded form; JSON without `Content-Type` goes out as `application/json`.
- [x] TR.5 (R6) The details screen shows the `raw_data` (indented JSON or text, with a line ceiling) and warns when `parameters` is not sent.
- [x] TR.6 (R6) External editor helper (`req_editor`, `req_edit_text`): `$VISUAL`, `$EDITOR`, `vim`, `vi`, in a temporary file, like git. Infrastructure, own commit.
- [x] TR.7 (R6) Edit menu: option `8) raw data` opens the editor with the JSON; valid JSON is written native, text that is not JSON offers to edit again or keep it as text; without an editor, a one-line prompt.
- [x] TR.8 (R6) `:n` with a format preset (json, text, html) offers the raw body in the editor instead of asking for `parameters`.
- [x] TR.9 (R2 to R4) `.req` helpers: find, replace, remove and append an entry, preserving comments and order. Infrastructure, own commit.
- [x] TR.10 (R2) `:ed [name]` renames the directory under the cursor; at the root it updates the `.req` entry.
- [x] TR.11 (R3) `:c [name]` (renamed to `:cp` in TR3.5) copies the directory under the cursor with everything inside (default `<name>-copy`); at the root it lists the copy in the `.req`.
- [x] TR.12 (R4, TA.1) `:rm` on a request: `[y/N]` confirmation and removal, in the list and in the details screen; also works for an invalid request.
- [x] TR.13 (R4) `:rm` on a directory: red warning with the path and the content count, `[y/N]` confirmation, recursive removal only inside the project; at the root it takes the entry out of the `.req`.
- TR.14 (R1) **Postponed: confirm with the user before implementing.** When running, the request data stays above and the response below. Preferred design for the footer: compact (request name and keys), with Enter running again.
- [x] TR.15 Review verification: integrated flow through the main loop, demonstration in a real terminal (pty) and final review of the README and `DEVELOPMENT.md`.

### Phase 5 — Environments and variables
Prerequisite: TR2.1 to TR2.4 (Review 2, at the end of the plan), which define where the environments of each project live. The tasks below are already adjusted to that.
- [x] T5.1 Reading of `~/.req/env/<env>/secrets.json` through jq; invalid JSON only reports the error. (Replaced by TR2.4: the loader now reads the project's `key=value`.)
- [x] T5.2 Resolution of a key, in precedence order: variable `<ENV>_<KEY>`, environment file (`projects/<id>/env/<environment>`), project variables (`projects/<id>/vars`).
- [x] T5.3 Substitution of `${key}` in a text (pure function), with a friendly error that lists the missing keys and guides the user (expected variable and the project's environment file).
- [x] T5.4 Apply the substitution to url, headers, query, `parameters` and `raw_data` (including the strings inside the native JSON) before running.
- [x] T5.5 Active project and environment (`REQ_ENV`, default `default`) shown in the menu header.
- [x] T5.6 `:env <name>` switches the environment in the session and validates a nonexistent environment (file in `projects/<id>/env/`); without an argument it lists the project's environments; it goes into the `:h` help.
- ~~T5.7~~ Dropped (see "No secrets distinction, no masking"): the physical isolation of variables per project makes masking unnecessary. In its place, the code and texts stop talking about "secrets" (`req_vars_load`, `REQ_VARS`).
- [x] T5.8 Phase verification (real execution with the mock server: `vars`, environment file and process variable, in that precedence; missing key with a friendly error) and documentation of the environments and project variables in the README.

### Phase 6 — Logs and verbose
- [x] T6.1 Project configuration (`projects/<id>/config`) over the global one (`~/.req/config`, created in TR2.5), reusing the `key=value` helpers and the key table: precedence (the project's wins). Decided with the user: by default it is assumed that one works on and configures a local project, so `:config key=value` writes to the project and `:config -g key=value` to the global one (with no project open, the default warns and suggests `-g`). The only log key, for now, is `log=yes|no` (default `no`); format and file name are left out.
- [x] T6.2 Log of the request sent, with a timestamp, in a file. Decided with the user: `projects/<id>/req.log`, one line of text per event (`lib/log.sh`), only with `log=yes` and a project open; the line carries file, environment, method, url, headers, form fields and body, with the real values.
- [x] T6.3 Log of the response received, in the same file: a `RESPONSE` line (status, type, total time and the whole body) or `ERROR` when there was no response. Without the response headers for now (T6.5 starts capturing them; see the questions for the final review).
- [x] T6.4 Verbose: data sent (`parameters` or `raw_data`) with `>>` in the terminal. Verbose is the `REQ_VERBOSE` variable (0 or 1; the process environment may set it), which T6.6 toggles with `:v`; each form field or body line gets a dimmed `>>`, right after `METHOD url`.
- [x] T6.5 Verbose: response (headers included) with `<<` in the terminal: the status line and each header, right after sending and before the normal display (which shows the formatted body). The headers come from `curl -D -` (`req_split_headers`).
- [x] T6.6 `:log` and `:v` toggle logs and verbose in the session (optional `yes|no` argument, also `on|off`; `:verbose` is an alias of `:v`); they go into the `:h` help. The choice holds until exit (`REQ_LOG_SESSION`, `REQ_VERBOSE`) and does not change the configuration; `:log` requires an open project.
- [x] T6.7 Phase verification (real binary: no file with `log=no`; with `log=yes` and `REQ_VERBOSE=1` the `req.log` comes out with `REQUEST` and `RESPONSE`, the `>>` and `<<` lines; `:v` and `:log` through the menu in a pty) and documentation (README: sections "Verbose" and "Log"; `DEVELOPMENT.md`: `log.sh` and the verbose in `http.sh`).

### Questions for the final review (noted during the continuous execution)
Doubts and choices made by default while the tasks went on without stopping; each item says what was done and what to decide.
- ~~Q1~~ Decided: `req.log` keeps the last `log_request_limit` lines (default 500, configurable; `0` for no limit; a new integer key in the configuration table). Still open: only the size of each line (the whole body) and a command to clear the log.
- Q2 (T6.3) The response log does not carry the response headers. Decide whether they should go in (T6.5 captures them for the verbose).
- Q3 (T6.4) Verbose is only the `REQ_VERBOSE` variable (or `:v` in T6.6); there is no `verbose` key in the config and no `-v` option in `req run`. Decide whether there should be.
- Q4 (T6.5) In verbose, the response shows only the status line and the headers with `<<`; the body stays in the normal display (formatted), without `<<`. Decide whether each body line should also carry `<<`.
- Q5 (T6.6) **Answered on 2026-11-14: keep the decision for now; the user will do more validations before deciding.** `:log` and `:v` hold only for the session and do not change the configuration (`:log` overrides the `log` key until exit). Decide whether `:log`/`:v` should be able to write the key, and whether `:v` should have a `verbose` key (tied to Q3).
- Q6 (T7.1/T7.2) Still no validation in the real environments (T7.1/T7.2); the functions use `declare -g` and other bash 4.2 constructs, but there is no test on bash 4.0 to 4.3 (for example CentOS 7, already out of support). Decide whether the declared minimum should become "bash 4.4+" or whether a test in a real environment with bash 4.2 is needed.
- Q7 (T8.1 to T8.3) The extra per-request fields (`timeout`, `follow_redirects`, `insecure`) exist only in the JSON file: they do not appear in the details screen, the wizards (`:n`, `:e`) do not ask for them, and `REQ_CONNECT_TIMEOUT` stays variable-only. Decide whether they go into the details screen and the wizard, and whether `timeout`/`insecure` should also exist as configuration keys.
- Q8 (T8.2) The redirect limit is now the `max_redirects` key (T9.2, decided), but curl still changes the method (POST becomes GET) on 301, 302 and 303. Decide whether the method should be kept (`--post301`/`--post302`/`--post303`).
- Q9 (T8.3) With `insecure` on, nothing warns that the certificate was not verified (neither on the run screen nor in the log). Decide whether there should be a warning.
- Q10 (T8.5) File sending was defined by default (the task had no details): field `files`, always `multipart/form-data`, with no configurable MIME type or file name (`;type=`, `;filename=`), several files only with fields of different names, and the file content does not go to the log. Decide whether that is enough and whether a raw binary body (`--data-binary @file`) is also needed.
- Q11 (T8.6) The nesting of `query` uses bracket notation (`filter[a]=1`, `tags[]=x`), the most common in web frameworks, and encodes the brackets in the url. Decide whether another convention is needed (lists repeating the name without `[]`, or dot notation) and whether `parameters` (form) should also accept nested values, which T8.7 removed.

**Agenda for the next session (to review one by one, in a new plan):**
1. Q2, Q3, Q4, Q6, Q7, Q9, Q10 and Q11: no answer yet.
2. Q1 and Q8: partly decided; what remains is the size of each log line and a command to clear it (Q1) and the method change on redirects (Q8).
3. Q5: validate with real use before deciding.
4. Also open: TR.14 (request above the response when running, postponed by the user), TA.2 to TA.14 (they wait for validation with users; TA.9 is partial, the external editor is missing; TA.14 is the literal `${key}`) and the decision on what to do with the branch stack `log-request-001` to `max-redirects-015` (merges into `main` are done by another process, through pull requests).

### Phase 7 — Portability, quality and delivery
- T7.1 Validation in a debian environment with bash 4+ (`make check`), including the external editor (`vi`), `cp -R`, `rm -rf` and `mktemp -d`. It will be done directly in the real environment, with no docker or container.
- T7.2 Validation in the centos and rhel environments, with the same points, also directly in them. Findings already made and kept: `mock_server.py` used `ThreadingHTTPServer` (Python 3.7+, RHEL 8 has 3.6), which silently skipped the execution tests; it was fixed. Missing `diffutils` (`cmp`) on minimal installs is a point to check.
- [x] T7.3 `shellcheck`: fix the warnings (done: `make lint` clean in `bin/`, `lib/` and `tests/`).
- [x] T7.4 Usage documentation (README): usage, the exit code of `req run`, the "The central directory" section and the fix of outdated passages ("nothing is written to disk", the `log` key in the configuration table).
- [x] T7.5 Documentation of the file format (`parameters`, `raw_data`), of the `.req` (`workspace`), of the layout of `~/.req` (projects, environments, variables, configuration, cursor) and of the environments.
- [x] T7.6 End-to-end test of the complete flow: `tests/test_e2e.sh` runs the real `bin/req` in a pseudo-terminal (`tests/pty_run.py`, which also covers TA.9) with the mock server: `init`, creating the request through the menu, variables and environments, `:env`, process variable, missing key, `:log`, `:v`, `:config log=yes` and `req run`.

### Additional — pending items and post-validation adjustments (before Phase 8)
Gathers what was left open so far. The navigation tasks depend on validations with users: confirm the need before implementing. What a validation confirms leaves here and becomes a task of a review section (see "Review 1"). Origin of each point in `DEVELOPMENT.md`, section "Open items to validate with users".
- ~~TA.1~~ Confirmed by Review 1 (R4): it became TR.12 (`:rm` on a request) and TR.13 (`:rm` on a directory).
- TA.2 Move a request or directory to another directory (for example `:mv`). Renaming a directory went to TR.10; renaming a request still goes through the `name` field of the edit menu.
- TA.3 Esc cancels the prompts of the wizards (`:n`, `:e`, `:d`, `:nd`) and the new confirmations (`:ed`, `:cp`, `:rm`). Today only an empty name or Ctrl-D cancel.
- TA.4 Review the two-step Enter and the selection that replaces the method color on the highlighted line, according to the validations (they may become an option). The order between request and response when running is TR.14.
- TA.5 History and Tab in command mode.
- ~~TA.6~~ Decided by Review 3 (R11): the root is the `workspace` and lists requests and directories; `:n` at the root creates the request (TR3.4).
- TA.7 Terminal resizing: the menu does not handle `SIGWINCH`; check the redraw and the erasing on resize. It includes screens taller than the terminal (help, details with a long `raw_data`).
- TA.8 Exit code of `req run` for 4xx and 5xx responses (today 0; it only fails on a transport error). Decision pending.
- TA.9 Pseudo-terminal test inside the suite (init, navigation, `:n`, `:q` and the external editor call), today only done by hand; it requires `python3` and is skipped without it. **Partly done by T7.6** (`tests/pty_run.py`: init, `:n`, navigation, `:env`, `:v`, `:log`, `:config`, `:q`); the external editor call (`:e`) is missing.
- TA.10 `REQ_ESC_TIMEOUT` (50 ms) on slow connections, such as SSH: validate and document the setting.
- TA.11 Validate in real terminals without UTF-8 and with `NO_COLOR`; the fallbacks exist, but were only tested in an automated test.
- TA.12 Multi-line description in the details screen (today the line breaks become spaces).
- ~~TA.13~~ Decided: `TASKS.md`, `DEVELOPMENT.md` and `guideline.md` are written in English, like the rest of the project (rule 10 of `guideline.md`); translated on `main`.
- TA.14 How to write a literal `${key}` (not substituted) in a request: today there is no escape, so a text such as `${x}` with no value defined is always an error (T5.3). Options: `$${x}`, a backslash before it, or leave it unescaped. Decide before T5.4 is used with a `raw_data` that contains that snippet.

### Phase 8 — Extras (to be detailed at the end of the project)
- [x] T8.1 Per-request `timeout`: optional `timeout` field (positive number, in seconds) that applies instead of `REQ_TIMEOUT` (default 60); validated in `REQ_SCHEMA_JQ`, used in `--max-time`. File only: it does not appear in the details screen or in the wizards (see Q7).
- [x] T8.2 Per-request `follow_redirects`: optional boolean field (default `false`), validated in `REQ_SCHEMA_JQ`; it turns on `-L --max-redirs 10`, and `req_split_headers` discards the 3xx blocks of the hops (the last one counts). `mock_server.py` got `/redirect` and `/loop`.
- [x] T8.3 Per-request `insecure`: optional boolean field (default `false`), validated in `REQ_SCHEMA_JQ`, turns on `-k`. `mock_server.py` serves https when it receives a certificate and key (the test generates a self-signed one with `openssl`, also installed by `tests/container.sh`).
- ~~T8.4~~ Replaced by TR.4: `raw_data` takes the place of `data_string`, with the precedence rule over `parameters`.
- [x] T8.5 File sending: optional `files` field (`{"field": "path"}`) that sends `multipart/form-data` (`-F field=@"path"`), with `parameters` as text fields (`--form-string`); a relative path starts at the request's folder (`REQ_REQUEST_DIR`); `${key}` works in the field; an unreadable file stops the run; `files` together with `raw_data` is refused in the validation. It enters the verbose (`>> field=@path`) and the log (`| file: field=path`).
- [x] T8.6 Nested values in `query`: an object becomes `key[sub]=value` and a list becomes `key[]=value` (brackets encoded in the url; empty ones omitted; `null` refused). Shared jq definition (`REQ_JQ_LEAVES`) between the validation, the details screen and the url assembly.
- ~~T8.7~~ Removed: nested JSON goes in `raw_data`; `parameters` stays flat (form fields).

### Phase 9 — Adjustments decided in the final review
- [x] T9.1 Line limit of `req.log`: key `log_request_limit` (integer, default 500, `0` for no limit), in the new `int` type of the configuration table; `req_log_trim` cuts the oldest lines after each write.
- [x] T9.2 Redirect limit in the configuration (global and project), with a default value, in place of the fixed 10 of `follow_redirects` (Q8): integer key `max_redirects` (default 10), used in `--max-redirs`. Still open is only the method change (POST becomes GET) on 301/302/303.

### Review 2 — findings from the usage validation (R8 to R10; at the end of the plan)
Continuation of the local `reviews` file (R1 to R7 are in Review 1). TR2.1 to TR2.4 come before Phase 5.

Findings:
- **R8** On exit, navigation restarts at the root. Suggestion: save the cursor position in the configuration directory (`~/.req`) and resume from it when opening `req`.
- **R9** A command to edit global settings is missing (presentation and future features), by key and value: `:config time_stats=no`, `:config time_stat_total=yes`.
- **R10** A central project control in `~/.req` is missing: for each initialized project, a control with its own environments and variables; a pointer file to the project in use; one file per environment, only `key=value`. It impacts Phase 5 and the configuration of T6.1.

Tasks (R10, before Phase 5):
- [x] TR2.1 (R10) `key=value` file helpers: read a key, list, write and remove, preserving comments, blank lines and order; names `[A-Za-z_][A-Za-z0-9_]*`, one-line values. Infrastructure, own commit.
- [x] TR2.2 (R10) Central directory: layout helpers (`~/.req` or `REQ_CONFIG_DIR`, `projects/<id>/`, `project` file with `name` and `path`), project id from the folder, and the `current` pointer (read and write). Infrastructure, own commit.
- [x] TR2.3 (R10) Project registration: `req init` and the first opening of a `.req` not yet registered create the project control; opening a registered project updates `current`; if `~/.req` is not writable, the menu keeps working and warns once.
- [x] TR2.4 (R10) Environments per project: the secrets loader (T5.1) reads `projects/<id>/env/<environment>` and `projects/<id>/vars` as `key=value`, with the environment winning over the project variables; `secrets.json` is no longer read (no migration; if the old file exists, a warning points to the new location).

Tasks (R9):
- [x] TR2.5 (R9) Global configuration: `~/.req/config` as `key=value`, with the single table of known keys (type, default, description) and validated reading; an unknown key in the file is warned about and ignored. Infrastructure, own commit.
- [x] TR2.6 (R9) `:config`: without an argument lists the keys with current value and default; `:config key=value` validates and writes; an unknown key or an invalid value explains and lists the valid ones; it goes into the `:h` help.
- [x] TR2.7 (R9) Presentation keys `time_stats` (timing profile) and `time_stat_total` (total line), `yes` or `no`, default `yes`, applied by `req_run_request` and by `req run`.

Tasks (R8):
- [x] TR2.8 (R8) Save the cursor on exit (`:q`, end of input and signals) in `projects/<id>/cursor`: current directory and selected item, relative to the `workspace`, as `key=value`.
- [x] TR2.9 (R8) Resume the cursor on opening: goes back to the directory and the item (the Esc stack is rebuilt); a nonexistent directory leads to the nearest ancestor, a nonexistent item to the first; a missing or invalid file leads to the root with no error; the `restore_cursor` key (default `yes`) turns the resuming off.
- [x] TR2.10 Review 2 verification: integrated flow through the main loop (quit and reopen in the same place, `:config`, registered project), demonstration in a real terminal (pty) and final review of the README and `DEVELOPMENT.md`.

### Review 3 — finding R11 (run now, before TR2.4)
Continuation of the local `reviews` file.

Finding:
- **R11** Use the project's `.req` only as a reference that the directory was initialized, and load the directories dynamically, without the mapping. User answers: the root lists all the items and their types and the commands act according to the type; the `.req` will have the `workspace` variable (a valid relative path or `.`), which must be in the documentation; `req init` only initializes the file and suggests `:n`.

Tasks:
- [x] TR3.1 (R11) Helper `req_project_workspace <.req>`: reads `workspace` through the `key=value` helpers (default `.` when absent; lines that are not `key=value`, such as the old entries, are ignored), validates and prints the physical path. Rules: only a relative path that exists and is a directory inside the project (no `..` that leaves it, no absolute path), and no component of the path may be a symbolic link; hard links are also refused (a directory does not accept a hard link on Linux, so the practical check is the symlink one, and a component that is not a regular directory is refused). Friendly error with the absolute path of the `.req` and the reason. Infrastructure, own commit.
- [x] TR3.2 (R11) `req init` and the initialization offered by the menu only write the `.req` (comment and `workspace=.`), without creating `requests/` (`REQ_PROJECT_DEFAULT_DIR` goes away), and show `Use :n to create a new request.`; an existing `.req` is still refused. README: section about the `.req` and the `workspace` variable.
- [x] TR3.3 (R11) Dynamic root: the menu root is the `workspace` and lists all the items (directories and requests, with the type) through `req_list_dir`; `REQ_NAV_ROOTS` and `req_project_dirs` go away. A single point (`req_nav_root`) decides the root directory; the title and the relative paths start from the `workspace`.
- [x] TR3.4 (R11, TA.6) Commands at the root: `:n` creates the request in the `workspace`; `:nd` creates a plain directory, without touching the `.req` (`req_project_add_dir` goes away); the "open a directory first" warning disappears.
- [x] TR3.5 (R11) Item commands without the `.req` logic (listed entry, "outside the project", unlist), acting on the item under the cursor according to the type: `:ed [name]` renames the directory (opens the question for the new name; on a request it warns that the edit is `:e`); `:cp [name]` replaces `:c` and copies a directory or request asking for the new name right away (default `<name>-copy`), without opening the edit mode; `:rm` removes a directory or request. The safety limit of `:rm` becomes the `workspace` (only inside it, never a symlink: a link is refused, there is no "unlist" anymore). `:h` help and documentation updated; `:d` (duplicate and edit) stays as it is.
- [x] TR3.6 (R11) Remove the dead code: the `.req` entry helpers (TR.9) and their tests, plus adjustments to the tests that dealt with the mapping; `DEVELOPMENT.md` (items 6 and 7 of the points to validate).
- [x] TR3.7 Review 3 verification: integrated flow through the main loop, demonstration in a real terminal (pty) and final review of the README and `DEVELOPMENT.md` (the `workspace` variable documented).

## Critical files (to be created)
`bin/req`, `lib/{core,ui,store,http,nav,cmd,wizard,env,home,log}.sh` (`home.sh`: `~/.req`, projects, configuration and cursor), `tests/*`, `README.md`, `TASKS.md`.

## Verification
Each phase ends with its tests passing and a manual demonstration: Phase 2 fires a real request and shows timings; Phase 3 navigates with arrows/Enter/Esc; Phase 4 creates, edits and duplicates requests generated on disk; Review 1 shows the `:h` help, sends a POST with JSON edited in vim and renames, copies and removes directories checking the `.req`; Review 3 initializes a `.req` with `workspace`, lists the root dynamically and operates on directories and requests at the root; Review 2 registers a project in `~/.req`, changes a setting with `:config` and reopens `req` in the same place; Phase 5 switches environment with `:env` and resolves secrets; Phase 6 produces log and verbose with `>>`/`<<`; Phase 7 runs directly in the debian, centos and rhel environments, without docker.
