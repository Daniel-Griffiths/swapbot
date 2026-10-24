use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

pub fn parse_object(raw: &str) -> Option<Object> {
    match serde_json::from_str(raw) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

pub fn object_at(object: &Object, key: &str) -> Option<Object> {
    match object.get(key) {
        Some(Value::Object(inner)) => Some(inner.clone()),
        _ => None,
    }
}

pub fn compact(object: &Object) -> String {
    serde_json::to_string(object).unwrap_or_default()
}

pub fn pretty<T: Serialize + ?Sized>(value: &T) -> io::Result<Vec<u8>> {
    serde_json::to_vec_pretty(value).map_err(io::Error::other)
}

pub fn read_object(path: &Path) -> io::Result<Option<Object>> {
    let text = fs::read_to_string(path)?;
    Ok(parse_object(&text))
}

pub fn write_atomic(path: &Path, data: &[u8], mode: Option<u32>) -> io::Result<()> {
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let dir = target
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let name = target
        .file_name()
        .ok_or_else(|| io::Error::other("no file name"))?;
    let temp: PathBuf = dir.join(format!(
        ".{}.{}.tmp",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));
    let mode = mode.or_else(|| {
        fs::metadata(&target)
            .ok()
            .map(|m| m.permissions().mode() & 0o7777)
    });
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode.unwrap_or(0o644))
            .open(&temp)?;
        if let Some(mode) = mode {
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        file.write_all(data)?;
        file.sync_all()?;
        fs::rename(&temp, &target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
