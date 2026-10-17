//! The approval gate: may this tool call run? (DESIGN §7.4, PRD B-DEC-06/07)
//!
//! The order: read-only tools run; the effect ledger blocks repeats of calls
//! that already completed in an earlier attempt; the owner's rules decide;
//! System 1 may let a *reversible* call through (a file write or edit inside the
//! bot's computer); everything else asks the owner. System 1 is never asked
//! about anything else, so it can't approve an irreversible action.

use orphusbot_proto::Attempt;
use serde_json::Value;
use sqlx::PgPool;
use sqlx::types::Json;

use crate::system1::System1;

/// Tools that run without asking and aren't ledgered: they only read, or (like
/// `request_takeover`) only ask the owner something.
const READ_ONLY: &[&str] = &[
    "read",
    "ls",
    "find",
    "grep",
    "search",
    "glob",
    "request_takeover",
    // Only gives the owner a copy of a file (an artifact).
    "share_file",
    // Hands a teammate a ticket, or starts a discussion; everything the
    // teammates do is gated itself.
    "ask_bot",
    "discuss",
    // A fleet's blueprints, read only; and its rooms, where the bot's own
    // helpers talk to each other (DESIGN §11.2).
    "fleet",
    "roundtable",
    // The MCP gateway when it only searches or describes tools; a call that
    // names a tool arrives as `mcp:<tool>` (see `main.rs` `on_dialog`) and asks.
    "mcp",
];

#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Deny(String),
    /// Ask the owner. `uncertain`: an interrupted attempt may already have run it.
    Ask {
        uncertain: bool,
    },
}

/// One tool call waiting at the gate.
pub struct Call<'a> {
    pub attempt: Attempt,
    pub tool_call_id: &'a str,
    pub tool: &'a str,
    pub input: &'a Value,
    /// The call runs inside the bot's computer, not on the node itself.
    pub in_computer: bool,
    /// The node put the bridge where helper sessions load it, so a helper's
    /// calls come back through this gate (DESIGN §11.2).
    pub helpers_gated: bool,
}

/// Reversible by construction (DESIGN §7.4): file changes inside the bot's computer.
/// Bash isn't, since a command can reach the network and act outside it.
fn reversible(call: &Call<'_>) -> bool {
    call.in_computer && matches!(call.tool, "write" | "edit")
}

/// What System 1 sees: the task, the bot's remit and the call.
async fn gate_state(db: &PgPool, call: &Call<'_>) -> sqlx::Result<String> {
    let ctx = sqlx::query!(
        "select r.prompt, b.remit from run r join thread t on t.id = r.thread_id
         join bot b on b.id = t.bot_id where r.id = $1",
        call.attempt.run
    )
    .fetch_one(db)
    .await?;
    let task: String = ctx.prompt.chars().take(1_000).collect();
    Ok(serde_json::json!({
        "task": task, "bot_remit": ctx.remit, "tool": call.tool, "args": call.input,
    })
    .to_string())
}

/// Tools that start helper agents. A helper's calls only come back through this
/// gate when the node installed the bridge for helpers; a workflow's own
/// TypeScript never does (DECISIONS D-030). The bridge blocks these too; this is the second lock.
fn ungated_helper(call: &Call<'_>) -> bool {
    call.tool == "workflow" || (call.tool == "subagent" && !call.helpers_gated)
}

/// Orphus's `memory` tool (Dossier) when it only reads: asking it something, or
/// checking it works. Writing (`ingest`, `gardener`) asks, and Orphus lets only
/// the librarian role write at all (DESIGN §11.4).
fn memory_read(call: &Call<'_>) -> bool {
    call.tool == "memory" && matches!(call.input["action"].as_str(), Some("query" | "doctor"))
}

pub async fn decide(db: &PgPool, system1: &System1, call: &Call<'_>) -> sqlx::Result<Verdict> {
    if call.tool == "roundtable"
        && crate::discussions::posted_already(db, call.attempt.run, call.input).await
    {
        return Ok(Verdict::Deny(
            "You've already posted this round; leave the room and stop.".into(),
        ));
    }
    if READ_ONLY.contains(&call.tool) || memory_read(call) {
        return Ok(Verdict::Allow);
    }
    // Helpers must run inside the turn: once it ends, the server answers no more of
    // their calls, so a background helper would wait for ever (DESIGN §11.2).
    if call.tool == "subagent" && call.input["async"] != false {
        return Ok(Verdict::Deny(
            "Run helpers in the foreground: call subagent again with \"async\": false and wait for the result.".into(),
        ));
    }
    if ungated_helper(call) {
        return Ok(Verdict::Deny(format!(
            "{} starts helpers whose actions OrphusBot can't check, so it isn't allowed. Do the work yourself.",
            call.tool
        )));
    }

    // Did an earlier attempt of this run make the same call?
    let earlier = sqlx::query!(
        r#"select state::text as "state!", result from effect
           where run_id = $1 and fence < $2 and tool = $3 and input = $4
           order by id desc limit 1"#,
        call.attempt.run,
        call.attempt.fence,
        call.tool,
        Json(call.input) as _
    )
    .fetch_optional(db)
    .await?;
    match earlier.as_ref().map(|e| e.state.as_str()) {
        Some("completed") => {
            let result = earlier.and_then(|e| e.result).unwrap_or_default();
            record(db, call, "denied", Some("ledger")).await?;
            return Ok(Verdict::Deny(format!(
                "This exact call already ran in an interrupted attempt of this run, so it was not run again. Its result was:\n{result}"
            )));
        }
        Some("approved") => {
            record(db, call, "pending", None).await?;
            return Ok(Verdict::Ask { uncertain: true });
        }
        _ => {}
    }

    let rule = sqlx::query_scalar!(
        r#"select effect::text as "effect!" from approval_rule where tool = $1"#,
        call.tool
    )
    .fetch_optional(db)
    .await?;
    match rule.as_deref() {
        Some("allow") => {
            record(db, call, "approved", Some("rule")).await?;
            Ok(Verdict::Allow)
        }
        Some(_) => {
            record(db, call, "denied", Some("rule")).await?;
            Ok(Verdict::Deny(format!(
                "The owner's rules don't allow the {} tool.",
                call.tool
            )))
        }
        None => {
            if reversible(call) {
                let state = gate_state(db, call).await?;
                if system1
                    .pass(db, &state, call.attempt.run, call.tool_call_id)
                    .await
                {
                    record(db, call, "approved", Some("system1")).await?;
                    return Ok(Verdict::Allow);
                }
            }
            record(db, call, "pending", None).await?;
            Ok(Verdict::Ask { uncertain: false })
        }
    }
}

async fn record(
    db: &PgPool,
    call: &Call<'_>,
    state: &str,
    decided_by: Option<&str>,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into effect (run_id, fence, tool_call_id, tool, input, state, decided_by)
         values ($1, $2, $3, $4, $5, $6::text::effect_state, $7)
         on conflict (run_id, fence, tool_call_id) do nothing",
        call.attempt.run,
        call.attempt.fence,
        call.tool_call_id,
        call.tool,
        Json(call.input) as _,
        state,
        decided_by
    )
    .execute(db)
    .await?;
    Ok(())
}

/// The owner's answer to an approval card. `always` also adds an allow rule.
pub async fn owner_decides(
    db: &PgPool,
    attempt: Attempt,
    tool_call_id: &str,
    allow: bool,
    always: bool,
) -> sqlx::Result<()> {
    let mut tx = db.begin().await?;
    let tool = sqlx::query_scalar!(
        "update effect set state = $4::text::effect_state, decided_by = 'owner', updated_at = now()
         where run_id = $1 and fence = $2 and tool_call_id = $3 and state = 'pending'
         returning tool",
        attempt.run,
        attempt.fence,
        tool_call_id,
        if allow { "approved" } else { "denied" }
    )
    .fetch_optional(&mut *tx)
    .await?;
    if let (Some(tool), true) = (tool, allow && always) {
        sqlx::query!(
            "insert into approval_rule (tool, effect) values ($1, 'allow')
             on conflict (tool) do update set effect = 'allow'",
            tool
        )
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await
}

/// A tool call finished: completes its ledger row if it was approved.
pub async fn tool_done(
    db: &PgPool,
    attempt: Attempt,
    tool_call_id: &str,
    ok: bool,
    result: &str,
) -> sqlx::Result<()> {
    sqlx::query!(
        "update effect set state = $4::text::effect_state, result = $5, updated_at = now()
         where run_id = $1 and fence = $2 and tool_call_id = $3 and state = 'approved'",
        attempt.run,
        attempt.fence,
        tool_call_id,
        if ok { "completed" } else { "failed" },
        result
    )
    .execute(db)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    async fn run_with_attempts(db: &PgPool) -> (Attempt, Attempt) {
        let crate::runs::Submitted::Queued(run) =
            crate::runs::submit(db, 1, "work", Default::default())
                .await
                .unwrap()
        else {
            panic!("expected a new run")
        };
        let first = crate::runs::claim(db, run, "laptop")
            .await
            .unwrap()
            .unwrap();
        crate::runs::release(db, Some("laptop")).await.unwrap();
        let second = crate::runs::claim(db, run, "laptop")
            .await
            .unwrap()
            .unwrap();
        (
            Attempt {
                run: first.run,
                fence: first.fence,
            },
            Attempt {
                run: second.run,
                fence: second.fence,
            },
        )
    }

    fn call<'a>(attempt: Attempt, id: &'a str, tool: &'a str, input: &'a Value) -> Call<'a> {
        Call {
            attempt,
            tool_call_id: id,
            tool,
            input,
            in_computer: false,
            helpers_gated: false,
        }
    }

    async fn decide(db: &PgPool, call: &Call<'_>) -> sqlx::Result<Verdict> {
        super::decide(db, &System1::off(), call).await
    }

    #[sqlx::test]
    async fn reads_run_and_writes_ask_until_a_rule_allows(db: PgPool) {
        let (_, a) = run_with_attempts(&db).await;
        let input = json!({"path": "x"});
        assert_eq!(
            decide(&db, &call(a, "c1", "read", &input)).await.unwrap(),
            Verdict::Allow
        );
        assert_eq!(
            decide(&db, &call(a, "c2", "write", &input)).await.unwrap(),
            Verdict::Ask { uncertain: false }
        );
        owner_decides(&db, a, "c2", true, true).await.unwrap();
        assert_eq!(
            decide(&db, &call(a, "c3", "write", &input)).await.unwrap(),
            Verdict::Allow
        );
    }

    #[sqlx::test]
    async fn helpers_that_skip_the_gate_are_denied_even_with_a_rule(db: PgPool) {
        let (_, a) = run_with_attempts(&db).await;
        sqlx::query!("insert into approval_rule (tool, effect) values ('subagent', 'allow')")
            .execute(&db)
            .await
            .unwrap();
        let input = json!({"agent": "worker", "task": "x"});
        // Helpers that wouldn't come back through the gate: always refused.
        for tool in ["subagent", "workflow"] {
            assert!(matches!(
                decide(&db, &call(a, "h1", tool, &input)).await.unwrap(),
                Verdict::Deny(_)
            ));
        }
        // With the bridge installed for helpers, a subagent follows the rules like any call;
        // a workflow's own code still can't be gated.
        let foreground = json!({"agent": "worker", "task": "x", "async": false});
        let gated = |id, tool| Call {
            helpers_gated: true,
            ..call(a, id, tool, &foreground)
        };
        assert_eq!(
            decide(&db, &gated("h2", "subagent")).await.unwrap(),
            Verdict::Allow
        );
        // In the background it would outlive the turn and wait for ever: refused.
        let background = Call {
            helpers_gated: true,
            ..call(a, "h5", "subagent", &input)
        };
        assert!(matches!(
            decide(&db, &background).await.unwrap(),
            Verdict::Deny(why) if why.contains("async")
        ));
        assert!(matches!(
            decide(&db, &gated("h3", "workflow")).await.unwrap(),
            Verdict::Deny(_)
        ));
        // The fleet tool only reads blueprints.
        assert_eq!(
            decide(&db, &call(a, "h4", "fleet", &input)).await.unwrap(),
            Verdict::Allow
        );
        // Memory: asking it is a read; filing something in it is not.
        let ask = serde_json::json!({ "action": "query", "question": "what did we decide?" });
        assert_eq!(
            decide(&db, &call(a, "m1", "memory", &ask)).await.unwrap(),
            Verdict::Allow
        );
        let file = serde_json::json!({ "action": "ingest", "source": "raw/x.md" });
        assert_ne!(
            decide(&db, &call(a, "m2", "memory", &file)).await.unwrap(),
            Verdict::Allow
        );
    }

    #[sqlx::test]
    async fn mcp_searches_run_and_each_mcp_tool_is_ruled_on_its_own(db: PgPool) {
        let (_, a) = run_with_attempts(&db).await;
        let search = json!({"search": "mail"});
        assert_eq!(
            decide(&db, &call(a, "m1", "mcp", &search)).await.unwrap(),
            Verdict::Allow
        );
        let draft = json!({"tool": "pa_mail_draft_new", "args": "{}"});
        assert_eq!(
            decide(&db, &call(a, "m2", "mcp:pa_mail_draft_new", &draft))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: false }
        );
        // Always allowing one MCP tool doesn't allow another.
        owner_decides(&db, a, "m2", true, true).await.unwrap();
        assert_eq!(
            decide(&db, &call(a, "m3", "mcp:pa_mail_draft_new", &draft))
                .await
                .unwrap(),
            Verdict::Allow
        );
        let delete = json!({"tool": "pa_todo_delete", "args": "{}"});
        assert_eq!(
            decide(&db, &call(a, "m4", "mcp:pa_todo_delete", &delete))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: false }
        );
    }

    #[sqlx::test]
    async fn resumed_attempt_cannot_repeat_a_completed_call(db: PgPool) {
        let (first, second) = run_with_attempts(&db).await;
        let input = json!({"command": "send-invoice 42"});
        let bash = |a, id| call(a, id, "bash", &input);

        // First attempt: approved and completed, then the node dropped.
        decide(&db, &bash(first, "c1")).await.unwrap();
        owner_decides(&db, first, "c1", true, false).await.unwrap();
        tool_done(&db, first, "c1", true, "sent").await.unwrap();

        let Verdict::Deny(reason) = decide(&db, &bash(second, "c9")).await.unwrap() else {
            panic!("a completed call must not run twice")
        };
        assert!(reason.ends_with("sent"));
    }

    #[sqlx::test]
    async fn approved_but_unconfirmed_call_is_uncertain(db: PgPool) {
        let (first, second) = run_with_attempts(&db).await;
        let input = json!({"command": "deploy"});
        decide(&db, &call(first, "c1", "bash", &input))
            .await
            .unwrap();
        owner_decides(&db, first, "c1", true, false).await.unwrap();
        // No tool_done: the node dropped while it ran.
        assert_eq!(
            decide(&db, &call(second, "c2", "bash", &input))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: true }
        );
    }

    #[sqlx::test]
    async fn system1_may_pass_only_reversible_calls_in_the_computer(db: PgPool) {
        let (_, a) = run_with_attempts(&db).await;
        let laya = crate::system1::tests::fake_laya("verdict", "pass", 0.99).await;
        let input = json!({"path": "notes.txt"});
        let in_computer = |id, tool| Call {
            in_computer: true,
            ..call(a, id, tool, &input)
        };
        assert_eq!(
            super::decide(&db, &laya, &in_computer("c1", "write"))
                .await
                .unwrap(),
            Verdict::Allow
        );
        // Bash can act outside the computer, and host files aren't reversible: both ask.
        assert_eq!(
            super::decide(&db, &laya, &in_computer("c2", "bash"))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: false }
        );
        assert_eq!(
            super::decide(&db, &laya, &call(a, "c3", "write", &input))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: false }
        );
        let by: Vec<Option<String>> =
            sqlx::query_scalar!("select decided_by from effect order by id")
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(by, [Some("system1".to_owned()), None, None]);
        let receipts: i64 = sqlx::query_scalar!(
            r#"select count(*) as "n!" from decision where catalogue = 'gate'"#
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(receipts, 1, "only the reversible call was put to System 1");

        // Not confident enough: ask.
        let unsure = crate::system1::tests::fake_laya("verdict", "pass", 0.9).await;
        assert_eq!(
            super::decide(&db, &unsure, &in_computer("c4", "edit"))
                .await
                .unwrap(),
            Verdict::Ask { uncertain: false }
        );
    }
}
