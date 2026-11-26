# Changelog

All notable changes to Dilated are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Direct builds now ask on the second launch whether to check for updates automatically, so new releases can reach you. Nothing is checked until you say yes.

## [1.0.1] - 2026-11-24

### Added

- A Focus filter for automation rules, so a rule can require a Focus mode.
- Leaving mode. `dilated leaving [--cancel]` and the menu let the Mac sleep once
  existing holds finish.

### Fixed

- A closed-lid arm request is now cancelled when you stop or resume automation while
  closed-lid setup is still in progress, so it can't arm after the fact.
- The Homebrew cask now reports the latest GitHub release as the current version
  instead of the Mac App Store build tag.
- Closed-lid mode offers Restore Normal Sleep when a live session can't revert sleep.
- Closed-lid setup only treats the pmset sudo rule as ready when it runs without a
  password and the effective and stored sleep values agree.
- Helper and CLI process waits no longer hang when Foundation misses an exit.

### Security

- Published release assets are signed with keyless cosign and ship with build
  provenance and an SPDX SBOM.

## [1.0.0] - 2026-11-21

First stable release. It includes everything from the 1.0.0 betas plus the fixes below.

### Added

- A Control Center toggle for keeping your Mac awake.
- Cookieless page analytics on the website that honor Do Not Track and Global Privacy
  Control.

### Fixed

- Closed-lid mode in the Mac App Store build no longer arms without its repair agent
  installed, and removing the companion setup during a live session no longer leaves sleep
  disabled.
- Closed-lid mode restores normal sleep when enabling fails after the power setting was
  applied, leaves sleep state set by other apps alone, and no longer runs power commands
  repeatedly when closed-lid was never set up.
- A pending sleep request no longer force-sleeps your Mac later, and another app disabling
  sleep no longer blocks quitting or updating Dilated.
- Triggers stopped by Low Power Mode or the battery floor restart when conditions clear,
  and "Resume when you return" resumes automation after trigger holds.
- `dilated run` stays awake across sleep and supervises its child process.
- The control socket lives in a per-user temporary directory and checks the connecting
  peer, so another local account can't block Dilated from launching.
- Trigger rules are kept when an older settings projection is missing, and downgrades
  preserve your data.

[Unreleased]: https://github.com/CodesWhat/dilated/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/CodesWhat/dilated/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/CodesWhat/dilated/releases/tag/v1.0.0
