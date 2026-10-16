# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) once releases start.

Every pull request that changes something a user or operator would notice adds a line under **Unreleased**.

## [Unreleased]

### Added

- The wearable (firmware, Flutter companion app, hardware, device-channel contract and docs) in `wearable/`, imported as a cleaned snapshot ([DECISIONS D-012](docs/DECISIONS.md)).
- `.gitleaksignore` listing the reviewed secret-scan false positives.
- Product requirements ([docs/PRD.md](docs/PRD.md)), design ([docs/DESIGN.md](docs/DESIGN.md)), decision log ([docs/DECISIONS.md](docs/DECISIONS.md)) and the Rakazo architecture study.
- Contribution rules: documentation-in-the-same-PR, the ponytail method and Rust practices ([CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md)).
- CodeRabbit review configuration and a CI check that pull requests update docs and the changelog.
