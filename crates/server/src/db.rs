//! The thread event log in Postgres.

use orphusbot_proto::ThreadEvent;
use sqlx::PgPool;
use sqlx::types::Json;

/// M0 has a single thread for its single bot.
pub const THREAD: i64 = 1;

/// Appends a persisted event and returns its sequence number.
///
/// The `update … returning` takes a row lock on the thread, so concurrent
/// appends get consecutive numbers with no gaps.
pub async fn append(db: &PgPool, event: &ThreadEvent) -> sqlx::Result<i64> {
    let mut tx = db.begin().await?;
    let seq = sqlx::query_scalar!(
        "update thread set last_seq = last_seq + 1 where id = $1 returning last_seq",
        THREAD
    )
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query!(
        "insert into event (thread_id, seq, body) values ($1, $2, $3)",
        THREAD,
        seq,
        Json(event) as _
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(seq)
}

/// Every persisted event after `after`, oldest first.
pub async fn since(db: &PgPool, after: i64) -> sqlx::Result<Vec<(i64, ThreadEvent)>> {
    let rows = sqlx::query!(
        r#"select seq, body as "body: Json<ThreadEvent>" from event
           where thread_id = $1 and seq > $2 order by seq"#,
        THREAD,
        after
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(|r| (r.seq, r.body.0)).collect())
}

/// Closes dialogs left open by an earlier server process: their engines are gone.
pub async fn expire_open_dialogs(db: &PgPool) -> sqlx::Result<u64> {
    let open = sqlx::query_scalar!(
        r#"select o.body -> 'dialog' ->> 'id' as "id!" from event o
           where o.thread_id = $1 and o.body ->> 'type' = 'dialog_opened'
             and not exists (select 1 from event c
                             where c.thread_id = o.thread_id and c.body ->> 'type' = 'dialog_closed'
                               and c.body ->> 'id' = o.body -> 'dialog' ->> 'id')"#,
        THREAD
    )
    .fetch_all(db)
    .await?;
    let count = open.len() as u64;
    for id in open {
        let outcome = "Expired: the server restarted".to_owned();
        append(db, &ThreadEvent::DialogClosed { id, outcome }).await?;
    }
    Ok(count)
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
        let mut seqs = Vec::new();
        for t in ["a", "b", "c"] {
            seqs.push(append(&db, &msg(t)).await.unwrap());
        }
        assert_eq!(seqs, [1, 2, 3]);
        let replay = since(&db, 1).await.unwrap();
        assert_eq!(replay, vec![(2, msg("b")), (3, msg("c"))]);
    }
}
