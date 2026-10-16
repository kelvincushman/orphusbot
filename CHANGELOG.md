# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) once releases start.

Every pull request that changes something a user or operator would notice adds a line under **Unreleased**.

## [Unreleased]

### Changed

- `ORPHUSBOT_UI_TOKEN` is replaced by `ORPHUSBOT_SETUP_TOKEN`, which only works until the first passkey is added. New setting `ORPHUSBOT_ORIGIN` (default `http://localhost:7480`). Open the page at `localhost`, not `127.0.0.1`.

### Added

- **Passkey sign-in (M1.3):** sign in with a passkey instead of a shared token. On first run, the setup token signs you in for an hour so you can add a passkey; after that it stops working. Sessions last 30 days and only their hashes are stored. Removing a passkey signs out its sessions, and removing all of them turns the setup token back on. New guide for running the server over NetBird with HTTPS: [docs/DEPLOY.md](docs/DEPLOY.md). Nodes can connect over `wss://`.
- **Approvals and the effect ledger (M1.2):** every tool call the bot makes goes to OrphusBot first through the `orphusbot-bridge` Orphus extension, which the node loads automatically. Read-only tools run; anything else shows an approval card (Allow once, Always allow this tool, Deny) unless a rule already decides. A resumed run can't repeat a call that already completed: it gets the earlier result instead, and a call that may have run before it was interrupted is flagged for you. Questions a bot asks appear as cards you can answer.
- **Durable runs (M1.1):** each message becomes a run in Postgres. If the node drops or goes silent mid-run, the run goes back to the queue and resumes, with its context, when a node is available again; a late report from the interrupted attempt is ignored. A message sent while the bot is waiting joins its run, and one sent while it is working steers it. A **Stop** button cancels the run.
- **Milestone M0:** a Rust workspace with `orphusbot-proto`, `orphusbot-server` and `orphusbot-node`. A message sent from the browser is stored in Postgres, handed to an `orphus --mode rpc` engine on a node, and the reply streams back to every open browser over Server-Sent Events, resuming from the last event after a reconnect. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- Rust CI: formatting, Clippy with warnings as errors, tests against Postgres 18, and `cargo deny` for licences and advisories.
- The wearable (firmware, Flutter companion app, hardware, device-channel contract and docs) in `wearable/`, imported as a cleaned snapshot ([DECISIONS D-012](docs/DECISIONS.md)).
- `.gitleaksignore` listing the reviewed secret-scan false positives.
- Product requirements ([docs/PRD.md](docs/PRD.md)), design ([docs/DESIGN.md](docs/DESIGN.md)), decision log ([docs/DECISIONS.md](docs/DECISIONS.md)) and the Rakazo architecture study.
- Contribution rules: documentation-in-the-same-PR, the ponytail method and Rust practices ([CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md)).
- CodeRabbit review configuration and a CI check that pull requests update docs and the changelog.
