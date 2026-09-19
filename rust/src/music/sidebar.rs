use super::scanner::scan_folder_recursive;
use super::types::FolderNode;
use super::utils::normalize_path;
use rusqlite::Connection;
use serde::Serialize;
use std::path::PathBuf;
use std::time::SystemTime;

#[derive(Serialize)]
pub struct SidebarFolder {
    pub path: String,
    pub name: String,
}

pub fn get_sidebar_folders(conn: &Connection) -> Result<Vec<SidebarFolder>, String> {
    let mut stmt = conn
        .prepare("SELECT path FROM sidebar_folders ORDER BY added_at DESC")
        .map_err(|e| e.to_string())?;

    let folders: Vec<SidebarFolder> = stmt
        .query_map([], |row| {
            let path: String = row.get(0)?;
            let name = std::path::Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.clone());
            Ok(SidebarFolder { path, name })
        })
        .map_err(|e| e.to_string())?
        .filter_map(|r| r.ok())
        .collect();

    Ok(folders)
}

pub fn add_sidebar_folder(conn: &Connection, path: String) -> Result<(), String> {
    let normalized = normalize_path(&path);
    conn.execute(
        "INSERT OR REPLACE INTO sidebar_folders (path, added_at) VALUES (?1, ?2)",
        [
            &normalized,
            &SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                .to_string(),
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn remove_sidebar_folder(conn: &Connection, path: String) -> Result<(), String> {
    let normalized = normalize_path(&path);
    conn.execute("DELETE FROM sidebar_folders WHERE path = ?1", [&normalized])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn get_sidebar_hierarchy(conn: &Connection) -> Result<Vec<FolderNode>, String> {
    let mut stmt = conn
        .prepare("SELECT path FROM sidebar_folders ORDER BY added_at DESC")
        .map_err(|e| e.to_string())?;
    let roots: Vec<String> = stmt
        .query_map([], |row| row.get(0))
        .map_err(|e| e.to_string())?
        .filter_map(|r| r.ok())
        .collect();

    let mut tree = Vec::new();

    for root in roots {
        let root_path = PathBuf::from(&root);
        if let Some(root_node) = scan_folder_recursive(root_path.clone(), 0, 1, conn) {
            tree.push(root_node);
        }
    }

    Ok(tree)
}