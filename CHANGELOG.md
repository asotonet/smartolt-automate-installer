# Changelog

All notable changes to the **installer** repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `scripts/upgrade.sh` — detect new versions on Docker Hub and offer to upgrade.
  - `scripts/upgrade.sh --check` — non-destructive check.
  - `scripts/upgrade.sh --apply` — update `.env`, pull, recreate containers.
  - `scripts/upgrade.sh <tag>` — upgrade to a specific version.
  - `scripts/upgrade.sh --pre` — include prereleases.
- `scripts/stack.sh upgrade` now delegates to `upgrade.sh --apply` when no
  extra args are passed, so `stack.sh upgrade` and `upgrade.sh` do the
  same thing.

## [0.2.1] — 2026-07-04

### Fixed
- `install.sh` could not run from `curl ... | bash`:
  - `BASH_SOURCE[0]` is unset when the script is piped from stdin
    (Bash treats stdin as the script body). Detect piped invocation
    and skip the file-based path resolution.
  - `ADMIN_PASSWORD` validation while-loop tripped `set -u` on the
    first iteration; pre-initialise it to an empty string.
  - `read` from stdin consumed the rest of the script body. When
    stdin is not a TTY, switch to reading from `/dev/tty`. The
    probe uses an actual `open()` because `[ -r /dev/tty ]` returns
    true in headless subshells where the open still fails.
  - The wizard depended on the repo being cloned first; it now
    fetches `.env.example`, `docker-compose.yml`,
    `configs/olts.example.yaml`, and `scripts/stack.sh` from
    `raw.githubusercontent.com` into a `mktemp` dir when invoked
    via `curl | bash`.

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