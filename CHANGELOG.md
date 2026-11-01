# Changelog

All notable changes to this project are documented in this file.

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
### Added
- Added .ai-instructions and ai/local/index.md from cs-template standard
### Fixed
- Fixed docker-compose.yml trailing blank line
- Fixed conf.yml comment formatting
### Changed
- Changed watchtower to use WATCHTOWER_SCHEDULE (default 0 24 * * * *, overridable via .env) with WATCHTOWER_CLEANUP enabled, replacing WATCHTOWER_POLL_INTERVAL; added example .env
### Deprecated
### Removed
### Deployment Changes

<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->

## [0.0.0] - Project created
