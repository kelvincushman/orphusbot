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

/// Low on battery: unplugged with less charge than `ORPHUSBOT_MIN_BATTERY`
/// percent (default 30; `101` never works unplugged). A desktop or server without
/// mains supplies never is; an unplugged laptop whose charge can't be read is.
pub fn on_battery() -> bool {
    let min = std::env::var("ORPHUSBOT_MIN_BATTERY")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok())
        .unwrap_or(30);
    let Ok(supplies) = fs::read_dir("/sys/class/power_supply") else {
        return false;
    };
    let read = |dir: &std::path::Path, file: &str| {
        fs::read_to_string(dir.join(file))
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    let (mut mains, mut charge) = (Vec::new(), None::<u32>);
    for p in supplies.flatten().map(|e| e.path()) {
        match read(&p, "type").as_str() {
            "Mains" => mains.push(read(&p, "online") == "1"),
            "Battery" => {
                if let Ok(c) = read(&p, "capacity").parse::<u32>() {
                    charge = Some(charge.map_or(c, |prev| prev.min(c)));
                }
            }
            _ => {}
        }
    }
    low_battery(&mains, charge, min)
}

fn low_battery(mains: &[bool], charge: Option<u32>, min: u32) -> bool {
    let unplugged = !mains.is_empty() && !mains.contains(&true);
    unplugged && charge.is_none_or(|c| c < min)
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
    fn works_unplugged_only_with_enough_charge() {
        assert!(!low_battery(&[true], Some(10), 30), "plugged in");
        assert!(!low_battery(&[false], Some(79), 30));
        assert!(low_battery(&[false], Some(29), 30));
        assert!(low_battery(&[false], None, 30), "unknown charge holds back");
        assert!(
            low_battery(&[false], Some(100), 101),
            "101: never unplugged"
        );
        assert!(!low_battery(&[], None, 30), "no mains supply: a server");
    }

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
