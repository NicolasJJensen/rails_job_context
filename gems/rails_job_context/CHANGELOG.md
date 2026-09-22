# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Support named CurrentAttributes classes with separate selections and one correlation owner.
- Publish GoodJob dashboard integration as the optional `rails_job_context-good_job` gem.
- Load the companion through its default entrypoint and configure it through `JobContext::Dashboard`.
- Remove legacy metadata and single-context configuration support before the first public release.

## [0.1.0] - 2026-09-21

### Added

- Initial release.
