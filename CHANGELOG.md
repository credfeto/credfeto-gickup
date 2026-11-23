# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
- Host egress lockdown (`firewall/configure`, run by `update`): firewalld policies limit what the host and the containers may connect to (gickup: GitHub over SSH and HTTPS, gitlab.com), with CDN-fronted destinations kept in ipsets refreshed every 10 minutes. `gickup-firewall-sync.timer` re-applies it when the firewall config changes, and the daily `Repo: Update egress ranges` workflow refreshes the GitHub and Cloudflare ranges. Observation mode (log unmatched traffic, drop nothing) until `GICKUP_FIREWALL_ENFORCE=true`
### Added
- Added .ai-instructions and ai/local/index.md from cs-template standard
- Added investigation of replacing gickup with a PAT-based bare git clone/fetch script, recommending adoption pending host memory measurement
### Fixed
- `./update` now re-runs itself after `git pull`, so changes to the update script take effect on the same run instead of the next one
- Fixed docker-compose.yml trailing blank line
- Fixed conf.yml comment formatting
### Changed
- Changed watchtower to use WATCHTOWER_SCHEDULE (default 0 24 * * * *, overridable via .env) with WATCHTOWER_CLEANUP enabled, replacing WATCHTOWER_POLL_INTERVAL; added example .env
- The host egress firewall is now one nftables table (`inet gku_egress`) loaded atomically by `firewall/egress`, instead of firewalld policies and ipsets: the 10-minute refresh reloaded firewalld, and a firewalld killed mid-reload (by the OOM killer) left its block-everything table in place and cut the host off. `firewall/configure` removes the old policies and ipsets with one last reload
### Deprecated
### Removed
### Deployment Changes

<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->

## [0.0.0] - Project created