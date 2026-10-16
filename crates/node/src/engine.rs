//! Translating one Orphus RPC output line into node-link frames.
//!
//! Orphus streams JSONL on stdout (orphus `docs/rpc.md`). The node only needs
//! four things from it: text deltas, finished assistant messages, a rejected
//! prompt, and the end of the run.

use orphusbot_proto::FromNode;
use serde_json::Value;

/// What a turn has seen so far: the error to report when it ends, if any.
#[derive(Debug, Default)]
pub struct TurnState {
    pub error: Option<String>,
}

/// Maps one stdout line to zero or more frames for `turn`.
/// Lines that aren't JSON, or events the node doesn't use, map to nothing.
pub fn map_line(line: &str, turn: i64, state: &mut TurnState) -> Vec<FromNode> {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    match v["type"].as_str() {
        Some("response") if v["command"] == "prompt" && v["success"] == false => {
            let error = v["error"].as_str().unwrap_or("Orphus rejected the prompt");
            vec![FromNode::TurnEnded {
                turn,
                error: Some(error.to_owned()),
            }]
        }
        Some("message_update") if v["assistantMessageEvent"]["type"] == "text_delta" => {
            match v["assistantMessageEvent"]["delta"].as_str() {
                Some(text) if !text.is_empty() => vec![FromNode::Delta {
                    turn,
                    text: text.to_owned(),
                }],
                _ => Vec::new(),
            }
        }
        Some("message_end") if v["message"]["role"] == "assistant" => {
            let msg = &v["message"];
            if matches!(msg["stopReason"].as_str(), Some("error" | "aborted")) {
                state.error = Some(
                    msg["errorMessage"]
                        .as_str()
                        .unwrap_or("The model stopped with an error")
                        .to_owned(),
                );
            }
            let text: String = msg["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|c| c["type"] == "text")
                .filter_map(|c| c["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
            if text.trim().is_empty() {
                Vec::new()
            } else {
                vec![FromNode::Reply { turn, text }]
            }
        }
        Some("agent_end") => vec![FromNode::TurnEnded {
            turn,
            error: state.error.take(),
        }],
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(lines: &[&str]) -> Vec<FromNode> {
        let mut state = TurnState::default();
        lines
            .iter()
            .flat_map(|l| map_line(l, 7, &mut state))
            .collect()
    }

    #[test]
    fn streams_deltas_then_reply_then_end() {
        let out = run(&[
            r#"{"type":"response","command":"prompt","success":true,"id":"turn-7"}"#,
            r#"{"type":"agent_start"}"#,
            r#"{"type":"message_update","message":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hel"}}"#,
            r#"{"type":"message_update","message":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"lo"}}"#,
            r#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hello"}],"stopReason":"stop"}}"#,
            r#"{"type":"agent_end","messages":[]}"#,
        ]);
        assert_eq!(
            out,
            vec![
                FromNode::Delta {
                    turn: 7,
                    text: "Hel".into()
                },
                FromNode::Delta {
                    turn: 7,
                    text: "lo".into()
                },
                FromNode::Reply {
                    turn: 7,
                    text: "Hello".into()
                },
                FromNode::TurnEnded {
                    turn: 7,
                    error: None
                },
            ]
        );
    }

    #[test]
    fn rejected_prompt_and_model_error_end_the_turn_with_a_reason() {
        let out =
            run(&[r#"{"type":"response","command":"prompt","success":false,"error":"no model"}"#]);
        assert_eq!(
            out,
            vec![FromNode::TurnEnded {
                turn: 7,
                error: Some("no model".into())
            }]
        );

        let out = run(&[
            r#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"rate limited"}}"#,
            r#"{"type":"agent_end","messages":[]}"#,
        ]);
        assert_eq!(
            out,
            vec![FromNode::TurnEnded {
                turn: 7,
                error: Some("rate limited".into())
            }]
        );
    }

    #[test]
    fn ignores_noise_and_user_messages() {
        let out = run(&[
            "not json",
            r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
            r#"{"type":"tool_execution_start","toolName":"bash"}"#,
        ]);
        assert!(out.is_empty());
    }
}
