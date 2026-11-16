# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Warn with a persistent bar at the top of the screen, at every screen, when `req` runs as root, since the
  files you create or edit could end up owned by root and upset the owner and permissions of your project.

### Changed

- Show an incorrect command (an unknown command, nothing selected, a wrong usage, an invalid setting or
  environment) as an orange warning bar at the top of the screen, once, instead of a dim line under the
  menu. Confirmations stay under the menu.
- Show the warnings raised while the menu is open (a bad line in a settings file, a log that cannot be
  written) in that bar too, instead of printing them in the terminal. `req run` still prints them to stderr.
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

[unreleased]: https://github.com/rodrigoio/req/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/rodrigoio/req/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rodrigoio/req/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rodrigoio/req/tree/v0.1.0
