use std::io;
use std::thread;
use std::time::{Duration, Instant};

use crate::system;

pub fn is_running(pid: i32) -> bool {
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

pub fn terminate(pids: &[i32], grace: Duration) -> Vec<i32> {
    for &pid in pids {
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
    let deadline = Instant::now() + grace;
    let mut remaining: Vec<i32> = pids
        .iter()
        .copied()
        .filter(|&pid| is_running(pid))
        .collect();
    while !remaining.is_empty() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(100));
        remaining.retain(|&pid| is_running(pid));
    }
    for &pid in &remaining {
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    thread::sleep(Duration::from_millis(200));
    remaining.retain(|&pid| is_running(pid));
    remaining
}

pub fn claude_sessions() -> Vec<i32> {
    system::run("pgrep", &["-x", "claude"], Duration::from_secs(10), None)
        .stdout
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect()
}
