# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Make the `env/` folder and the `default` environment file of a project when `req` opens it, instead of
  leaving them for you to create by hand. A project you already had gets them the next time it is opened.
- Offer to create the environment when `:env <name>` names one that does not exist (`Create environment
  "<name>"? [Y/n]`), instead of telling you to create its file yourself. The new file is empty and private,
  and the message says where it is.
- Load the whole set of variables of an environment when you switch to it with `:env`, and report a broken
  file right then (with its path and line) instead of only when a request runs. The status line says how
  many variables were loaded.
- Choose the environment from a menu: `:env` with no name lists the environments of the project, with the
  one in use marked (up and down, Enter to switch, Esc to leave), instead of printing a line of text.

## [0.5.0] - 2026-11-18

### Added

- Follow the log of the project from another terminal with `req log` (`tail -n 200 -F` on its `req.log`),
  without looking for the file. If the log does not exist yet it waits for it. While the log is at its
  `log_request_limit` lines, `tail` prints the whole log again after each new line (see the README).
- Clear the screen with Ctrl-L: the results of the requests already made go away and the menu is drawn
  again at the top, with the same selection.
- Show the last response in full screen with `v` (on the list or on the details): JSON indented by `jq`,
  anything else as it came, in `$PAGER` or else `less`. Only the response of this session is kept, in
  memory; nothing is written to disk.

### Changed

- Download a smaller `release/req.sh`, about 30% lighter (139 KB down to 99 KB): the comments of the
  sources are left out of the single file. It runs exactly as before.

## [0.4.0] - 2026-11-16

### Added

- Warn with a persistent bar at the top of the screen, at every screen, when `req` runs as root, since the
  files you create or edit could end up owned by root and upset the owner and permissions of your project.
- Warn, in a bar at the top of the details and when the request runs in the menu, about a `url` that is not
  a usable address (whitespace, a scheme other than http or https, no host). The request is still sent.

### Changed

- Link `make install` to the built `release/req.sh` (it runs `make build` first) instead of to the sources,
  so the installed `req` is the same single file as the download. Run `make install` again to update it.
  `make uninstall` removes the link, including one made by an older `make install`.
- Show an incorrect command (an unknown command, nothing selected, a wrong usage, an invalid setting or
  environment) as an orange warning bar at the top of the screen, once, instead of a dim line under the
  menu. Confirmations stay under the menu.
- Show the warnings raised while the menu is open (a bad line in a settings file, a log that cannot be
  written) in that bar too, instead of printing them in the terminal. `req run` still prints them to stderr.
- Show the failure of a request run from the menu (a variable with no value, a file that cannot be read, a
  failure of curl) as a one-line warning at the top, instead of error text above the menu.
- Pin the first problem of an invalid request at the top of its details screen and list at most 10 of its
  problems, so a file with many problems no longer fills the terminal.

## [0.3.0] - 2026-11-16

### Added

- Install `req` with a single download: `release/req.sh` is the whole tool in one executable file, which
  `curl` can fetch straight into your `PATH` (see the README). `make build` generates it.

## [0.2.0] - 2026-11-16

### Added

- Run the lint and the tests automatically on every pull request with GitHub Actions, so contributors
  see a broken change before it is merged. `req` itself behaves as in 0.1.0.

## [0.1.0] - 2026-11-16

### Added

- Register, browse and fire HTTP requests from an interactive terminal menu, with requests kept as plain
  JSON files in your project folder.
- Run a single request without the menu with `req run <file>`, which shows the response and a timing
  profile (DNS, TCP, TLS, wait, download, total).
- Start a project with `req init`, or accept the offer when `req` opens a folder that has none.
- Create, edit, duplicate, copy, rename and remove requests and directories from the menu (`:n`, `:e`,
  `:d`, `:cp`, `:ed`, `:nd`, `:rm`), with the body opened in your editor.
- Use variables in requests with `${key}` placeholders, resolved from per-project environments and
  switched with `:env`.
- Tune behavior with project and global settings through `:config` (timing display, cursor restore,
  redirect limit, log size).
- Keep an optional log of requests and responses per project (`:log`), and show the data being sent
  with the verbose mode (`:v`).
- Show the installed version with `req --version`.

[unreleased]: https://github.com/rodrigoio/req/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/rodrigoio/req/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/rodrigoio/req/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/rodrigoio/req/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rodrigoio/req/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rodrigoio/req/tree/v0.1.0
