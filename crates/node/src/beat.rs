//! The heartbeat: what placement needs to know about this machine (DESIGN §4.1, §6.3).

use std::fs;

/// One-minute load average as a percentage of the CPUs.
pub fn load() -> u32 {
    let one = fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
        .unwrap_or(0.0);
    let cpus = std::thread::available_parallelism().map_or(1, |n| n.get());
    (one * 100.0 / cpus as f64).round() as u32
}

/// On battery: the machine has mains power supplies and none of them is online.
/// A desktop or server without them never is.
pub fn on_battery() -> bool {
    let Ok(supplies) = fs::read_dir("/sys/class/power_supply") else {
        return false;
    };
    let read = |dir: &std::path::Path, file: &str| {
        fs::read_to_string(dir.join(file))
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    let mains: Vec<bool> = supplies
        .flatten()
        .map(|e| e.path())
        .filter(|p| read(p, "type") == "Mains")
        .map(|p| read(&p, "online") == "1")
        .collect();
    !mains.is_empty() && !mains.contains(&true)
}

/// `hours` is `START-END` in whole local hours, such as `22-7` (it may wrap past midnight).
pub fn quiet(hours: Option<&str>, now_hour: u32) -> bool {
    let Some((start, end)) = hours.and_then(|h| h.split_once('-')) else {
        return false;
    };
    let (Ok(start), Ok(end)) = (start.trim().parse::<u32>(), end.trim().parse::<u32>()) else {
        return false;
    };
    if start <= end {
        (start..end).contains(&now_hour)
    } else {
        now_hour >= start || now_hour < end
    }
}

/// The local hour, from `date` (std has no time zones).
pub async fn local_hour() -> u32 {
    let out = tokio::process::Command::new("date")
        .arg("+%H")
        .output()
        .await;
    out.ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .unwrap_or(12)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quiet_hours_wrap_past_midnight() {
        let night = Some("22-7");
        assert!(quiet(night, 23) && quiet(night, 0) && quiet(night, 6));
        assert!(!quiet(night, 7) && !quiet(night, 12) && !quiet(night, 21));
        assert!(quiet(Some("13-14"), 13) && !quiet(Some("13-14"), 14));
        assert!(!quiet(None, 3) && !quiet(Some("nonsense"), 3));
    }

    #[test]
    fn readings_are_sane() {
        assert!(load() < 10_000);
        let _ = on_battery();
    }
}
