//! Google through the node's `gog` CLI (DESIGN §11.5). A bot's `google` tool
//! call is a gog command line; the gate lets look-ups through, refuses changes
//! from bots that may only read, and asks the owner about every change from a
//! bot that may write (the owner's choice: everyone reads, PA writes).

use serde_json::Value;
use sqlx::PgPool;

/// The services a bot may use; the node passes the same list to gog's
/// `--enable-commands`, so anything else (`auth`, `chat`, …) can't run.
pub const SERVICES: &[&str] = &[
    "gmail", "calendar", "tasks", "drive", "docs", "sheets", "contacts", "time",
];

/// Commands that only look things up, per service.
const LOOKUPS: &[(&str, &[&str])] = &[
    (
        "gmail",
        &[
            "search",
            "messages",
            "get",
            "attachment",
            "url",
            "history",
            "thread",
        ],
    ),
    (
        "calendar",
        &[
            "calendars",
            "events",
            "event",
            "freebusy",
            "conflicts",
            "search",
            "time",
            "users",
            "colors",
            "team",
        ],
    ),
    ("tasks", &["lists", "list", "get"]),
    (
        "drive",
        &[
            "ls",
            "search",
            "get",
            "download",
            "url",
            "drives",
            "permissions",
            "comments",
        ],
    ),
    ("docs", &["export", "info", "cat"]),
    ("sheets", &["get", "metadata", "export"]),
    ("contacts", &["search", "list", "get", "directory", "other"]),
];

/// Words that make a nested command a change, such as `tasks lists create`.
const CHANGES: &[&str] = &[
    "create", "add", "new", "update", "set", "edit", "delete", "remove", "rm", "clear", "insert",
    "patch", "move", "rename", "send", "share", "unshare", "reply", "post", "upload", "mkdir",
    "done", "undo",
];

#[derive(Debug, PartialEq, Eq)]
pub enum Kind {
    /// Only looks something up.
    Lookup,
    /// Creates, changes, sends or deletes something.
    Change,
    /// Not a service a bot may use, or not a command at all.
    Refused,
}

/// What a gog command line does. Unknown commands count as changes, so the
/// owner is asked rather than a guess letting them through.
pub fn kind(args: &[String]) -> Kind {
    let words: Vec<&str> = args
        .iter()
        .map(String::as_str)
        .filter(|a| !a.starts_with('-'))
        .collect();
    let Some(&service) = words.first() else {
        return Kind::Refused;
    };
    if !SERVICES.contains(&service) {
        return Kind::Refused;
    }
    if service == "time" {
        return Kind::Lookup;
    }
    let command = words.get(1).copied().unwrap_or_default();
    let looks = LOOKUPS
        .iter()
        .any(|(s, commands)| *s == service && commands.contains(&command));
    let nested_change = words.get(2).is_some_and(|w| CHANGES.contains(w));
    if looks && !nested_change {
        Kind::Lookup
    } else {
        Kind::Change
    }
}

/// The command line in a `google` tool call.
pub fn args(input: &Value) -> Vec<String> {
    input["args"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// What the run's bot may do in Google: none, read or write.
pub async fn mode(db: &PgPool, run: i64) -> sqlx::Result<String> {
    sqlx::query_scalar!(
        "select b.google from run r join thread t on t.id = r.thread_id join bot b on b.id = t.bot_id where r.id = $1",
        run
    )
    .fetch_one(db)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k(line: &str) -> Kind {
        kind(&line.split(' ').map(str::to_owned).collect::<Vec<_>>())
    }

    #[test]
    fn sorts_lookups_from_changes() {
        for lookup in [
            "calendar events --from today",
            "tasks list",
            "gmail search is:unread",
            "drive search budget",
            "docs cat abc123",
            "time",
            "--json calendar events",
        ] {
            assert_eq!(k(lookup), Kind::Lookup, "{lookup}");
        }
        for change in [
            "calendar create --title Dentist",
            "tasks add Buy milk",
            "gmail send --to x@example.com",
            "drive delete abc",
            "tasks lists create Shopping",
            "drive comments create abc",
            "gmail drafts create",
            "gmail labels",
        ] {
            assert_eq!(k(change), Kind::Change, "{change}");
        }
        for refused in ["auth add me@example.com", "chat spaces list", "", "--json"] {
            assert_eq!(k(refused), Kind::Refused, "{refused}");
        }
    }
}
