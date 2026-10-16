//! The thread event log in Postgres.

use orphusbot_proto::ThreadEvent;
use sqlx::PgPool;
use sqlx::types::Json;

/// A bot's thread. Every bot has exactly one (DESIGN §3.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thread {
    pub id: i64,
    /// The bot's slug.
    pub bot: String,
}

/// The thread of the bot with this slug.
pub async fn bot_thread(db: &PgPool, slug: &str) -> sqlx::Result<Option<Thread>> {
    let row = sqlx::query!(
        "select t.id, b.slug from thread t join bot b on b.id = t.bot_id where b.slug = $1",
        slug
    )
    .fetch_optional(db)
    .await?;
    Ok(row.map(|r| Thread {
        id: r.id,
        bot: r.slug,
    }))
}

/// The thread a run belongs to.
pub async fn run_thread(db: &PgPool, run: i64) -> sqlx::Result<Thread> {
    let r = sqlx::query!(
        "select t.id, b.slug from run r join thread t on t.id = r.thread_id
         join bot b on b.id = t.bot_id where r.id = $1",
        run
    )
    .fetch_one(db)
    .await?;
    Ok(Thread {
        id: r.id,
        bot: r.slug,
    })
}

/// Appends a persisted event to a thread and returns its event id, which
/// clients resume from. Within a thread, `seq` also counts up without gaps:
/// the `update … returning` takes a row lock on the thread.
pub async fn append(db: &PgPool, thread: i64, event: &ThreadEvent) -> sqlx::Result<i64> {
    let mut tx = db.begin().await?;
    let seq = sqlx::query_scalar!(
        "update thread set last_seq = last_seq + 1 where id = $1 returning last_seq",
        thread
    )
    .fetch_one(&mut *tx)
    .await?;
    let id = sqlx::query_scalar!(
        "insert into event (thread_id, seq, body) values ($1, $2, $3) returning id",
        thread,
        seq,
        Json(event) as _
    )
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(id)
}

/// Every persisted event after event id `after`, oldest first, with its bot.
pub async fn since(db: &PgPool, after: i64) -> sqlx::Result<Vec<(i64, String, ThreadEvent)>> {
    let rows = sqlx::query!(
        r#"select e.id, b.slug, e.body as "body: Json<ThreadEvent>" from event e
           join thread t on t.id = e.thread_id join bot b on b.id = t.bot_id
           where e.id > $1 order by e.id"#,
        after
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.slug, r.body.0)).collect())
}

/// Closes dialogs left open by an earlier server process: their engines are gone.
pub async fn expire_open_dialogs(db: &PgPool) -> sqlx::Result<u64> {
    let open = sqlx::query!(
        r#"select o.thread_id, o.body -> 'dialog' ->> 'id' as "id!" from event o
           where o.body ->> 'type' = 'dialog_opened'
             and not exists (select 1 from event c
                             where c.thread_id = o.thread_id and c.body ->> 'type' = 'dialog_closed'
                               and c.body ->> 'id' = o.body -> 'dialog' ->> 'id')"#
    )
    .fetch_all(db)
    .await?;
    let count = open.len() as u64;
    for row in open {
        let outcome = "Expired: the server restarted".to_owned();
        let event = ThreadEvent::DialogClosed {
            id: row.id,
            outcome,
        };
        append(db, row.thread_id, &event).await?;
    }
    Ok(count)
}

/// The node holding a bot's computer, if it has one yet.
pub async fn computer_home(db: &PgPool, bot: &str) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar!("select node from bot_computer where bot = $1", bot)
        .fetch_optional(db)
        .await
}

pub async fn set_computer_home(db: &PgPool, bot: &str, node: &str) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into bot_computer (bot, node) values ($1, $2)
         on conflict (bot) do update set node = excluded.node, updated_at = now()
         where bot_computer.node <> excluded.node",
        bot,
        node
    )
    .execute(db)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use orphusbot_proto::Role;

    #[sqlx::test]
    async fn sequence_is_gap_free_and_replayable(db: PgPool) {
        let msg = |t: &str| ThreadEvent::Message {
            role: Role::User,
            text: t.into(),
        };
        let inbox = bot_thread(&db, "inbox").await.unwrap().unwrap();
        let mut ids = Vec::new();
        for t in ["a", "b", "c"] {
            ids.push(append(&db, inbox.id, &msg(t)).await.unwrap());
        }
        assert!(ids.windows(2).all(|w| w[0] < w[1]));
        let seqs: Vec<i64> = sqlx::query_scalar!("select seq from event order by id")
            .fetch_all(&db)
            .await
            .unwrap();
        assert_eq!(seqs, [1, 2, 3]);
        let replay = since(&db, ids[0]).await.unwrap();
        let inbox_slug = || "inbox".to_owned();
        assert_eq!(
            replay,
            vec![
                (ids[1], inbox_slug(), msg("b")),
                (ids[2], inbox_slug(), msg("c"))
            ]
        );
    }
}
