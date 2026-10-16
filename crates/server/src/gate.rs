//! The approval gate: may this tool call run? (DESIGN §7.4, PRD B-DEC-06/07)
//!
//! M1 has no System 1 yet, so the order is: read-only tools run; the effect
//! ledger blocks repeats of calls that already completed in an earlier
//! attempt; the owner's rules decide; everything else asks the owner.

use orphusbot_proto::Attempt;
use serde_json::Value;
use sqlx::PgPool;
use sqlx::types::Json;

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
}

pub async fn decide(db: &PgPool, call: &Call<'_>) -> sqlx::Result<Verdict> {
    if READ_ONLY.contains(&call.tool) {
        return Ok(Verdict::Allow);
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
        crate::runs::submit(db, "work").await.unwrap();
        let first = crate::runs::claim(db, "laptop").await.unwrap().unwrap();
        crate::runs::release(db, Some("laptop")).await.unwrap();
        let second = crate::runs::claim(db, "laptop").await.unwrap().unwrap();
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
        }
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
}
