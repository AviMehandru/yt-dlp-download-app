// Named option sets.
//
// A profile is a RunOptions with the URL removed. That is the whole design,
// and it is deliberate: profiles are NOT a second description of what this
// window can do. Every field the runner accepts is profileable the moment it
// exists, and a field added to RunOptions cannot be forgotten here, because
// there is no per-field list in this file to forget it from.
//
// What that costs is that an old profiles.json may not name a field a newer
// build added. RunOptions is #[serde(default)] throughout, so a missing field
// deserialises to the same value it has in a fresh install rather than
// failing the whole file -- one profile written before an option existed
// keeps working, and simply does not set that option.
//
// Stored beside settings.json in the state dir, NOT in the cache dir: losing
// a profile someone built up over months is losing real user data, which is
// the same reason history.json and queue.json live there.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::paths;
use crate::pipeline::RunOptions;

pub const MAX_NAME: usize = 60;
pub const MAX_PROFILES: usize = 100;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Profile {
    pub name: String,
    pub opts: RunOptions,
    /// Unix seconds, for "last saved" in the UI. Not used for ordering --
    /// profiles are kept in the order they were created so a dropdown does
    /// not reshuffle itself under the pointer.
    #[serde(default)]
    pub saved: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Store {
    /// The profile selected when the window last closed, restored at startup.
    /// None means "no profile", which is a real state: it is what the window
    /// is in before anything has been saved, and what Clear puts it back to.
    pub active: Option<String>,
    pub profiles: Vec<Profile>,
}

impl Store {
    fn position(&self, name: &str) -> Option<usize> {
        // Case-insensitive, so "Archival" and "archival" are one profile
        // rather than two indistinguishable rows in a dropdown.
        self.profiles
            .iter()
            .position(|p| p.name.eq_ignore_ascii_case(name))
    }

    pub fn get(&self, name: &str) -> Option<&Profile> {
        self.position(name).map(|i| &self.profiles[i])
    }
}

fn store_path() -> PathBuf {
    paths::state_dir().join("profiles.json")
}

pub fn load() -> Store {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Written through a temp file and renamed, unlike settings.json.
///
/// The difference matters: settings.json holds five values a user can retype
/// in a minute, while this file holds work built up over time. A truncated
/// write from a crash or a full disk would silently lose all of it, and the
/// rename is atomic on every platform this runs on.
fn save(store: &Store) -> Result<(), String> {
    let dir = paths::state_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let text = serde_json::to_string_pretty(store).map_err(|e| e.to_string())?;
    let tmp = dir.join("profiles.json.tmp");
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, store_path()).map_err(|e| e.to_string())
}

fn clean_name(name: &str) -> Result<String, String> {
    let n = name.trim();
    if n.is_empty() {
        return Err("A profile needs a name.".into());
    }
    if n.chars().count() > MAX_NAME {
        return Err(format!("Profile names are limited to {} characters.", MAX_NAME));
    }
    Ok(n.to_string())
}

/// Create or overwrite by name, and make it the active one.
///
/// The URL is dropped rather than stored empty-or-not at the caller's choice:
/// a profile that carried a URL would turn "select a profile" into "select a
/// profile and silently replace what I was about to download", which is the
/// one thing a preset must never do.
pub fn save_profile(store: &mut Store, name: &str, mut opts: RunOptions) -> Result<(), String> {
    let name = clean_name(name)?;
    opts.url = String::new();
    let saved = crate::pipeline::now_secs();
    match store.position(&name) {
        Some(i) => {
            store.profiles[i].opts = opts;
            store.profiles[i].saved = saved;
            // Keep the name as newly typed, so re-saving "Archival" over
            // "archival" fixes the capitalisation rather than ignoring it.
            store.profiles[i].name = name.clone();
        }
        None => {
            if store.profiles.len() >= MAX_PROFILES {
                return Err(format!(
                    "That would be more than {} profiles. Delete one first.",
                    MAX_PROFILES
                ));
            }
            store.profiles.push(Profile { name: name.clone(), opts, saved });
        }
    }
    store.active = Some(name);
    save(store)
}

pub fn delete_profile(store: &mut Store, name: &str) -> Result<(), String> {
    let Some(i) = store.position(name) else {
        return Err(format!("There is no profile called \"{}\".", name));
    };
    let removed = store.profiles.remove(i);
    if store
        .active
        .as_deref()
        .map(|a| a.eq_ignore_ascii_case(&removed.name))
        .unwrap_or(false)
    {
        store.active = None;
    }
    save(store)
}

pub fn rename_profile(store: &mut Store, from: &str, to: &str) -> Result<(), String> {
    let to = clean_name(to)?;
    let Some(i) = store.position(from) else {
        return Err(format!("There is no profile called \"{}\".", from));
    };
    if let Some(j) = store.position(&to) {
        if j != i {
            return Err(format!("There is already a profile called \"{}\".", to));
        }
    }
    let was_active = store
        .active
        .as_deref()
        .map(|a| a.eq_ignore_ascii_case(&store.profiles[i].name))
        .unwrap_or(false);
    store.profiles[i].name = to.clone();
    if was_active {
        store.active = Some(to);
    }
    save(store)
}

/// None clears the selection. A name that no longer exists is an error rather
/// than a silent no-op, because the only way to reach it is a stale window.
pub fn activate(store: &mut Store, name: Option<String>) -> Result<(), String> {
    match name {
        None => store.active = None,
        Some(n) => {
            let Some(p) = store.get(&n) else {
                return Err(format!("There is no profile called \"{}\".", n));
            };
            store.active = Some(p.name.clone());
        }
    }
    save(store)
}
