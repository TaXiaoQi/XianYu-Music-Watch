
use rusqlite::Connection;
use std::fs;
use std::path::Path;

pub fn clear_all_app_data(conn: &mut Connection, data_dir: &Path) -> Result<(), String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    tx.execute_batch(
        "
        DELETE FROM play_history;
        DELETE FROM song_artists;
        DELETE FROM artists;
        DELETE FROM songs;
        DELETE FROM library_folders;
        DELETE FROM sidebar_folders;
        ",
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        .map_err(|e| e.to_string())?;

    let cover_dir = data_dir.join("covers");
    if cover_dir.exists() {
        fs::remove_dir_all(&cover_dir).map_err(|e| e.to_string())?;
    }

    let state_dir = data_dir.join("state");
    if state_dir.exists() {
        fs::remove_dir_all(&state_dir).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::schema::{configure_connection, ensure_base_schema};
    use rusqlite::Connection;

    #[test]
    fn clear_all_app_data_empties_tables() {
        let mut conn = Connection::open_in_memory().unwrap();
        configure_connection(&conn).unwrap();
        ensure_base_schema(&conn).unwrap();

        conn.execute("INSERT INTO artists (id, name) VALUES (1, 'Artist')", [])
            .unwrap();
        conn.execute("INSERT INTO songs (path, title, container, codec) VALUES ('/x.flac', 'T', 'flac', 'flac')", [])
            .unwrap();

        let data_dir = std::env::temp_dir();
        clear_all_app_data(&mut conn, &data_dir).unwrap();

        let artists: i64 = conn
            .query_row("SELECT COUNT(*) FROM artists", [], |r| r.get(0))
            .unwrap();
        let songs: i64 = conn
            .query_row("SELECT COUNT(*) FROM songs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(artists, 0);
        assert_eq!(songs, 0);
    }
}