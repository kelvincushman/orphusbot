//! The wearable's wire constants and cue vocabulary (DESIGN §9.2, AGENTS rule 9).
//!
//! These mirror `wearable/server-contract/src/device/commands.ts` (the reference),
//! `wearable/firmware/devkit/src/agent_commands.h` and
//! `wearable/app/lib/wearable/command_codec.dart`. The contract test below reads
//! the firmware header and the app codec and fails if any value drifts; change
//! all of them together.
//!
//! The server queues commands as the JSON objects the phone app's command poll
//! already decodes (`{"kind": "led_color", "r": 0, …}`), and the app writes the
//! 4-byte packets to the wearable.

use serde_json::{Value, json};

pub const OP_LED_COLOR: u8 = 0x01;
pub const OP_LED_PATTERN: u8 = 0x02;
pub const OP_HAPTIC: u8 = 0x03;
pub const OP_STATUS_QUERY: u8 = 0x04;
/// 0x05 is NOTIFY, which the firmware composes itself; nothing here encodes it.
pub const OP_HABITAT: u8 = 0x06;

pub const PATTERN_OFF: u8 = 0x00;
pub const PATTERN_SOLID: u8 = 0x01;
pub const PATTERN_BREATHING: u8 = 0x02;
pub const PATTERN_PULSE: u8 = 0x03;
pub const PATTERN_BLINK: u8 = 0x04;
pub const PATTERN_FLASH: u8 = 0x05;
pub const PATTERN_FADE: u8 = 0x06;
pub const PATTERN_ALT_FLASH: u8 = 0x07;
pub const PATTERN_DOUBLE_BLINK: u8 = 0x08;
pub const HAPTIC_SINGLE: u8 = 0x10;
pub const HAPTIC_DOUBLE: u8 = 0x11;
pub const HAPTIC_TRIPLE: u8 = 0x12;
pub const HAPTIC_LONG: u8 = 0x13;

/// Habitat cue ids (byte 1 of an `OP_HABITAT` write); firmware owns each cue's look and feel.
pub const HABITAT_CUES: [(&str, u8); 12] = [
    ("capture_open", 0x01),
    ("note_filed", 0x02),
    ("discarded", 0x03),
    ("ack", 0x04),
    ("nop", 0x05),
    ("ble_searching", 0x06),
    ("ble_connected", 0x07),
    ("ble_idle", 0x08),
    ("budget_warn", 0x09),
    ("error", 0x0A),
    ("task_running", 0x0B),
    ("awaiting_input", 0x0C),
];

fn habitat(cue: &str) -> Value {
    json!({ "kind": "habitat", "cue": cue })
}

fn led(pattern: u8, duration_ms: u32, (r, g, b): (u8, u8, u8)) -> [Value; 2] {
    [
        json!({ "kind": "led_pattern", "pattern": pattern, "durationMs": duration_ms }),
        json!({ "kind": "led_color", "r": r, "g": g, "b": b }),
    ]
}

fn haptic(pattern: u8, duration_ms: u32) -> Value {
    json!({ "kind": "haptic", "pattern": pattern, "durationMs": duration_ms })
}

/// A named alert as the commands the app's poll returns, exactly as
/// `HABITAT_ALERTS` in commands.ts; empty for an unknown name.
pub fn alert(name: &str) -> Vec<Value> {
    match name {
        // The four task alerts stay LED+haptic triples: they work on shipped firmware.
        "task_queued" => {
            let mut c = led(PATTERN_PULSE, 1000, (0, 80, 200)).to_vec();
            c.push(haptic(HAPTIC_SINGLE, 120));
            c
        }
        "task_running" => led(PATTERN_BREATHING, 0, (0, 80, 200)).to_vec(),
        "task_done" => {
            let mut c = led(PATTERN_FLASH, 2000, (0, 200, 60)).to_vec();
            c.push(haptic(HAPTIC_DOUBLE, 300));
            c
        }
        "budget_warn" => led(PATTERN_BREATHING, 0, (220, 140, 0)).to_vec(),
        // These are recognised by the app (ALERT_PENDING), so they go as named cues.
        "awaiting_input" | "error" => vec![habitat(name)],
        _ if HABITAT_CUES.iter().any(|(n, _)| *n == name) => vec![habitat(name)],
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn read(path: &str) -> String {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../wearable/");
        std::fs::read_to_string(format!("{root}{path}")).unwrap()
    }

    /// `#define AGENT_<PREFIX>_<NAME> 0x..` lines, as (name, value).
    fn defines(header: &str, prefix: &str) -> BTreeMap<String, u8> {
        header
            .lines()
            .filter_map(|l| {
                let mut parts = l.split_whitespace();
                (parts.next()? == "#define").then_some(())?;
                let name = parts.next()?.strip_prefix(prefix)?.to_lowercase();
                let value = u8::from_str_radix(parts.next()?.strip_prefix("0x")?, 16).ok()?;
                Some((name, value))
            })
            .collect()
    }

    /// DESIGN §9.6: the cue table, ops and patterns match the firmware and the app.
    #[test]
    fn wire_constants_match_the_firmware_and_the_app() {
        let header = read("firmware/devkit/src/agent_commands.h");
        let ours: BTreeMap<String, u8> = HABITAT_CUES
            .iter()
            .map(|(n, v)| ((*n).to_owned(), *v))
            .collect();
        assert_eq!(
            defines(&header, "AGENT_CUE_"),
            ours,
            "habitat cues vs firmware"
        );

        let ops = defines(&header, "AGENT_OP_");
        for (name, ours) in [
            ("led_color", OP_LED_COLOR),
            ("led_pattern", OP_LED_PATTERN),
            ("haptic", OP_HAPTIC),
            ("status_query", OP_STATUS_QUERY),
            ("habitat", OP_HABITAT),
        ] {
            assert_eq!(ops.get(name), Some(&ours), "op {name}");
        }
        let patterns = defines(&header, "AGENT_PATTERN_");
        for (name, ours) in [
            ("off", PATTERN_OFF),
            ("solid", PATTERN_SOLID),
            ("breathing", PATTERN_BREATHING),
            ("pulse", PATTERN_PULSE),
            ("blink", PATTERN_BLINK),
            ("flash", PATTERN_FLASH),
            ("fade", PATTERN_FADE),
            ("alt_flash", PATTERN_ALT_FLASH),
            ("double_blink", PATTERN_DOUBLE_BLINK),
            ("haptic_single", HAPTIC_SINGLE),
            ("haptic_double", HAPTIC_DOUBLE),
            ("haptic_triple", HAPTIC_TRIPLE),
            ("haptic_long", HAPTIC_LONG),
        ] {
            assert_eq!(patterns.get(name), Some(&ours), "pattern {name}");
        }

        // The app's `'name': 0x..` cue map.
        let dart = read("app/lib/wearable/command_codec.dart");
        for (name, value) in HABITAT_CUES {
            let line = format!("'{name}': 0x{value:02X},");
            assert!(dart.contains(&line), "app codec is missing {line}");
        }
    }

    #[test]
    fn alerts_match_the_reference_table() {
        assert_eq!(
            alert("task_done"),
            vec![
                json!({ "kind": "led_pattern", "pattern": 5, "durationMs": 2000 }),
                json!({ "kind": "led_color", "r": 0, "g": 200, "b": 60 }),
                json!({ "kind": "haptic", "pattern": 17, "durationMs": 300 }),
            ]
        );
        assert_eq!(
            alert("awaiting_input"),
            vec![json!({ "kind": "habitat", "cue": "awaiting_input" })]
        );
        assert_eq!(
            alert("nop"),
            vec![json!({ "kind": "habitat", "cue": "nop" })]
        );
        assert!(alert("made_up").is_empty());
    }
}
