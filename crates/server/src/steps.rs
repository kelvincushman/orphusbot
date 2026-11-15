//! Steps: every tool call that reaches the gate becomes a line in the thread
//! (DESIGN §12.6, D-067). The label is the server's own words. It carries at
//! most one name the server already holds, never the call's arguments.

use orphusbot_proto::{StepKind, ThreadEvent};
use serde_json::Value;

use crate::{App, bots, connections, db, lock, record};

/// The names a label may show.
#[derive(Default)]
pub struct Names {
    /// Enabled bots: (slug, name).
    pub bots: Vec<(String, String)>,
    /// The bot's own connections.
    pub connections: Vec<String>,
}

/// Google services by their `gws` name, and what we call them.
const GOOGLE: [(&str, &str); 7] = [
    ("gmail", "Gmail"),
    ("calendar", "Calendar"),
    ("tasks", "Tasks"),
    ("drive", "Drive"),
    ("docs", "Docs"),
    ("sheets", "Sheets"),
    ("people", "Contacts"),
];

/// What a tool call is called in the thread. `tool` is as the gate sees it,
/// so an MCP tool is `mcp:<name>`. Every name shown is copied from `names` or
/// the table above, matched against the input; the input's own text never is.
pub fn label(tool: &str, input: &Value, names: &Names) -> (String, StepKind) {
    let fixed = |text: &str, kind| (text.to_owned(), kind);
    if let Some(inner) = tool.strip_prefix("mcp:") {
        // Orphus names an MCP tool `<connection>_<tool>`; the longest match wins.
        let connection = names
            .connections
            .iter()
            .filter(|c| {
                inner
                    .strip_prefix(c.as_str())
                    .is_some_and(|rest| rest.starts_with('_'))
            })
            .max_by_key(|c| c.len());
        let label = connection.map_or("Using a connection".to_owned(), |c| format!("Using {c}"));
        return (label, StepKind::Other);
    }
    match tool {
        "bash" => fixed("Running a command", StepKind::Command),
        "read" => fixed("Reading a file", StepKind::Read),
        "write" | "edit" => fixed("Writing a file", StepKind::Write),
        "ask_bot" => {
            // Matched the way `team::ask` finds the teammate.
            let asked = input["bot"]
                .as_str()
                .unwrap_or_default()
                .trim()
                .to_lowercase();
            let name = names.bots.iter().find(|(slug, _)| *slug == asked);
            let who = name.map_or("a teammate", |(_, name)| name);
            (format!("Checking with {who}"), StepKind::Talk)
        }
        "google" => {
            let service = GOOGLE
                .iter()
                .find(|(arg, _)| input["args"][0].as_str() == Some(arg));
            let place = service.map_or("Google", |(_, name)| name);
            (format!("Looking in {place}"), StepKind::Google)
        }
        "media" => fixed("Making an image", StepKind::Media),
        "phone" => fixed("Using the phone", StepKind::Phone),
        // Orphus's web tools, which only run for a bot without a computer.
        "web_search" | "code_search" => fixed("Searching the web", StepKind::Search),
        "fetch_content" | "get_search_content" => fixed("Reading a web page", StepKind::Browse),
        _ => fixed("Working", StepKind::Other),
    }
}

/// A tool call reached the gate: put it in the thread.
pub async fn started(
    app: &App,
    thread: &db::Thread,
    run: i64,
    id: &str,
    tool: &str,
    input: &Value,
) {
    // A call asked about twice is still one step.
    if !lock(&app.rt).steps.insert((run, id.to_owned())) {
        return;
    }
    let mut names = Names::default();
    if tool == "ask_bot" {
        let all = bots::all(&app.db).await.unwrap_or_default();
        names.bots = all
            .into_iter()
            .filter(|b| !b.disabled)
            .map(|b| (b.slug, b.name))
            .collect();
    }
    if tool.starts_with("mcp:") {
        let mut by_bot = connections::names_by_bot(&app.db).await;
        names.connections = by_bot.remove(&thread.bot).unwrap_or_default();
    }
    let (label, kind) = label(tool, input, &names);
    let id = id.to_owned();
    let event = ThreadEvent::StepStarted {
        run,
        id,
        label,
        kind,
    };
    record(app, thread, event).await;
}

/// The call finished or was refused. Only an open step ends, and only once:
/// a refused call may also report a failed result.
pub async fn ended(app: &App, thread: &db::Thread, run: i64, id: &str, ok: bool) {
    if !lock(&app.rt).steps.remove(&(run, id.to_owned())) {
        return;
    }
    let id = id.to_owned();
    record(app, thread, ThreadEvent::StepEnded { run, id, ok }).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn names() -> Names {
        Names {
            bots: vec![("coder".into(), "Coder".into())],
            connections: vec!["pa".into(), "pa_mail".into(), "github".into()],
        }
    }

    #[test]
    fn each_tool_has_its_label_and_kind() {
        let n = names();
        let cases = [
            (
                "bash",
                json!({ "command": "ls" }),
                "Running a command",
                StepKind::Command,
            ),
            (
                "read",
                json!({ "path": "a.txt" }),
                "Reading a file",
                StepKind::Read,
            ),
            (
                "write",
                json!({ "path": "a.txt" }),
                "Writing a file",
                StepKind::Write,
            ),
            (
                "edit",
                json!({ "path": "a.txt" }),
                "Writing a file",
                StepKind::Write,
            ),
            (
                "ask_bot",
                json!({ "bot": " Coder ", "task": "x" }),
                "Checking with Coder",
                StepKind::Talk,
            ),
            (
                "ask_bot",
                json!({ "bot": "nobody" }),
                "Checking with a teammate",
                StepKind::Talk,
            ),
            (
                "ask_bot",
                json!({}),
                "Checking with a teammate",
                StepKind::Talk,
            ),
            (
                "google",
                json!({ "args": ["gmail", "users"] }),
                "Looking in Gmail",
                StepKind::Google,
            ),
            (
                "google",
                json!({ "args": ["people"] }),
                "Looking in Contacts",
                StepKind::Google,
            ),
            (
                "google",
                json!({ "args": ["schema", "x"] }),
                "Looking in Google",
                StepKind::Google,
            ),
            (
                "google",
                json!({ "args": "gmail" }),
                "Looking in Google",
                StepKind::Google,
            ),
            (
                "media",
                json!({ "prompt": "a cat" }),
                "Making an image",
                StepKind::Media,
            ),
            (
                "phone",
                json!({ "action": "look" }),
                "Using the phone",
                StepKind::Phone,
            ),
            (
                "mcp:github_search_code",
                json!({}),
                "Using github",
                StepKind::Other,
            ),
            (
                "mcp:pa_mail_send",
                json!({}),
                "Using pa_mail",
                StepKind::Other,
            ),
            ("mcp:pa_todo_delete", json!({}), "Using pa", StepKind::Other),
            (
                "mcp:pager_send",
                json!({}),
                "Using a connection",
                StepKind::Other,
            ),
            (
                "mcp:github",
                json!({}),
                "Using a connection",
                StepKind::Other,
            ),
            (
                "mcp",
                json!({ "search": "mail" }),
                "Working",
                StepKind::Other,
            ),
            (
                "web_search",
                json!({ "query": "x" }),
                "Searching the web",
                StepKind::Search,
            ),
            (
                "fetch_content",
                json!({ "url": "x" }),
                "Reading a web page",
                StepKind::Browse,
            ),
            (
                "share_file",
                json!({ "path": "a.txt" }),
                "Working",
                StepKind::Other,
            ),
            ("made_up", json!(null), "Working", StepKind::Other),
        ];
        for (tool, input, text, kind) in cases {
            assert_eq!(
                label(tool, &input, &n),
                (text.to_owned(), kind),
                "{tool} {input}"
            );
        }
    }

    /// Hard rule 8: whatever the bot puts in a call, none of it reaches the thread.
    #[test]
    fn a_label_never_carries_the_input() {
        const SECRET: &str = "token-abc123";
        let n = names();
        // The secret as every argument a tool takes, and as names that match nothing.
        let inputs = [
            json!({ "command": format!("curl https://example.com/{SECRET}"), "path": SECRET }),
            json!({ "bot": SECRET, "task": SECRET }),
            json!({ "bot": format!("coder {SECRET}"), "task": SECRET }),
            json!({ "args": [SECRET, SECRET] }),
            json!({ "args": ["gmail", SECRET, "--params", SECRET] }),
            json!({ "tool": SECRET, "server": SECRET, "url": SECRET, "prompt": SECRET }),
            json!(SECRET),
            json!([SECRET]),
        ];
        let tools = [
            "bash",
            "read",
            "write",
            "edit",
            "ask_bot",
            "google",
            "media",
            "phone",
            "mcp",
            "web_search",
            "fetch_content",
            "share_file",
            "unknown",
            SECRET,
        ];
        let mcp = [
            format!("mcp:{SECRET}"),
            format!("mcp:github_{SECRET}"),
            format!("mcp:{SECRET}_github"),
        ];
        // Everything a label may be made of.
        let allowed = [
            "Running a command",
            "Reading a file",
            "Writing a file",
            "Checking with Coder",
            "Checking with a teammate",
            "Looking in Gmail",
            "Looking in Google",
            "Making an image",
            "Using the phone",
            "Using github",
            "Using a connection",
            "Searching the web",
            "Reading a web page",
            "Working",
        ];
        for tool in tools.iter().copied().chain(mcp.iter().map(String::as_str)) {
            for input in &inputs {
                let (text, _) = label(tool, input, &n);
                assert!(!text.contains(SECRET), "{tool} {input}: {text}");
                assert!(allowed.contains(&text.as_str()), "{tool} {input}: {text}");
            }
        }
    }
}
