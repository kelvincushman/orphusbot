//! The owner's phone and social accounts, through ContentSwarm on the node
//! (DESIGN §11.6, D-044). A bot's `phone` tool call is `{action, …}`. Each
//! bot has a `phone` setting: `none`, `draft` (read the accounts and queue
//! drafts for the owner) or `operate` (also look at and use the phone).
//!
//! The gate lets looking, queueing drafts and getting about the phone
//! through; anything that could publish or commit on the owner's behalf asks
//! the owner every time, and no "always" rule can wave it through (the
//! owner's choice: every post and reply is approved by hand).

use serde_json::Value;
use sqlx::PgPool;

#[derive(Debug, PartialEq, Eq)]
pub enum Kind {
    /// Only looks: the screen, the accounts, what an account remembers.
    Look,
    /// Queues a draft for the owner's approval, or notes something seen.
    Queue,
    /// Gets about the phone without committing anything: opening an app,
    /// typing into a field, scrolling, going back.
    Navigate,
    /// Could post, send, like, follow, delete or confirm something.
    Commit,
    /// Not a phone action.
    Refused,
}

/// Actions only a bot that may operate the phone gets.
pub const OPERATE: &[&str] = &["look", "screenshot", "open", "tap", "type", "key", "swipe"];

/// Keys that only move around. `ENTER` and `DPAD_CENTER` can submit a form.
const MOVING_KEYS: &[&str] = &[
    "BACK",
    "HOME",
    "TAB",
    "ESCAPE",
    "DPAD_UP",
    "DPAD_DOWN",
    "DPAD_LEFT",
    "DPAD_RIGHT",
    "PAGE_UP",
    "PAGE_DOWN",
    "DEL",
    "FORWARD_DEL",
];

/// A tap whose label has a word starting with one of these could commit
/// something, so it asks. Deliberately broad: a needless question is cheap.
const COMMIT_STEMS: &[&str] = &[
    "post",
    "send",
    "repl",
    "tweet",
    "retweet",
    "repost",
    "quote",
    "like",
    "unlike",
    "love",
    "react",
    "celebrat",
    "support",
    "insightful",
    "funny",
    "follow",
    "unfollow",
    "connect",
    "share",
    "publish",
    "comment",
    "submit",
    "upload",
    "delete",
    "remov",
    "block",
    "report",
    "mute",
    "accept",
    "messag",
    "invit",
    "endors",
    "vote",
    "buy",
    "pay",
    "purchas",
    "subscrib",
    "install",
    "allow",
    "confirm",
    "sign",
    "log",
    "bookmark",
    "pin",
    "done",
    "live",
];

/// Whether a label (text, description or resource id) could commit.
fn commits(label: &str) -> bool {
    label
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .any(|w| COMMIT_STEMS.iter().any(|s| w.starts_with(s)))
}

pub fn kind(input: &Value) -> Kind {
    let s = |k: &str| input[k].as_str().unwrap_or_default();
    match s("action") {
        "look" | "screenshot" | "accounts" | "context" => Kind::Look,
        "draft" | "remember" => Kind::Queue,
        "open" | "type" | "swipe" => Kind::Navigate,
        "key" if MOVING_KEYS.contains(&s("key").to_uppercase().as_str()) => Kind::Navigate,
        "key" => Kind::Commit,
        "tap" => {
            let labels = [s("text"), s("desc"), s("id")];
            // A tap by id alone has no visible label to judge, so it asks.
            if (s("text").is_empty() && s("desc").is_empty()) || labels.iter().any(|l| commits(l)) {
                Kind::Commit
            } else {
                Kind::Navigate
            }
        }
        _ => Kind::Refused,
    }
}

/// What the run's bot may do with the phone: none, draft or operate.
pub async fn mode(db: &PgPool, run: i64) -> sqlx::Result<String> {
    sqlx::query_scalar!(
        "select b.phone from run r join thread t on t.id = r.thread_id join bot b on b.id = t.bot_id where r.id = $1",
        run
    )
    .fetch_one(db)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn looking_and_getting_about_pass_and_committing_asks() {
        assert_eq!(kind(&json!({"action": "look"})), Kind::Look);
        assert_eq!(
            kind(&json!({"action": "context", "account": "a"})),
            Kind::Look
        );
        assert_eq!(kind(&json!({"action": "draft", "text": "hi"})), Kind::Queue);
        assert_eq!(kind(&json!({"action": "open", "app": "X"})), Kind::Navigate);
        assert_eq!(
            kind(&json!({"action": "type", "text": "Post it"})),
            Kind::Navigate
        );
        assert_eq!(
            kind(&json!({"action": "key", "key": "back"})),
            Kind::Navigate
        );
        assert_eq!(
            kind(&json!({"action": "key", "key": "ENTER"})),
            Kind::Commit
        );
        assert_eq!(
            kind(&json!({"action": "tap", "text": "Notifications"})),
            Kind::Navigate
        );
        assert_eq!(
            kind(&json!({"action": "tap", "desc": "Search and Explore"})),
            Kind::Navigate
        );
        for commit in [
            json!({"action": "tap", "text": "Post"}),
            json!({"action": "tap", "text": "POST ALL"}),
            json!({"action": "tap", "desc": "Like"}),
            json!({"action": "tap", "text": "Reply"}),
            json!({"action": "tap", "text": "Follow"}),
            json!({"action": "tap", "text": "Connect"}),
            json!({"action": "tap", "text": "Done"}),
            json!({"action": "tap", "text": "Open", "id": "com.twitter.android:id/button_tweet"}),
            // No visible label to judge.
            json!({"action": "tap", "id": "com.linkedin.android:id/xyz"}),
            json!({"action": "tap"}),
        ] {
            assert_eq!(kind(&commit), Kind::Commit, "{commit}");
        }
        assert_eq!(
            kind(&json!({"action": "shell", "cmd": "rm"})),
            Kind::Refused
        );
        assert_eq!(kind(&json!({})), Kind::Refused);
    }
}
