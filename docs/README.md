# OrphusBot documentation

Start with the [project README](../README.md) for the overview. Then:

| Document | Read it when you want to know… |
|---|---|
| [PRD.md](PRD.md) | **what** OrphusBot must do and why: goals, requirements (`B-*` IDs), user journeys, milestones, open questions |
| [DESIGN.md](DESIGN.md) | **how** it is built: components, run loop, decision layer, computers and placement, the wearable's duplex habitat, ambient capture, data model, security, testing, deployment |
| [DEVELOPMENT.md](DEVELOPMENT.md) | how to build, run and test it, and what M0 leaves out |
| [DECISIONS.md](DECISIONS.md) | what has been decided, when, and what would reopen it |
| [../wearable/README.md](../wearable/README.md) | the wearable itself: hardware, firmware, companion app, device channel, button and habitat specs (its own `docs/` folder) |
| [research/rakazo-architecture.md](research/rakazo-architecture.md) | how Rakazo works and how each part maps onto OrphusBot (background, not normative) |

## Keeping these up to date

Docs change in the same pull request as the code they describe. See [CONTRIBUTING.md](../CONTRIBUTING.md#documentation-is-part-of-the-change) for which file to update for which kind of change. CI and CodeRabbit both check.

When a guide is needed (installing, running a node, pairing the wearable), it goes in this folder and gets a row in the table above.
