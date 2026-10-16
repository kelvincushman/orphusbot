# AGENTS.md

Instructions for AI coding agents and automated reviewers (Claude Code, CodeRabbit, others) working in this repository. Humans: see [CONTRIBUTING.md](CONTRIBUTING.md), which these rules summarise.

## Project in one paragraph

OrphusBot is a self-hosted bot service written mainly in Rust. A server on an always-on machine keeps tasks, runs, approvals and decision receipts in Postgres. A node daemon on each of the owner's machines runs `orphus --mode rpc` engines and one container per bot. A Laya decision model ("System 1") routes tasks and gates risky tool calls; Orphus agents ("System 2") do the work. A one-button wearable with an LED and a vibration motor (no speaker) talks to it in both directions. Read [docs/DESIGN.md](docs/DESIGN.md) before changing anything structural.

## Hard rules

1. **Update the docs in the same change.** Behaviour, interfaces, config, protocols or data shapes changed → update [docs/DESIGN.md](docs/DESIGN.md) (and [docs/PRD.md](docs/PRD.md) if a requirement changed). User-visible change → [CHANGELOG.md](CHANGELOG.md) under Unreleased. A decision between alternatives → a new entry in [docs/DECISIONS.md](docs/DECISIONS.md). Setup or usage changed → [README.md](README.md).
2. **Ponytail.** Before writing code: does it need to exist? Is it already here? Does std, the platform or an existing dependency do it? Can it be one line? Only then write the minimum. No speculative abstractions or scaffolding. Mark known corner cuts with `// ponytail: <ceiling>, <upgrade path>`.
3. **Never cut** input validation at trust boundaries, data-loss error handling, security measures, accessibility, or explicitly requested features.
4. **Subscription tokens never leave a node**, never enter a bot computer or E2B, and no `proto` type may carry one.
5. **System 1 never approves an irreversible action** (send, pay, delete outside the bot's computer, merge, publish). Only a user rule or a human tap can.
6. **The wearable has no speaker, by design.** Nothing may depend on audio output. Every signal to the wrist is a tracked habitat message; every ask has a defined tap and double-tap reply (DESIGN §9.3).
7. **The capture consent light is non-suppressible.** No change may dim, delay or remove it.
8. **No personal data or secrets in the repo**: receipts, labels, transcripts, captures, fine-tuned checkpoints, keys, `.env`.
9. **Wearable wire constants** live in `crates/device` and are mirrored in the firmware header and the Dart codec; change all three and the contract test together.

## Rust conventions

- `cargo fmt`, `cargo clippy -- -D warnings`, `cargo test --workspace`, `cargo deny check` must pass.
- `thiserror` in libraries, `anyhow` in binaries. No `unwrap`/`expect` outside tests without a comment proving the invariant.
- `#![forbid(unsafe_code)]` by default.
- sqlx compile-checked queries; constraints in the database.
- `tracing` for logs; never log secrets.
- Every external system sits behind a trait with a fake in `crates/testkit`.

## Reviewing (CodeRabbit and other reviewers)

Flag, in this order:

1. Bugs, data loss, security holes, token or personal-data leaks, and breaks of the hard rules above.
2. **Missing documentation updates** for the change (rule 1). Name the file and section that should change.
3. Over-engineering against ponytail: unused abstractions, new dependencies that existing code or std covers, scaffolding for later, duplicated helpers.
4. Missing tests for non-trivial logic.

Don't flag style the formatter or linter already enforces. Be specific and short; suggest the smaller alternative when you flag over-engineering.

## Where things are

| Path | What |
|---|---|
| `docs/PRD.md` | Requirements (`B-*` IDs), journeys, milestones, open questions |
| `docs/DESIGN.md` | How it's built; section numbers are referenced from code comments and PRs |
| `docs/DECISIONS.md` | Decision log |
| `docs/research/` | Background studies (not normative) |
| `crates/` | Rust crates (from milestone M0; layout in DESIGN §2) |
