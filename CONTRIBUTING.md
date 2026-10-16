# Contributing to OrphusBot

Thanks for helping. This file is the rulebook for humans; [AGENTS.md](AGENTS.md) holds the same rules in the form AI agents and reviewers use. If the two ever disagree, this file wins and the other gets fixed in the same PR.

## The workflow

1. **Open or pick an issue** for anything bigger than a typo, so the approach can be agreed before code is written.
2. **Branch from `main`.** Name it `<type>/<short-topic>`, for example `feat/node-link` or `docs/duplex-habitat`.
3. **Make the change, with its docs, tests and changelog entry** (see below).
4. **Open a pull request** using the template. Keep it to one concern. Draft PRs are welcome for early feedback.
5. **Review.** [CodeRabbit](https://coderabbit.ai) reviews every PR automatically; address or answer each comment. The maintainer reviews and merges.
6. **Squash-merge.** The PR title becomes the commit message, so write it as one (see [Commits](#commits)).

`main` is protected: changes land only through pull requests with passing checks.

## Documentation is part of the change

This is the rule CI and CodeRabbit both enforce:

| If your PR… | …it must also update |
|---|---|
| changes behaviour, an interface, a config option, a protocol or a data shape | the relevant section of [docs/DESIGN.md](docs/DESIGN.md), and [docs/PRD.md](docs/PRD.md) if a requirement changes |
| adds or changes how someone installs, runs or uses OrphusBot | [README.md](README.md) and any affected guide under `docs/` |
| makes a decision with alternatives (a library, a protocol, a trade-off) | [docs/DECISIONS.md](docs/DECISIONS.md), one new entry |
| changes anything a user or operator would notice | [CHANGELOG.md](CHANGELOG.md), under **Unreleased** |
| changes the wearable wire format | the wire table in all three places and the contract test (DESIGN §9.6) |

The `docs` check fails when a PR changes code but no documentation, or has no changelog entry. If a PR genuinely needs neither (a pure refactor with no visible effect, CI tweaks), add the `no-docs` label and say why in the PR description.

Docs are written in plain English: short sentences, one idea per paragraph, terms defined on first use, tables for comparisons. Keep requirement IDs (`B-…`) and section numbers stable; when you renumber, fix every reference.

## Ponytail: how we write code

We follow the [ponytail](https://github.com/DietrichGebert/ponytail) method. Before writing code, stop at the first rung that holds:

1. **Does this need to exist at all?** If the need is speculative, don't build it; say so in the PR.
2. **Is it already in this codebase?** Reuse the helper, type or pattern that's already here.
3. **Does the standard library do it?** Use it.
4. **Does the platform already do it?** Postgres constraints over application checks, systemd over a hand-rolled supervisor, NetBird over our own tunnel, CSS over JavaScript.
5. **Does a dependency we already have do it?** Use it. Don't add a crate for what a few lines can do.
6. **Can it be one line?** Make it one line.
7. **Only then** write the minimum code that works.

Rules that follow from it:

- No abstraction without a second real use. No trait with one implementation **unless** the design calls for a test fake or a second backend (for example `ComputerProvider`, `DecisionModel`); those are listed in DESIGN.md.
- No scaffolding "for later". Later can scaffold for itself.
- Delete before you add. Boring beats clever.
- Fix bugs at the root, where every caller goes through, not only on the path the issue names.
- When you knowingly cut a corner that has a ceiling, mark it: `// ponytail: global lock; per-run locks if throughput matters`.
- Non-trivial logic (a branch, a loop, a parser, anything touching security, money or data loss) leaves at least one test that fails if the logic breaks.

**Never cut:** input validation at trust boundaries, error handling that prevents data loss, security measures, accessibility, or anything the issue explicitly asks for. Never skip understanding the problem: read the code the change touches and trace the real flow first, then be lazy about the solution.

## Rust practices

These apply to every crate. CI (`.github/workflows/rust.yml`) runs fmt, Clippy, the tests against Postgres, and `cargo deny`. Local setup is in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

- **Toolchain:** stable, pinned in `rust-toolchain.toml`. Edition 2024.
- **Formatting and lints:** `cargo fmt --check` and `cargo clippy --all-targets --all-features -- -D warnings` must pass.
- **Tests:** `cargo test --workspace`. Database tests use Testcontainers Postgres. Every external system is reached through a trait with a fake in `crates/testkit`.
- **Dependencies:** `cargo deny check` (licences, advisories, duplicates). Prefer MIT or Apache-2.0. Justify every new dependency in the PR.
- **Errors:** `thiserror` in libraries, `anyhow` only in binaries. No `unwrap()` or `expect()` outside tests, except for invariants that can't fail, which carry a comment saying why.
- **Unsafe:** `#![forbid(unsafe_code)]` in every crate unless the PR explains why not.
- **Async:** Tokio. No blocking calls on async threads; use `spawn_blocking`.
- **SQL:** sqlx with compile-time checked queries and migrations in the repo. Constraints in the database, not only in code.
- **Logging:** `tracing`, structured fields, never secrets or tokens. Redact at the source.
- **Public items** get a one-line doc comment that says what it is for, not how it works.

Non-Rust parts (the TypeScript Orphus bridge extension, Playwright tests, any Python tooling) follow their own ecosystem's formatter and linter, configured in the repo when they arrive.

The wearable in `wearable/` keeps its own toolchains: Zephyr / nRF Connect SDK for the firmware and Flutter (pinned with fvm) for the app. See [wearable/README.md](wearable/README.md), [wearable/docs/TOOLCHAIN.md](wearable/docs/TOOLCHAIN.md) and [wearable/docs/APP.md](wearable/docs/APP.md). Its docs follow the same rule: change the code, change the doc that describes it.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, imperative mood, under 72 characters.

Types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`. Scopes follow the crate or area: `server`, `node`, `decide`, `device`, `capture`, `ui`, `bridge`, `docs`, `wearable`.

AI-assisted commits keep their `Co-Authored-By` line.

## Security and privacy

- Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
- **Never commit personal data**: decision receipts, labels, transcripts, captures, or any model fine-tuned on them. Never commit secrets, keys or `.env` files.
- Anything that touches tokens, sandboxes, the approval gate, the capture gate or the wearable's consent light gets a test and a note in the PR description.

## Licence

By contributing you agree that your contribution is licensed under the [MIT licence](LICENSE).
