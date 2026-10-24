use std::env;
use std::ffi::{CStr, OsStr};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Output {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

pub fn run<S: AsRef<OsStr>>(
    program: impl AsRef<OsStr>,
    args: &[S],
    timeout: Duration,
    dir: Option<&Path>,
) -> Output {
    let program = program.as_ref();
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = dir {
        command.current_dir(dir);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return Output {
                status: -1,
                stdout: String::new(),
                stderr: error.to_string(),
                timed_out: false,
            }
        }
    };

    let (sender, receiver) = mpsc::channel();
    for (index, stream) in [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .enumerate()
    {
        let sender = sender.clone();
        thread::spawn(move || {
            let mut data = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.read_to_end(&mut data);
            }
            let _ = sender.send((index, data));
        });
    }
    drop(sender);

    let mut outputs = [Vec::new(), Vec::new()];
    let mut pending = 2;
    let mut collect = |until: Instant, outputs: &mut [Vec<u8>; 2]| {
        while pending > 0 {
            match receiver.recv_timeout(until.saturating_duration_since(Instant::now())) {
                Ok((index, data)) => {
                    outputs[index] = data;
                    pending -= 1;
                }
                Err(_) => return false,
            }
        }
        true
    };

    let mut timed_out = false;
    if !collect(Instant::now() + timeout, &mut outputs) {
        timed_out = true;
        let pid = child.id() as i32;
        unsafe { libc::kill(pid, libc::SIGTERM) };
        if !collect(Instant::now() + Duration::from_secs(1), &mut outputs) {
            unsafe { libc::kill(pid, libc::SIGKILL) };
            collect(Instant::now() + Duration::from_secs(1), &mut outputs);
        }
    }
    let status = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
    let name = Path::new(program)
        .file_name()
        .unwrap_or(program)
        .to_string_lossy()
        .into_owned();
    Output {
        status: if timed_out { -2 } else { status },
        stdout: String::from_utf8_lossy(&outputs[0]).into_owned(),
        stderr: if timed_out {
            format!("{name} didn't respond within {} seconds", timeout.as_secs())
        } else {
            String::from_utf8_lossy(&outputs[1]).into_owned()
        },
        timed_out,
    }
}

pub fn home() -> PathBuf {
    if let Some(home) = env::var_os("HOME").filter(|h| !h.is_empty()) {
        return PathBuf::from(home);
    }
    password_entry(|entry| entry.pw_dir)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn user_name() -> String {
    password_entry(|entry| entry.pw_name)
        .or_else(|| env::var("USER").ok())
        .unwrap_or_default()
}

fn password_entry(field: impl Fn(&libc::passwd) -> *mut libc::c_char) -> Option<String> {
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() {
            return None;
        }
        let value = field(&*entry);
        if value.is_null() {
            return None;
        }
        Some(CStr::from_ptr(value).to_string_lossy().into_owned())
    }
}

pub fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}
