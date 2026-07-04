# Changelog

All notable changes to the **installer** repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-07-04

### Added
- Initial public release.
- `scripts/install.sh` — interactive wizard (7 steps) with prerequisites, admin credentials, SmartOLT connection, scheduler window, optional HTTPS, and one-shot deploy + healthcheck.
- `scripts/stack.sh` — `pull`, `up`, `down`, `restart`, `status`, `logs`, `ps`, `upgrade`, `config` subcommands.
- `docker-compose.yml` — 5-service template pulling prebuilt images from `asoton/smartolt-automate{-frontend,-proxy,-certbot}` on Docker Hub.
- `.env.example` — full environment variable reference.
- `configs/olts.example.yaml` — sample OLT list for first-time setup.
- MIT license.
- README with quick start, configuration, architecture, and troubleshooting.