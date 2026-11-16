# Guidelines for working on `req`

It has three parts: the project context (what the project is), the
workflow (how work is run) and the style guide (how code, tests and docs are written).
Architecture and gotchas are in `DEVELOPMENT.md`; roadmap, decisions and open questions in `TASKS.md`.

## Project context

### What it is
- `req` is an interactive bash + curl tool to register, browse and fire HTTP requests stored as JSON files.
- It lives **outside** a development project: the project directory holds only `req` things. Using it
  at the root of a code repository is not a goal.
- Runtime dependencies: bash 4+, `curl`, `jq`. `shellcheck` is a development tool only.
- Target environments: debian, centos and rhel, tested directly in them (Python 3.6 on RHEL 8).
- **No docker**, nor any other container, for tests or operations. Other environments are tested
  directly in them, never simulated.
- `manifest` (the original spec) and `reviews` (usage findings) are the user's local files: git-ignored,
  never commit them.

### Documents
- `README.md`: user documentation.
- `DEVELOPMENT.md`: how the code is built now (architecture, gotchas, test setup). Not a history log.
- `TASKS.md`: roadmap, closed decisions, open questions and items waiting for validation with users.

## Workflow

### Tasks
- Work in small tasks; if a task is too big, split it. One task = one behavior, about 100 to 200 lines
  including tests, one commit. Helpers go in their own commit, before the feature that uses them.
- What is already implemented counts as done; do not re-validate it.
- Findings from usage validations become new tasks in `TASKS.md`; do not change behavior ad hoc.
- If more information is needed, write a note (question in `TASKS.md`) and ask later; keep going until
  blocked by a decision.

### Branches and commits
- One short branch per task: one or two words in slug-case plus a three-digit sequence number that never
  restarts (`log-request-001`, `log-response-002`; `git branch --list '*-[0-9][0-9][0-9]'` shows the
  last one). Each branch starts from the previous task's branch, the first one from `main`.
- Commit locally on the task's branch, with one line: a simple summary of the change. No extra info: no
  co-author or tool lines, no model version.
- Never push to `origin`, and never merge, rebase onto `main` or delete branches: merges into `main` are
  done by another process, through pull requests.

### Versioning
- Versions follow semantic versioning, `MAJOR.MINOR.PATCH`. The single source is `REQ_VERSION` in
  `lib/core.sh` (shown by `req --version`).
- Before every change, assess its semantic impact and bring it up, so we agree on how to version:
  - MAJOR: incompatible change to what users rely on (request file format, `.req` or `~/.req` layout,
    commands and keys, exit codes).
  - MINOR: new backwards-compatible feature.
  - PATCH: backwards-compatible fix. A change to docs, tests or internals with no behavior change may
    need no bump; say so explicitly.
- The decision (bump and new number, or no bump) goes in the task's notes, and the `REQ_VERSION` change
  is part of the same task, in its commit.

### Changelog
- `CHANGELOG.md` at the repository root follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
  and says it adheres to Semantic Versioning. It is written for the people who use `req`, not as a
  copy of `git log`.
- Every change with an effect for users gets an entry under `## [Unreleased]` (always at the top), in
  the same task and commit as the change. Internal refactors, tests and docs-only changes get none.
- Entries go under the types `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`, in that
  order, in English; empty types are omitted. One item says what changed and its effect, in a short
  sentence that starts with the effect; related commits become one item.
- A breaking change (MAJOR) is marked `**BREAKING:**` and says how to migrate.
- A release renames `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (ISO 8601), the same number as
  `REQ_VERSION`, and leaves a new empty `[Unreleased]` above it. Newest version first; never delete a
  version (a withdrawn one is marked `[YANKED]`).
- The footer keeps the comparison links, including `[unreleased]`, built on tags `vX.Y.Z`.

### Done criteria
- After each task run the tests (`make check`) and make sure none is frozen.

## Style guide

### Language and documents
- Everything is in English: code, comments, messages, tests, `README.md`, `DEVELOPMENT.md`, `TASKS.md`
  and this file. Only the chat with the user is in Portuguese.
- Every new command goes into the `:h` help and the README.
- Documents describe the current state. History belongs to `TASKS.md` and `git log`.

### Code
- Everything is a function, prefixed `req_`; `bin/req` stays a thin entrypoint, no loose procedural scripts.
- Functions return status codes; results travel in `REQ_*` globals (no subshell).
- Errors: `req_err "..."` (`req: error: ...` on stderr); warnings: `req_warn`; notices: plain `printf`.
  Messages about a file carry its **absolute path**.
- Names of requests, directories and environments are slugs (`^[a-z0-9]+(-[a-z0-9]+)*$`).
- Colors are decided once, when `ui.sh` is loaded (`REQ_COLORS`); never test `-t 1` per call.
- Menu: never print inside the menu loop without `req_screen_erase` first; lines that can wrap go through
  `req_screen_add_long`.
- jq 1.6: every call costs about 55 ms, so batch work into one call; `$label` is a reserved word.
- `make lint` (shellcheck 0.9.0, no `-x`) must stay clean: a global shared between modules carries
  `# shellcheck disable=SC2034` with the reason; jq programs are single-quoted (`SC2016` disabled).
- Keep it working on bash 4+ and on Python 3.6 (`tests/mock_server.py`).

### Tests
- Test names must be explicit that they are tests, mainly the ones that exist to catch a defect or an
  invalid input, and so must the fixtures made up for them (e.g. `invalid_retries_field`, not `retries`:
  a bare name reads like a real feature and breaks the test when someone adds it, as `timeout` did).
- Each task carries only the tests of its own behavior; integrated scenarios go in the verification task
  that ends a phase.
- Tests that depend on file permissions must not be fooled by root.
- Test mechanics (`REQ_INPUT_FD`, pty runs, mock server) are in `DEVELOPMENT.md`, section "Testing".
