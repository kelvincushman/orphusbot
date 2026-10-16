# Security policy

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an acknowledgement within 7 days and a plan or fix after that.

## Scope

OrphusBot is at the design stage, so reports about the design are welcome too. Areas that matter most:

- model subscription tokens leaving a node, or reaching a bot computer, E2B or the server database;
- the approval gate letting an irreversible action through without a rule or a human;
- escape from a bot's container, or a bot reaching the owner's LAN or NetBird peers;
- the wearable capture gate admitting audio outside a button window or allowed hands-free mode;
- personal data (receipts, transcripts, captures) leaking into logs, events or the repository.

## Supported versions

Only `main` until the first release.
