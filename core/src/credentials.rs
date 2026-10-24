use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use crate::error::{Error, Result};
use crate::json::write_atomic;
use crate::store::Paths;
use crate::system;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Slot {
    Live,
    Saved(String),
}

pub trait Credentials: Send + Sync {
    fn read(&self, slot: &Slot) -> Result<Option<String>>;
    fn write(&self, slot: &Slot, value: &str) -> Result<()>;
    fn delete(&self, slot: &Slot) -> Result<()>;

    fn read_many(&self, slots: &[Slot]) -> Vec<Option<String>> {
        thread::scope(|scope| {
            let reads: Vec<_> = slots
                .iter()
                .map(|slot| scope.spawn(move || self.read(slot).ok().flatten()))
                .collect();
            reads
                .into_iter()
                .map(|read| read.join().ok().flatten())
                .collect()
        })
    }
}

pub fn for_platform(paths: &Paths) -> Box<dyn Credentials> {
    let files = env::var("SWAPBOT_CREDENTIALS").is_ok_and(|v| v == "file");
    if cfg!(target_os = "macos") && !files {
        Box::new(Keychain::new(paths.service.clone()))
    } else {
        Box::new(CredentialFiles::new(
            paths.credentials_file.clone(),
            paths.profile_dir.clone(),
        ))
    }
}

pub struct Keychain {
    service: String,
    account: String,
}

impl Keychain {
    const TOOL: &'static str = "/usr/bin/security";
    const NOT_FOUND: i32 = 44;

    pub fn new(service: String) -> Self {
        Keychain {
            service,
            account: system::user_name(),
        }
    }

    fn service(&self, slot: &Slot) -> String {
        match slot {
            Slot::Live => self.service.clone(),
            Slot::Saved(name) => format!("{}:{name}", self.service),
        }
    }

    fn security(&self, args: &[&str]) -> system::Output {
        system::run(Self::TOOL, args, Duration::from_secs(10), None)
    }

    fn failure(action: &str, service: &str, output: &system::Output) -> Error {
        Error::Credentials(format!(
            "Keychain error: couldn't {action} {service}: {}",
            output.stderr.trim()
        ))
    }

    pub fn decode_hex(text: &str) -> Option<String> {
        if text.is_empty() || text.len() % 2 != 0 || !text.is_ascii() {
            return None;
        }
        let bytes = (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok())
            .collect::<Option<Vec<u8>>>()?;
        String::from_utf8(bytes).ok()
    }
}

impl Credentials for Keychain {
    fn read(&self, slot: &Slot) -> Result<Option<String>> {
        let service = self.service(slot);
        let output = self.security(&[
            "find-generic-password",
            "-s",
            &service,
            "-a",
            &self.account,
            "-w",
        ]);
        if output.status == Self::NOT_FOUND {
            return Ok(None);
        }
        if output.status != 0 {
            return Err(Self::failure("read", &service, &output));
        }
        let value = output.stdout.strip_suffix('\n').unwrap_or(&output.stdout);
        if !value.starts_with('{') {
            if let Some(decoded) = Self::decode_hex(value) {
                return Ok(Some(decoded));
            }
        }
        Ok(Some(value.to_string()))
    }

    fn write(&self, slot: &Slot, value: &str) -> Result<()> {
        let service = self.service(slot);
        let output = self.security(&[
            "add-generic-password",
            "-U",
            "-s",
            &service,
            "-a",
            &self.account,
            "-w",
            value,
        ]);
        if output.status != 0 {
            return Err(Self::failure("write", &service, &output));
        }
        if self.read(slot)?.as_deref() != Some(value) {
            return Err(Error::Credentials(format!(
                "Keychain error: wrote {service} but it didn't read back intact"
            )));
        }
        Ok(())
    }

    fn delete(&self, slot: &Slot) -> Result<()> {
        let service = self.service(slot);
        let output = self.security(&[
            "delete-generic-password",
            "-s",
            &service,
            "-a",
            &self.account,
        ]);
        if output.status != 0 && output.status != Self::NOT_FOUND {
            return Err(Self::failure("delete", &service, &output));
        }
        Ok(())
    }
}

pub struct CredentialFiles {
    live: PathBuf,
    dir: PathBuf,
}

impl CredentialFiles {
    pub fn new(live: PathBuf, dir: PathBuf) -> Self {
        CredentialFiles { live, dir }
    }

    pub fn path(&self, slot: &Slot) -> PathBuf {
        match slot {
            Slot::Live => self.live.clone(),
            Slot::Saved(name) => self.dir.join(format!("{name}.credentials.json")),
        }
    }

    fn failure(action: &str, path: &std::path::Path, error: io::Error) -> Error {
        Error::Credentials(format!("couldn't {action} {}: {error}", path.display()))
    }
}

impl Credentials for CredentialFiles {
    fn read(&self, slot: &Slot) -> Result<Option<String>> {
        let path = self.path(slot);
        match fs::read_to_string(&path) {
            Ok(text) => Ok(Some(text)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(Self::failure("read", &path, error)),
        }
    }

    fn write(&self, slot: &Slot, value: &str) -> Result<()> {
        let path = self.path(slot);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| Self::failure("write", &path, e))?;
        }
        write_atomic(&path, value.as_bytes(), Some(0o600))
            .map_err(|e| Self::failure("write", &path, e))
    }

    fn delete(&self, slot: &Slot) -> Result<()> {
        let path = self.path(slot);
        match fs::remove_file(&path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => {
                Err(Self::failure("delete", &path, error))
            }
            _ => Ok(()),
        }
    }
}
