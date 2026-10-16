//! Placement: which node runs the bot's next run (DESIGN §6.3, PRD B-CMP-07).
//!
//! Deterministic rules, no System 1 yet. In order:
//! 1. the node that already holds the bot's computer, if it may work;
//! 2. else the least busy node that may work;
//! 3. else wait, and say why.
//!
//! A node may work unless it's on battery or in its quiet hours. E2B overflow
//! (M4) and GPU-only work (M3, when tasks can ask for a GPU) slot in later.

/// What placement knows about a connected node, from its heartbeat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub name: String,
    /// Load as a percentage of its CPUs.
    pub load: u32,
    pub on_battery: bool,
    pub quiet: bool,
}

impl Candidate {
    /// Why it may not take work, if it may not.
    pub fn held_back(&self) -> Option<&'static str> {
        if self.on_battery {
            Some("low on battery")
        } else if self.quiet {
            Some("in its quiet hours")
        } else {
            None
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Placement {
    /// Run on `node`; `why` names the rule that chose it.
    Run { node: String, why: &'static str },
    /// Nothing may take it now.
    Wait { why: String },
}

/// `home`: the node holding the bot's computer, if it has one.
pub fn choose(nodes: &[Candidate], home: Option<&str>) -> Placement {
    let ready = || nodes.iter().filter(|n| n.held_back().is_none());
    if let Some(home) = ready().find(|n| Some(n.name.as_str()) == home) {
        return Placement::Run {
            node: home.name.clone(),
            why: "where its computer is",
        };
    }
    // Ties go to the first name, so the choice doesn't flap.
    if let Some(best) = ready().min_by(|a, b| a.load.cmp(&b.load).then(a.name.cmp(&b.name))) {
        return Placement::Run {
            node: best.name.clone(),
            why: "least busy machine",
        };
    }
    let why = if nodes.is_empty() {
        "no node is connected".to_owned()
    } else {
        let parts: Vec<String> = nodes
            .iter()
            .filter_map(|n| n.held_back().map(|r| format!("{} is {r}", n.name)))
            .collect();
        parts.join("; ")
    };
    Placement::Wait { why }
}

/// For a bot whose computer is in E2B: the engine is light, so any connected
/// node may host it, even one on battery or in its quiet hours.
pub fn choose_for_cloud(nodes: &[Candidate]) -> Placement {
    match nodes
        .iter()
        .min_by(|a, b| a.load.cmp(&b.load).then(a.name.cmp(&b.name)))
    {
        Some(n) => Placement::Run {
            node: n.name.clone(),
            why: "its computer is in E2B; least busy machine",
        },
        None => Placement::Wait {
            why: "no node is connected".to_owned(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(name: &str, load: u32, on_battery: bool, quiet: bool) -> Candidate {
        Candidate {
            name: name.into(),
            load,
            on_battery,
            quiet,
        }
    }

    fn run(node: &str, why: &'static str) -> Placement {
        Placement::Run {
            node: node.into(),
            why,
        }
    }

    #[test]
    fn home_wins_when_it_may_work() {
        let nodes = [
            node("gpu-box", 10, false, false),
            node("laptop", 90, false, false),
        ];
        assert_eq!(
            choose(&nodes, Some("laptop")),
            run("laptop", "where its computer is")
        );
    }

    #[test]
    fn otherwise_the_least_busy_ready_node() {
        let nodes = [
            node("laptop", 5, true, false),
            node("gpu-box", 60, false, false),
            node("desk", 20, false, false),
        ];
        // The home is on battery, so it falls through to the others.
        assert_eq!(
            choose(&nodes, Some("laptop")),
            run("desk", "least busy machine")
        );
        let tied = [node("b", 10, false, false), node("a", 10, false, false)];
        assert_eq!(choose(&tied, None), run("a", "least busy machine"));
    }

    #[test]
    fn a_cloud_computer_can_use_any_connected_node() {
        let nodes = [
            node("laptop", 5, true, false),
            node("desk", 50, false, true),
        ];
        assert_eq!(
            choose_for_cloud(&nodes),
            run("laptop", "its computer is in E2B; least busy machine")
        );
        assert!(matches!(choose_for_cloud(&[]), Placement::Wait { .. }));
    }

    #[test]
    fn waits_and_says_why() {
        assert_eq!(
            choose(&[], None),
            Placement::Wait {
                why: "no node is connected".into()
            }
        );
        let nodes = [
            node("laptop", 5, true, false),
            node("gpu-box", 5, false, true),
        ];
        assert_eq!(
            choose(&nodes, Some("laptop")),
            Placement::Wait {
                why: "laptop is low on battery; gpu-box is in its quiet hours".into()
            }
        );
    }
}
