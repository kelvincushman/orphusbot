//! Run state in Postgres: queueing, leasing, fencing and finishing.
//!
//! Every function is a single statement or a short transaction, so the
//! database's constraints and row locks decide races, not the server's memory.

use sqlx::PgPool;

/// How long a lease lasts without renewal. The server renews every 30 s.
pub const LEASE_SECS: i32 = 120;
/// Attempts before a run that keeps losing its node is failed.
pub const MAX_ATTEMPTS: i32 = 3;

/// What happened to a new message.
#[derive(Debug, PartialEq, Eq)]
pub enum Submitted {
    /// A new run was queued.
    Queued(i64),
    /// The text was added to the run that is already waiting.
    Joined(i64),
    /// A run is working; the caller should steer it with this text.
    Steer { run: i64, fence: i64 },
}

/// What started a run, kept on it from the moment it's created.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Source {
    pub routine: Option<i64>,
    pub ticket: Option<i64>,
}

/// Queues the message as a run, or attaches it to the thread's active run.
pub async fn submit(
    db: &PgPool,
    thread: i64,
    text: &str,
    source: Source,
) -> sqlx::Result<Submitted> {
    let mut tx = db.begin().await?;
    // Lock the thread row so two submits can't both see "no active run".
    sqlx::query!("select id from thread where id = $1 for update", thread)
        .fetch_one(&mut *tx)
        .await?;
    let active = sqlx::query!(
        r#"select id, fence, status::text as "status!" from run
           where thread_id = $1 and status in ('queued', 'running')"#,
        thread
    )
    .fetch_optional(&mut *tx)
    .await?;
    let out = match active {
        Some(r) if r.status == "running" => Submitted::Steer {
            run: r.id,
            fence: r.fence,
        },
        Some(r) => {
            sqlx::query!(
                "update run set prompt = prompt || E'\\n\\n' || $2, updated_at = now() where id = $1",
                r.id,
                text
            )
            .execute(&mut *tx)
            .await?;
            Submitted::Joined(r.id)
        }
        None => {
            let id = sqlx::query_scalar!(
                "insert into run (thread_id, prompt, routine_id, ticket_id) values ($1, $2, $3, $4)
                 returning id",
                thread,
                text,
                source.routine,
                source.ticket
            )
            .fetch_one(&mut *tx)
            .await?;
            Submitted::Queued(id)
        }
    };
    tx.commit().await?;
    Ok(out)
}

/// A run handed to a node.
#[derive(Debug, PartialEq, Eq)]
pub struct Claimed {
    pub run: i64,
    pub fence: i64,
    pub prompt: String,
    /// True when an earlier attempt was interrupted.
    pub resumed: bool,
}

/// The thread has a queued or running run.
pub async fn busy(db: &PgPool, thread: i64) -> sqlx::Result<bool> {
    sqlx::query_scalar!(
        r#"select exists (select 1 from run where thread_id = $1 and status in ('queued', 'running')) as "busy!""#,
        thread
    )
    .fetch_one(db)
    .await
}

/// A queued run and the bot it's for.
#[derive(Debug, PartialEq, Eq)]
pub struct Queued {
    pub run: i64,
    pub bot: String,
}

/// Every queued run, oldest first.
pub async fn queued(db: &PgPool) -> sqlx::Result<Vec<Queued>> {
    let rows = sqlx::query!(
        "select r.id, b.slug from run r join thread t on t.id = r.thread_id
         join bot b on b.id = t.bot_id
         where r.status = 'queued' order by r.created_at, r.id"
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| Queued {
            run: r.id,
            bot: r.slug,
        })
        .collect())
}

/// Leases queued run `run` to `node`, bumping its fence. `None` if it's no
/// longer queued (another dispatch took it, or it was cancelled).
pub async fn claim(db: &PgPool, run: i64, node: &str) -> sqlx::Result<Option<Claimed>> {
    let row = sqlx::query!(
        r#"update run set status = 'running', fence = fence + 1, node = $2, attempts = attempts + 1,
                  lease_expires_at = now() + make_interval(secs => $3), updated_at = now()
           where id = $1 and status = 'queued'
           returning id, fence, prompt, attempts"#,
        run,
        node,
        f64::from(LEASE_SECS)
    )
    .fetch_optional(db)
    .await?;
    Ok(row.map(|r| Claimed {
        run: r.id,
        fence: r.fence,
        prompt: r.prompt,
        resumed: r.attempts > 1,
    }))
}

/// Extends the leases of every run `node` holds.
pub async fn renew(db: &PgPool, node: &str) -> sqlx::Result<u64> {
    let done = sqlx::query!(
        "update run set lease_expires_at = now() + make_interval(secs => $2)
         where status = 'running' and node = $1",
        node,
        f64::from(LEASE_SECS)
    )
    .execute(db)
    .await?;
    Ok(done.rows_affected())
}

/// How a node's attempt ended. Cancelling has its own path (`cancel_active`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Completed,
    Failed,
}

/// Finishes the run if `fence` is still current. Returns false when a newer
/// attempt owns the run or it already ended, so the caller does nothing.
pub async fn finish(
    db: &PgPool,
    run: i64,
    fence: i64,
    outcome: Outcome,
    error: Option<&str>,
) -> sqlx::Result<bool> {
    let status = match outcome {
        Outcome::Completed => "completed",
        Outcome::Failed => "failed",
    };
    let done = sqlx::query!(
        "update run set status = $3::text::run_status, error = $4, node = null,
                lease_expires_at = null, updated_at = now()
         where id = $1 and fence = $2 and status = 'running'",
        run,
        fence,
        status,
        error
    )
    .execute(db)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// Cancels the thread's active run, whatever state it is in.
/// Returns the run and the fence it had, so a running node can be told to stop.
pub async fn cancel_active(db: &PgPool, thread: i64) -> sqlx::Result<Option<(i64, i64)>> {
    let row = sqlx::query!(
        "update run set status = 'cancelled', node = null, lease_expires_at = null, updated_at = now()
         where thread_id = $1 and status in ('queued', 'running')
         returning id, fence",
        thread
    )
    .fetch_optional(db)
    .await?;
    Ok(row.map(|r| (r.id, r.fence)))
}

/// A run that went back to the queue, or gave up.
#[derive(Debug, PartialEq, Eq)]
pub struct Released {
    pub run: i64,
    pub failed: bool,
}

/// Puts runs back in the queue: those held by `node` (it disconnected), or,
/// with `node = None`, those whose lease has lapsed. Runs out of attempts fail.
pub async fn release(db: &PgPool, node: Option<&str>) -> sqlx::Result<Vec<Released>> {
    let rows = sqlx::query!(
        r#"update run set
              status = case when attempts >= $2 then 'failed'::run_status else 'queued'::run_status end,
              error = case when attempts >= $2 then 'The bot lost its node too many times' else error end,
              node = null, lease_expires_at = null, updated_at = now()
           where status = 'running'
             and case when $1::text is null then lease_expires_at < now() else node = $1 end
           returning id, status::text as "status!""#,
        node,
        MAX_ATTEMPTS
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| Released {
            run: r.id,
            failed: r.status == "failed",
        })
        .collect())
}

/// On server start no node is connected, so every running run is orphaned.
// ponytail: assumes one server process; with several, rely on lease expiry instead.
pub async fn release_all(db: &PgPool) -> sqlx::Result<u64> {
    let done = sqlx::query!(
        "update run set status = 'queued', node = null, lease_expires_at = null, updated_at = now()
         where status = 'running'"
    )
    .execute(db)
    .await?;
    Ok(done.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The inbox bot's thread, made by the migrations.
    const INBOX: i64 = 1;

    async fn status(db: &PgPool, run: i64) -> String {
        sqlx::query_scalar!(r#"select status::text as "s!" from run where id = $1"#, run)
            .fetch_one(db)
            .await
            .unwrap()
    }

    #[sqlx::test]
    async fn second_message_joins_or_steers(db: PgPool) {
        let Submitted::Queued(run) = submit(&db, INBOX, "one", Source::default()).await.unwrap()
        else {
            panic!("expected a new run")
        };
        assert_eq!(
            submit(&db, INBOX, "two", Source::default()).await.unwrap(),
            Submitted::Joined(run)
        );
        assert_eq!(
            queued(&db).await.unwrap(),
            vec![Queued {
                run,
                bot: "inbox".into()
            }]
        );
        let c = claim(&db, run, "laptop").await.unwrap().unwrap();
        assert_eq!(c.prompt, "one\n\ntwo");
        assert!(!c.resumed);
        assert_eq!(
            submit(&db, INBOX, "three", Source::default())
                .await
                .unwrap(),
            Submitted::Steer {
                run,
                fence: c.fence
            }
        );
    }

    #[sqlx::test]
    async fn stale_fence_cannot_finish_and_requeue_bumps_the_fence(db: PgPool) {
        let Submitted::Queued(run) = submit(&db, INBOX, "work", Source::default()).await.unwrap()
        else {
            panic!("expected a new run")
        };
        let first = claim(&db, run, "laptop").await.unwrap().unwrap();
        assert!(
            claim(&db, run, "gpu").await.unwrap().is_none(),
            "already running"
        );

        // The laptop drops: the run goes back to the queue and the GPU box takes it.
        assert_eq!(
            release(&db, Some("laptop")).await.unwrap(),
            vec![Released {
                run: first.run,
                failed: false
            }]
        );
        let second = claim(&db, run, "gpu").await.unwrap().unwrap();
        assert_eq!(second.run, first.run);
        assert!(second.fence > first.fence);
        assert!(second.resumed);

        // A late "done" from the laptop's attempt is ignored; the GPU box's counts.
        assert!(
            !finish(&db, first.run, first.fence, Outcome::Completed, None)
                .await
                .unwrap()
        );
        assert_eq!(status(&db, first.run).await, "running");
        assert!(
            finish(&db, second.run, second.fence, Outcome::Completed, None)
                .await
                .unwrap()
        );
        assert_eq!(status(&db, first.run).await, "completed");
    }

    #[sqlx::test]
    async fn expired_leases_requeue_until_attempts_run_out(db: PgPool) {
        let Submitted::Queued(run) = submit(&db, INBOX, "work", Source::default()).await.unwrap()
        else {
            panic!("expected a new run")
        };
        for attempt in 1..=MAX_ATTEMPTS {
            let c = claim(&db, run, "laptop").await.unwrap().unwrap();
            sqlx::query!(
                "update run set lease_expires_at = now() - interval '1 second' where id = $1",
                c.run
            )
            .execute(&db)
            .await
            .unwrap();
            let released = release(&db, None).await.unwrap();
            assert_eq!(released.len(), 1);
            assert_eq!(released[0].failed, attempt == MAX_ATTEMPTS);
        }
        assert!(claim(&db, run, "laptop").await.unwrap().is_none());
    }

    #[sqlx::test]
    async fn renewing_keeps_a_lease_alive(db: PgPool) {
        let Submitted::Queued(run) = submit(&db, INBOX, "work", Source::default()).await.unwrap()
        else {
            panic!("expected a new run")
        };
        claim(&db, run, "laptop").await.unwrap().unwrap();
        assert_eq!(renew(&db, "laptop").await.unwrap(), 1);
        assert_eq!(renew(&db, "gpu").await.unwrap(), 0);
        assert!(
            release(&db, None).await.unwrap().is_empty(),
            "lease is fresh"
        );
    }
}
