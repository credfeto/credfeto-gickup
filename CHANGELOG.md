# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
- Egress allow-list uses the reverse proxies' DMZ VLAN addresses (192.168.140.250/.251 and IPv6)
- Host egress lockdown via `firewall/configure`; observation mode until GICKUP_FIREWALL_ENFORCE=true
### Added
- Added .ai-instructions and ai/local/index.md from cs-template standard
- Added investigation of replacing gickup with a bare git clone/fetch script
### Fixed
- Fixed docker-compose.yml trailing blank line
- Fixed conf.yml comment formatting
- `./update` now re-runs itself after `git pull` so script changes apply on the same run
### Changed
- Replacing gickup with a git clone/fetch backup container published to ghcr.io (in progress)
- Watchtower uses WATCHTOWER_SCHEDULE (overridable via .env) with cleanup; added example .env
- Host egress firewall is now one atomically loaded nftables table (`inet gku_egress`)
### Deprecated
### Removed
### Deployment Changes

<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->

## [0.0.0] - Project created