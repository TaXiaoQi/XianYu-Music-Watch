
use crate::music::lyrics::build_structured_lyrics_payload;
use crate::music::url_resolver::LxUrlSongInfo;

// =========================================================================
// 歌词解析（第三批）
// =========================================================================

pub fn parse_lyrics(raw_lyrics: String) -> String {
    serde_json::to_string(&build_structured_lyrics_payload(raw_lyrics))
        .unwrap_or_else(|_| "{}".to_string())
}

// =========================================================================
// 音乐源 URL 直链解析（第二批）
// =========================================================================

pub async fn lx_search(source: String, keyword: String, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::lx_search(&source, &keyword, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub async fn tx_search_albums(keyword: String, page: u32, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::tx_search_albums(&keyword, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub async fn tx_album_songs(album_mid: String, page: u32, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::tx_album_songs(&album_mid, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub async fn tx_batch_track_interval(song_ids_json: String) -> Result<String, String> {
    let song_ids: Vec<String> = serde_json::from_str(&song_ids_json).map_err(|e| e.to_string())?;
    let map = crate::music::lx_search::tx_batch_track_interval(&song_ids).await?;
    serde_json::to_string(&map).map_err(|e| e.to_string())
}

pub async fn lx_search_playlists(
    source: String,
    keyword: String,
    page: u32,
    limit: u32,
) -> Result<String, String> {
    let items =
        crate::music::lx_catalog::lx_search_playlists(&source, &keyword, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub async fn lx_playlist_tracks(
    source: String,
    playlist_id: String,
    page: u32,
    limit: u32,
) -> Result<String, String> {
    let result =
        crate::music::lx_catalog::lx_playlist_tracks(&source, &playlist_id, page, limit).await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn lx_album_songs(
    source: String,
    album_id: String,
    page: u32,
    limit: u32,
) -> Result<String, String> {
    let items = crate::music::lx_catalog::lx_album_songs(&source, &album_id, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

// =========================================================================
// 歌词在线抓取（第三批）
// =========================================================================

pub async fn fetch_lyric_from_source(
    source: String,
    song_info_json: String,
) -> Result<String, String> {
    let song_info: crate::music::lyric_fetcher::LyricSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let result = crate::music::lyric_fetcher::fetch_lyric_from_source(source, song_info).await?;
    match result {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

// =========================================================================
// WebDAV 云盘（第四批）
// =========================================================================

fn parse_remote_source(
    json: &str,
) -> Result<crate::remote::types::RemoteSourceCredentials, String> {
    serde_json::from_str(json).map_err(|e| format!("WebDAV 源 JSON 无效: {e}"))
}

pub async fn webdav_test_connection(source_json: String) -> Result<(), String> {
    let source = parse_remote_source(&source_json)?;
    crate::remote::webdav::test_connection(&source).await
}

pub async fn webdav_browse_directory(
    source_json: String,
    path: String,
) -> Result<String, String> {
    let source = parse_remote_source(&source_json)?;
    let entries = crate::remote::webdav::list_directory(
        crate::remote::webdav::shared_client(),
        &source,
        &path,
    )
    .await?;
    serde_json::to_string(&entries).map_err(|e| e.to_string())
}

#[derive(Default, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebdavSourceOverrides {
    pub base_url: Option<String>,
    pub username: Option<String>,
    pub root_path: Option<String>,
}

pub async fn webdav_test_saved_source(
    db_path: String,
    source_id: String,
    overrides_json: String,
) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    let mut source = crate::remote::repository::get_source(&conn, &source_id)?;
    let overrides: WebdavSourceOverrides = if overrides_json.trim().is_empty() {
        WebdavSourceOverrides::default()
    } else {
        serde_json::from_str(&overrides_json).map_err(|e| e.to_string())?
    };
    if let Some(base_url) = overrides.base_url {
        let trimmed = base_url.trim().trim_end_matches('/').to_string();
        if !trimmed.is_empty() {
            source.base_url = trimmed;
        }
    }
    if overrides.username.is_some() {
        source.username = overrides.username.filter(|v| !v.trim().is_empty());
    }
    if let Some(root_path) = overrides.root_path {
        let trimmed = root_path.trim().to_string();
        if !trimmed.is_empty() {
            source.root_path = trimmed;
        }
    }
    crate::remote::webdav::test_connection(&source).await
}

// =========================================================================
// 响度归一化（第四批）
// =========================================================================

pub fn loudness_playback_gain_for_file(
    file_path: String,
    gain_offset_db: f32,
    prevent_clipping: bool,
) -> f32 {
    let path = std::path::Path::new(&file_path);
    let Some((tag_gain, tag_peak)) = crate::player::loudness::extract_replaygain_from_path(path)
    else {
        return 1.0;
    };
    let record = crate::player::loudness::LoudnessRecord {
        song_id: 0,
        song_path: file_path,
        loudness_lufs: None,
        estimated_loudness_lufs: None,
        sample_peak: None,
        true_peak: None,
        tag_track_gain_db: Some(tag_gain as f64),
        tag_track_peak: tag_peak.map(|p| p as f64),
        tag_album_gain_db: None,
        tag_album_peak: None,
        tag_r128_track_gain_db: None,
        tag_r128_album_gain_db: None,
        file_size: 0,
        file_modified_at: 0,
        scan_source: "tag_replaygain".to_string(),
        analyzer_name: None,
        analyzer_version: 1,
        scan_status: "scanned".to_string(),
        scanned_at: None,
        error_message: None,
    };
    crate::player::loudness::calculate_playback_gain(&record, gain_offset_db, prevent_clipping)
}

pub fn get_track_loudness_info(db_path: String, song_id: i64) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let record = crate::player::loudness::get_song_loudness_record(&conn, song_id)?;
    match record {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

// =========================================================================
// 听歌统计（第五批）
// =========================================================================

fn stats_schema_ready() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static READY: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    READY.get_or_init(|| std::sync::Mutex::new(std::collections::HashSet::new()))
}

fn open_stats_conn(db_path: &str) -> Result<rusqlite::Connection, String> {
    let conn = rusqlite::Connection::open(db_path).map_err(|e| e.to_string())?;
    crate::database::schema::configure_connection(&conn)?;
    let mut ready = stats_schema_ready()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if !ready.contains(db_path) {
        crate::database::schema::ensure_base_schema(&conn)?;
        crate::database::migrations::run_migrations(&conn)?;
        ready.insert(db_path.to_string());
    }
    Ok(conn)
}

pub fn stats_record_play(db_path: String, payload_json: String) -> Result<(), String> {
    let payload: crate::statistics::RecordPlayPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::record_play(&mut conn, payload)
}

pub fn stats_get_listen_durations(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_listen_durations(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_behavior_stats(
    db_path: String,
    time_range_json: String,
) -> Result<String, String> {
    let tr: crate::statistics::TimeRange =
        serde_json::from_str(&time_range_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_behavior_stats(&conn, tr)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_recent_history(db_path: String, limit: Option<usize>) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_history(&conn, limit)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_add_to_history(db_path: String, song_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::add_to_history(&conn, song_path)
}

pub fn stats_clear_recent_history(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::clear_recent_history(&conn)
}

pub fn stats_remove_from_recent_history(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_from_recent_history(&mut conn, song_paths)
}

pub fn stats_export_statistics_file(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
    let options: crate::statistics::StatisticsExportOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::export_statistics_file(&conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_preview_statistics_import(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
    let options: crate::statistics::StatisticsImportPreviewOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::preview_statistics_import(&conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_import_statistics_file(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
    let options: crate::statistics::StatisticsImportOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::import_statistics_file(&mut conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub(crate) fn open_scan_conn(db_path: &str) -> Result<rusqlite::Connection, String> {
    let conn = rusqlite::Connection::open(db_path).map_err(|e| e.to_string())?;
    crate::database::schema::configure_connection(&conn)?;
    crate::database::schema::ensure_base_schema(&conn)?;
    crate::database::migrations::run_migrations(&conn)?;
    Ok(conn)
}

// =========================================================================
// 音乐库扫描（第六批）
// =========================================================================

fn derive_cover_cache_dir(db_path: &str) -> Option<std::path::PathBuf> {
    let db = std::path::Path::new(db_path);
    let cache_root = db.parent()?.join("cover_cache");
    Some(crate::music::covers::get_cover_cache_dir(&cache_root))
}

pub fn scan_music_folder(
    db_path: String,
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
    allowed_formats: Option<Vec<String>>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let options =
        crate::music::scanner::ScanOptions::new(minimum_duration_seconds, allowed_formats);
    let cover_cache_dir = derive_cover_cache_dir(&db_path);
    let songs = crate::music::scanner::scan_single_directory_internal(
        folder_path,
        db_conn,
        None,
        None,
        1,
        1,
        options,
        cover_cache_dir,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn parse_audio_files(
    paths: Vec<String>,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs = crate::music::scanner::parse_audio_files(paths, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn parse_music_folder(
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs = crate::music::scanner::parse_music_folder(folder_path, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn parse_audio_from_fd_android(
    fd: i32,
    file_name: String,
    path_key: String,
    format: String,
) -> Result<String, String> {
    let song = crate::music::scanner::parse_song_from_fd(fd, &file_name, &path_key, &format)
        .ok_or_else(|| format!("无法解析音频（fd={fd}）"))?;
    serde_json::to_string(&song).map_err(|e| e.to_string())
}

pub fn parse_audio_from_path_android(
    file_path: String,
    file_name: String,
    path_key: String,
    format: String,
) -> Result<String, String> {
    let path = std::path::Path::new(&file_path);
    let song =
        crate::music::scanner::parse_song_from_file_with_name(path, &file_name, &path_key, &format)
            .ok_or_else(|| format!("无法解析音频（file={file_path}）"))?;
    serde_json::to_string(&song).map_err(|e| e.to_string())
}

pub fn extract_song_cover_thumbnail_from_path(
    cache_root: String,
    source_key: String,
    real_path: String,
) -> Result<String, String> {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    crate::music::covers::get_or_create_thumbnail_from_path(
        &source_key,
        std::path::Path::new(&real_path),
        &cache_dir,
    )
    .ok_or_else(|| "无内嵌封面".to_string())
}

pub fn scan_saf_songs_commit(
    db_path: String,
    folder_key: String,
    songs_json: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs: Vec<crate::music::types::Song> =
        serde_json::from_str(&songs_json).map_err(|e| e.to_string())?;
    let mut conn = open_scan_conn(&db_path)?;
    let options = crate::music::scanner::ScanOptions::new(minimum_duration_seconds, None);
    crate::music::scanner::commit_saf_scan_songs(&mut conn, &folder_key, songs, &options)?;
    Ok("ok".to_string())
}

// =========================================================================
// WebDAV 远程源管理（第七批）
// =========================================================================

pub fn list_remote_sources(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let sources = crate::remote::repository::list_sources(&conn)?;
    serde_json::to_string(&sources).map_err(|e| e.to_string())
}

pub fn save_remote_source(db_path: String, source_json: String) -> Result<String, String> {
    let input: crate::remote::types::RemoteSourceInput =
        serde_json::from_str(&source_json).map_err(|e| e.to_string())?;
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::save_source(&conn, input)?;
    serde_json::to_string(&source).map_err(|e| e.to_string())
}

pub fn remove_remote_source(db_path: String, source_id: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::remote::repository::remove_source(&mut conn, &source_id)
}

pub async fn sync_remote_source(
    db_path: String,
    cache_root: String,
    source_id: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::get_source(&conn, &source_id)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let result =
        crate::remote::scanner::sync_source(std::path::Path::new(&cache_root), db_conn, source)
            .await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn get_remote_cache_usage(cache_root: String) -> Result<String, String> {
    let usage = crate::remote::cache::cache_usage(std::path::Path::new(&cache_root))?;
    serde_json::to_string(&usage).map_err(|e| e.to_string())
}

pub fn clear_remote_cache(cache_root: String) -> Result<String, String> {
    let usage = crate::remote::cache::clear_cache(std::path::Path::new(&cache_root))?;
    serde_json::to_string(&usage).map_err(|e| e.to_string())
}

pub fn remote_playback_source(db_path: String, remote_uri: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::cache::remote_playback_source(&conn, &remote_uri)?;
    serde_json::to_string(&source).map_err(|e| e.to_string())
}

// =========================================================================
// 账号认证（第八批）
// =========================================================================

pub async fn auth_authed_request(
    data_dir: String,
    action: String,
    body_json: String,
    fetch_timeout_ms: Option<u64>,
) -> Result<String, String> {
    let body: serde_json::Value = serde_json::from_str(&body_json).map_err(|e| e.to_string())?;
    let payload = crate::music::auth::authed_request(
        std::path::Path::new(&data_dir),
        action,
        body,
        fetch_timeout_ms,
    )
    .await?;
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

pub fn auth_save_credentials(
    data_dir: String,
    token: String,
    user_json: String,
) -> Result<(), String> {
    let user: serde_json::Value = serde_json::from_str(&user_json).map_err(|e| e.to_string())?;
    crate::music::auth::save_auth_credentials(std::path::Path::new(&data_dir), token, user)
}

pub fn auth_get_credentials(data_dir: String) -> Result<String, String> {
    let credentials = crate::music::auth::get_auth_credentials(std::path::Path::new(&data_dir))?;
    serde_json::to_string(&credentials).map_err(|e| e.to_string())
}

pub fn auth_clear_credentials(data_dir: String) -> Result<(), String> {
    crate::music::auth::clear_auth_credentials(std::path::Path::new(&data_dir))
}

pub fn auth_set_base_url(data_dir: String, base_url: String) -> Result<(), String> {
    crate::music::auth::set_auth_base_url(std::path::Path::new(&data_dir), base_url)
}

pub fn auth_set_api_secret(data_dir: String, api_secret: String) -> Result<(), String> {
    crate::music::auth::set_auth_api_secret(std::path::Path::new(&data_dir), api_secret)
}

// =========================================================================
// 音乐库管理（第九批）
// =========================================================================

pub fn get_library_folders(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let folders = crate::music::library::get_library_folders(&conn)?;
    serde_json::to_string(&folders).map_err(|e| e.to_string())
}

pub fn add_library_folder(db_path: String, path: String) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::library::add_library_folder(&conn, path)
}

pub fn remove_library_folder(db_path: String, path: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::library::remove_library_folder(&mut conn, path)
}

pub fn get_library_songs_cached(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::get_library_songs_cached(&conn)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn get_library_songs_by_paths(db_path: String, paths: Vec<String>) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::get_library_songs_by_paths(&conn, paths)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn search_library_songs(
    db_path: String,
    query: String,
    limit: Option<usize>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::search_library_songs(&conn, query, limit)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn get_library_artist_catalog(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let items = crate::music::library::get_library_artist_catalog(&conn)?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub fn get_library_album_catalog(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let items = crate::music::library::get_library_album_catalog(&conn)?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

pub fn get_library_song_paths_by_artist(
    db_path: String,
    artist_name: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_by_artist(&conn, artist_name)?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

pub fn get_library_song_paths_by_album(
    db_path: String,
    album_key: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_by_album(&conn, album_key)?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

pub fn get_library_song_paths_for_folder_view(
    db_path: String,
    folder_path: String,
    query: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let mode = crate::music::library::parse_folder_song_sort_mode(&sort_mode)?;
    let paths = crate::music::library::get_library_song_paths_for_folder_view(
        &conn,
        folder_path,
        query,
        mode,
    )?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

pub fn get_library_hierarchy(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let tree = crate::music::library::get_library_hierarchy(&conn)?;
    serde_json::to_string(&tree).map_err(|e| e.to_string())
}

// =========================================================================
// 封面缓存管理（第十批）
// =========================================================================

pub async fn get_song_cover_thumbnail(
    db_path: String,
    cache_root: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::covers::get_song_cover_thumbnail(
        std::path::PathBuf::from(&cache_root),
        db_conn,
        path,
    )
    .await
}

pub async fn get_song_cover(
    db_path: String,
    cache_root: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::covers::get_song_cover(std::path::PathBuf::from(&cache_root), db_conn, path).await
}

pub fn extract_song_cover_thumbnail_from_fd(
    cache_root: String,
    path: String,
    fd: i32,
) -> Result<String, String> {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    std::thread::spawn(move || {
        crate::music::covers::get_or_create_thumbnail_from_fd(&path, fd, &cache_dir)
    })
    .join()
    .map_err(|_| "缩略图生成线程异常".to_string())?
    .ok_or_else(|| "无内嵌封面".to_string())
}

// =========================================================================
// 文件操作（第十一批）
// =========================================================================

pub async fn get_song_lyrics_payload(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics_payload(path, db_conn).await
}

pub async fn get_song_lyrics_for_edit(path: String) -> Result<String, String> {
    crate::music::files::get_song_lyrics_for_edit(path).await
}

pub async fn save_song_lyrics(
    path: String,
    lyrics: String,
    source: crate::music::types::LyricsStorageSource,
    source_path: Option<String>,
) -> Result<String, String> {
    crate::music::files::save_song_lyrics(path, lyrics, source, source_path).await
}

pub async fn get_song_lyrics(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics(path, db_conn).await
}

pub fn read_lyrics_file(path: String) -> Result<String, String> {
    crate::music::files::read_lyrics_file(path)
}

pub fn save_song_background(
    db_path: String,
    song_backgrounds_root: String,
    song_path: String,
    background_path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::save_song_background(
        &conn,
        std::path::Path::new(&song_backgrounds_root),
        song_path,
        background_path,
    )
}

pub fn get_song_background(db_path: String, song_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let result = crate::music::files::get_song_background(&conn, song_path)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn clear_song_background(
    db_path: String,
    song_backgrounds_root: String,
    song_path: String,
) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::clear_song_background(
        &conn,
        std::path::Path::new(&song_backgrounds_root),
        song_path,
    )
}

pub fn save_song_info(
    db_path: String,
    path: String,
    payload_json: String,
) -> Result<String, String> {
    let mut conn = open_scan_conn(&db_path)?;
    let payload: crate::music::types::SongInfoEditPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    crate::music::files::save_song_info(&mut conn, path, payload)
}

pub fn get_song_detail(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::get_song_detail(&conn, path)
}

// =========================================================================
// 播放会话（第十二批）
// =========================================================================

use crate::player::session::PlaybackSessionState;
use crate::player::types::PlaybackSessionData;

fn global_playback_session() -> &'static PlaybackSessionState {
    static SESSION: std::sync::OnceLock<PlaybackSessionState> = std::sync::OnceLock::new();
    SESSION.get_or_init(PlaybackSessionState::new)
}

pub fn save_playback_session(db_path: String, session_json: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    let session: PlaybackSessionData =
        serde_json::from_str(&session_json).map_err(|e| e.to_string())?;
    global_playback_session().save_playback_session(&conn, session)
}

pub fn load_playback_session(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().load_from_db(&conn)?;
    serde_json::to_string(&global_playback_session().get_playback_session())
        .map_err(|e| e.to_string())
}

pub fn session_get_playback_session(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().load_from_db(&conn)?;
    serde_json::to_string(&global_playback_session().get_playback_session())
        .map_err(|e| e.to_string())
}

pub fn session_flush_playback_session(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().flush_playback_session(&conn)
}
pub fn update_playback_position(
    db_path: String,
    position_secs: f64,
    is_playing: bool,
) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().update_playback_position(&conn, position_secs, is_playing)
}

// =========================================================================
// 工具箱（第十三批）
// =========================================================================

pub fn preview_rename(root_path: String, config_json: String) -> Result<String, String> {
    let config: crate::toolbox::RenameConfig =
        serde_json::from_str(&config_json).map_err(|e| e.to_string())?;
    let previews = crate::toolbox::preview_rename(root_path, config)?;
    serde_json::to_string(&previews).map_err(|e| e.to_string())
}

pub fn apply_rename(operations_json: String) -> Result<u32, String> {
    let operations: Vec<crate::toolbox::RenameOperation> =
        serde_json::from_str(&operations_json).map_err(|e| e.to_string())?;
    crate::toolbox::apply_rename(operations)
}

pub fn refresh_folder_songs(
    db_path: String,
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let cover_cache_dir = derive_cover_cache_dir(&db_path);
    let songs = crate::toolbox::refresh_folder_songs(
        db_conn,
        folder_path,
        minimum_duration_seconds,
        cover_cache_dir,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn resolve_download_full_path(
    directory: String,
    title: String,
    artist: String,
    album: String,
    url: String,
    quality: String,
    keep_source_filename: bool,
    file_name_style: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    crate::toolbox::resolve_download_full_path(
        directory,
        title,
        artist,
        album,
        url,
        quality,
        keep_source_filename,
        file_name_style,
        overwrite_existing,
    )
}

// =========================================================================
// USB 独占音频输出（仅 Android）
// =========================================================================

pub fn start_usb_exclusive_playback(
    path: String,
    device_id: i32,
    volume: f32,
    start_time_secs: f64,
    is_playing: bool,
    volume_balance_gain: f32,
    equalizer_settings_json: String,
    sound_effect_settings_json: String,
    bit_perfect: bool,
    dsd_native_passthrough: bool,
    shared_mode: bool,
) -> Result<String, String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Play {
            path,
            device_id,
            volume,
            start_time_secs,
            is_playing,
            volume_balance_gain,
            equalizer_settings_json,
            sound_effect_settings_json,
            bit_perfect,
            dsd_native_passthrough,
            shared_mode,
        },
    )
}

pub fn stop_usb_exclusive_playback() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Stop,
    )
    .ok();
}

pub fn pause_usb_exclusive() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Pause,
    )
    .ok();
}

pub fn resume_usb_exclusive() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Resume,
    )
    .ok();
}

pub fn seek_usb_exclusive(time_secs: f64, is_playing: bool) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Seek {
            time_secs,
            is_playing,
        },
    )
    .ok();
}

pub fn set_usb_exclusive_volume(volume: f32) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetVolume(volume),
    )
    .ok();
}

pub fn set_usb_exclusive_volume_balance_gain(gain: f32) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetVolumeBalanceGain(gain),
    )
    .ok();
}

pub fn set_usb_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetEqualizer(settings_json),
    )
    .map(|_| ())
}

pub fn set_usb_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetSoundEffect(settings_json),
    )
    .map(|_| ())
}

pub fn set_usb_exclusive_bit_perfect(enabled: bool) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetBitPerfect(enabled),
    )
    .ok();
}

pub fn get_usb_exclusive_bit_perfect() -> bool {
    crate::player::output::is_exclusive_bit_perfect()
}

pub fn get_usb_exclusive_device_info() -> String {
    crate::player::output::get_exclusive_device_info()
}

pub fn get_usb_exclusive_position_secs() -> f64 {
    crate::player::output::get_exclusive_position_secs()
}

pub async fn download_online_song(
    url: String,
    dest_path: String,
    ekey: Option<String>,
    headers_json: String,
) -> Result<String, String> {
    let headers: std::collections::HashMap<String, String> = if headers_json.trim().is_empty() {
        std::collections::HashMap::new()
    } else {
        serde_json::from_str(&headers_json).map_err(|e| e.to_string())?
    };
    crate::toolbox::download_online_song(url, dest_path, ekey, Some(headers)).await
}

pub fn decrypt_qmc_file_standalone(
    file_path: String,
    ekey: Option<String>,
) -> Result<String, String> {
    crate::toolbox::decrypt_qmc_file_standalone(file_path, ekey)
}

pub async fn finalize_download_extras(request_json: String) -> Result<String, String> {
    let request: crate::toolbox::FinalizeDownloadExtrasRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    let result = crate::toolbox::finalize_download_extras(request).await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn read_download_history(data_dir: String) -> Result<String, String> {
    crate::toolbox::read_download_history(std::path::Path::new(&data_dir)).await
}

pub async fn write_download_history(data_dir: String, content: String) -> Result<(), String> {
    crate::toolbox::write_download_history(std::path::Path::new(&data_dir), content).await
}

pub async fn fetch_announcement() -> Result<String, String> {
    crate::toolbox::fetch_announcement().await
}

// =========================================================================
// 插件 / 识曲（第十四批）
// =========================================================================

pub fn read_plugin_file(path: String) -> Result<String, String> {
    crate::plugins::read_plugin_file(path)
}

pub async fn proxy_image(url: String, referer: Option<String>) -> Result<String, String> {
    crate::plugins::proxy_image(url, referer).await
}

pub fn read_image_base64(path: String) -> Result<String, String> {
    crate::plugins::read_image_base64(path)
}

pub async fn download_video_to_cache(
    cache_dir: String,
    url: String,
    headers: Option<std::collections::HashMap<String, String>>,
) -> Result<String, String> {
    crate::plugins::download_video_to_cache(cache_dir, url, headers).await
}

pub async fn remove_cached_background_video(cache_dir: String, path: String) -> Result<(), String> {
    crate::plugins::remove_cached_background_video(cache_dir, path).await
}

// =========================================================================
// 宿主端平台签名/加密 + 兜底模块验签（移植自桌面端 host_crypto / fallback_verify）
// 供插件脚本 / 前端调用，对齐桌面端同名 Tauri 命令。
// =========================================================================

pub fn host_zzc_sign(text: String) -> String {
    crate::host_crypto::zzc_sign(&text)
}

pub fn host_kugou_sign(params: String, platform: String, body: Option<String>) -> String {
    crate::host_crypto::kugou_sign(&params, &platform, body.as_deref().unwrap_or(""))
}

pub fn host_kugou_request_key() -> String {
    crate::host_crypto::KG_SALT_ANDROID.to_string()
}

pub fn host_migu_sign(text: String, time: String) -> String {
    let (sign, device_id) = crate::host_crypto::migu_sign(&text, &time);
    serde_json::json!({ "sign": sign, "deviceId": device_id }).to_string()
}

pub fn host_linuxapi_encrypt(payload: String) -> String {
    crate::host_crypto::linuxapi_encrypt(&payload)
}

pub fn host_weapi_encrypt(payload: String) -> String {
    let (params, enc_sec_key) = crate::host_crypto::weapi_encrypt(&payload);
    serde_json::json!({ "params": params, "encSecKey": enc_sec_key }).to_string()
}

pub fn host_sha256_hex(text: String) -> String {
    crate::host_crypto::sha256_hex(&text)
}

pub fn verify_fallback_module_signature(
    module_key: String,
    version: i64,
    code: String,
    signature: String,
) -> Result<bool, String> {
    crate::fallback_verify::verify_fallback_module_signature(
        &module_key,
        version,
        &code,
        &signature,
    )
}

// =========================================================================
// 插件引擎（QuickJS 沙箱，移植自桌面端 plugin_host）
// =========================================================================

pub fn plugin_engine_init(data_dir: String) -> Result<(), String> {
    crate::plugin_host::global_engine(&data_dir);
    Ok(())
}

pub async fn plugin_engine_load_lx(
    data_dir: String,
    plugin_id: String,
    script: String,
    script_info_json: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine.load_lx(&plugin_id, &script, &script_info_json).await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn plugin_engine_load_musicfree(
    data_dir: String,
    plugin_id: String,
    script: String,
    user_vars_json: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine
        .load_musicfree(&plugin_id, &script, &user_vars_json)
        .await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn plugin_engine_call(
    data_dir: String,
    plugin_id: String,
    method: String,
    args_json: String,
    user_vars_json: Option<String>,
    timeout_ms: u64,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine
        .call(
            &plugin_id,
            &method,
            &args_json,
            user_vars_json.as_deref(),
            timeout_ms,
        )
        .await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn plugin_engine_destroy(data_dir: String, plugin_id: String) -> Result<(), String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    engine.unload(&plugin_id).await;
    Ok(())
}

pub async fn plugin_engine_destroy_all(data_dir: String) -> Result<(), String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    engine.unload_all().await;
    Ok(())
}

pub fn cancel_recognize_system_audio() -> Result<(), String> {
    crate::recognize::cancel_recognize_system_audio()
}

pub async fn recognize_with_pcm(pcm: Vec<u8>) -> Result<String, String> {
    let resp = crate::recognize::recognize_with_pcm(pcm).await?;
    serde_json::to_string(&resp).map_err(|e| e.to_string())
}

// =========================================================================
// 在线播放流式缓存（常规 → 存储空间）
// 与桌面端 SettingsGeneral 的「存储空间」分组对齐。
// =========================================================================

pub fn set_stream_cache_max_size_bytes(bytes: u64) {
    crate::player::stream_cache::set_max_cache_size(bytes);
}

pub fn stream_cache_current_bytes() -> u64 {
    crate::player::stream_cache::current_cache_size()
}

pub fn stream_cache_max_bytes() -> u64 {
    crate::player::stream_cache::max_cache_size()
}

pub fn clear_stream_cache() {
    crate::player::stream_cache::clear_all();
}

// =========================================================================
// 统计分布 / 重置（对齐桌面端 statistics）
// =========================================================================

pub fn stats_get_quality_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_quality_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_format_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_format_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_library_stats(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_library_stats(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_reset_local_statistics(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::reset_local_statistics(&conn)
}

// =========================================================================
// 收藏 / 近期目录（对齐桌面端 get_favorite_*/get_recent_*）
// =========================================================================

pub fn stats_get_favorite_artist_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_artist_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_favorite_album_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_album_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_favorite_song_paths_view(
    db_path: String,
    favorite_paths: Vec<String>,
    query: Option<String>,
    sort_mode: String,
    detail_filter_type: Option<String>,
    detail_filter_value: Option<String>,
) -> Result<String, String> {
    let sort: crate::statistics::SongPathSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_song_paths_view(
        &conn,
        favorite_paths,
        query,
        sort,
        detail_filter_type,
        detail_filter_value,
    )?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_recent_album_catalog(
    db_path: String,
    recent_entries_json: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_album_catalog(&conn, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_recent_song_paths_view(
    db_path: String,
    recent_entries_json: String,
    query: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let sort: crate::statistics::SongPathSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_song_paths_view(&conn, entries, query, sort)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_get_recent_playlist_catalog(
    playlists_json: String,
    recent_entries_json: String,
) -> Result<String, String> {
    let playlists: Vec<crate::statistics::PlaylistImportItem> =
        serde_json::from_str(&playlists_json).map_err(|e| e.to_string())?;
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let v = crate::statistics::get_recent_playlist_catalog(playlists, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

// =========================================================================
// 封面缓存清理（对齐桌面端 music::covers::clear_cover_cache）
// =========================================================================

pub fn clear_cover_cache(cache_dir: String) -> Result<(), String> {
    crate::music::covers::clear_no_cover_negative_cache();
    crate::music::covers::clear_cover_cache(std::path::Path::new(&cache_dir))
}

// =========================================================================
// LX 音源解析辅助（对齐桌面端 get_lx_cover / 换源 / 缓存清理）
// =========================================================================

pub async fn get_lx_cover(song_info_json: String) -> Result<String, String> {
    let song_info: LxUrlSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let url = crate::music::url_resolver::get_lx_cover(song_info).await?;
    serde_json::to_string(&url).map_err(|e| e.to_string())
}

pub async fn clear_lx_url_cache() -> Result<(), String> {
    crate::music::url_resolver::clear_lx_url_cache().await
}

pub async fn clear_lx_all_cache() -> Result<(), String> {
    if crate::music::url_resolver::clear_lx_url_cache()
        .await
        .is_err()
    {
        return Err("清除 URL 缓存失败".to_string());
    }
    crate::music::lx_search::clear_lx_all_cache().await
}

pub async fn find_alternative_lx_source(
    song_name: String,
    song_artist: String,
    song_duration: f64,
    failed_sources_json: String,
) -> Result<String, String> {
    let failed_sources: Vec<String> =
        serde_json::from_str(&failed_sources_json).map_err(|e| e.to_string())?;
    let result = crate::music::url_resolver::find_alternative_lx_source(
        song_name,
        song_artist,
        song_duration,
        failed_sources,
    )
    .await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

// =========================================================================
// 远程源管理增强（对齐桌面端 test_remote_source / precache / list_directory）
// =========================================================================

pub async fn test_remote_source(source_json: String) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TestInput {
        id: Option<String>,
        name: String,
        provider: String,
        base_url: String,
        username: Option<String>,
        password: Option<String>,
        root_path: Option<String>,
    }
    let input: TestInput = serde_json::from_str(&source_json).map_err(|e| e.to_string())?;
    if input.provider != "webdav" {
        return Err("第一版仅支持 WebDAV".to_string());
    }
    let creds = crate::remote::types::RemoteSourceCredentials {
        id: input.id.unwrap_or_else(|| "test".to_string()),
        name: input.name,
        provider: input.provider,
        base_url: input.base_url.trim().trim_end_matches('/').to_string(),
        username: input.username,
        password: input.password,
        root_path: input.root_path.unwrap_or_else(|| "/".to_string()),
        enabled: true,
        last_sync_at: None,
        last_sync_error: None,
        created_at: crate::remote::now_seconds(),
        updated_at: crate::remote::now_seconds(),
    };
    match crate::remote::webdav::test_connection(&creds).await {
        Ok(()) => Ok(serde_json::json!({ "ok": true, "message": "连接成功" }).to_string()),
        Err(error) => Ok(serde_json::json!({ "ok": false, "message": error }).to_string()),
    }
}

pub async fn precache_remote_song(
    db_path: String,
    cache_root: String,
    remote_uri: String,
) -> Result<(), String> {
    if !crate::remote::cache::is_remote_uri(&remote_uri) {
        return Ok(());
    }
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(open_scan_conn(&db_path)?));
    crate::remote::cache::ensure_cached_path(
        std::path::Path::new(&cache_root),
        db_conn,
        &remote_uri,
    )
    .await
    .map(|_| ())
}

pub async fn list_remote_directory(
    db_path: String,
    source_id: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::get_source(&conn, &source_id)?;
    let entries = crate::remote::webdav::list_directory(
        crate::remote::webdav::shared_client(),
        &source,
        &path,
    )
    .await?;
    serde_json::to_string(&entries).map_err(|e| e.to_string())
}

pub async fn transcode_audio_to_wav(
    db_path: String,
    cache_root: String,
    src_path: String,
) -> Result<String, String> {
    let outcome = crate::player::transcode::transcode_to_wav(
        &db_path,
        std::path::Path::new(&cache_root),
        &src_path,
    )
    .await?;
    serde_json::to_string(&outcome).map_err(|e| e.to_string())
}

// =========================================================================
// 下载工具链（对齐桌面端 probe_url_size / write_text / fetch_image /
// embed_metadata / finalize_extras）
// =========================================================================

pub async fn probe_url_size(url: String) -> Result<String, String> {
    let info = crate::toolbox::probe_url_size(url).await?;
    serde_json::to_string(&info).map_err(|e| e.to_string())
}

pub async fn write_text_file(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::write_text_file(content, dest_path).await
}

pub async fn fetch_image_bytes(url: String) -> Result<String, String> {
    let img = crate::toolbox::fetch_image_bytes(url).await?;
    serde_json::to_string(&img).map_err(|e| e.to_string())
}

pub async fn embed_audio_metadata(request_json: String) -> Result<(), String> {
    let request: crate::music::tags::EmbedMetadataRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    crate::toolbox::embed_audio_metadata(request).await
}

// =========================================================================
// 曲库 / 文件 / 下载管理补齐（对齐桌面端 library/files/toolbox）
// =========================================================================

pub fn is_directory(path: String) -> bool {
    crate::music::files::is_directory(path)
}

pub fn save_artist_avatar(
    db_path: String,
    covers_root: String,
    artist_id: i64,
    image_path: String,
    write_to_tags: bool,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::save_artist_avatar(
        &conn,
        std::path::Path::new(&covers_root),
        artist_id,
        image_path,
        write_to_tags,
    )
}

pub fn get_library_song_paths_for_all_view(
    db_path: String,
    query: Option<String>,
    artist_filter: Option<String>,
    album_filter: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let mode: crate::music::library::LibrarySongSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_for_all_view(
        &conn,
        query,
        artist_filter,
        album_filter,
        mode,
    )?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

pub fn scan_library(
    db_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let shared = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let cover_cache_dir = derive_cover_cache_dir(&db_path);
    let songs =
        crate::music::library::scan_library(shared, minimum_duration_seconds, cover_cache_dir)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

pub fn get_folder_children(db_path: String, folder_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let nodes = crate::music::library::get_folder_children(&conn, folder_path)?;
    serde_json::to_string(&nodes).map_err(|e| e.to_string())
}

pub fn get_folder_first_song(db_path: String, folder_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let path = crate::music::scanner::find_first_song_in_folder(&conn, &folder_path);
    serde_json::to_string(&path).map_err(|e| e.to_string())
}

pub fn create_folder(parent_path: String, folder_name: String) -> Result<String, String> {
    crate::music::files::create_folder(parent_path, folder_name)
}

pub fn delete_folder(path: String) -> Result<(), String> {
    crate::music::files::delete_folder(path)
}

pub fn move_file_to_folder(
    db_path: String,
    source_path: String,
    target_folder: String,
) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_file_to_folder(&mut conn, source_path, target_folder)
}

pub fn batch_move_music_files(
    db_path: String,
    paths: Vec<String>,
    target_folder: String,
) -> Result<String, String> {
    let mut conn = open_scan_conn(&db_path)?;
    let result = crate::music::files::batch_move_music_files(&mut conn, paths, target_folder)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn move_music_file(db_path: String, old_path: String, new_path: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_music_file(&mut conn, old_path, new_path)
}

pub fn delete_music_file(path: String) -> Result<(), String> {
    crate::music::files::delete_music_file(path)
}

pub fn remove_songs_from_history_and_statistics(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_songs_from_history_and_statistics(&mut conn, song_paths)
}

pub fn resolve_download_path(
    directory: String,
    file_name: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    crate::toolbox::resolve_download_path(directory, file_name, overwrite_existing)
}

pub fn build_download_basename(
    title: String,
    artist: String,
    album: String,
    file_name_style: String,
) -> String {
    crate::toolbox::build_download_basename(title, artist, album, file_name_style)
}

pub async fn save_download_bytes(data: Vec<u8>, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_bytes(data, dest_path).await
}

pub async fn save_download_lyrics(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_lyrics(content, dest_path).await
}

// =========================================================================
// 流缓存增强（对齐桌面端 get_stream_cache_info/is_stream_cached/
// copy_stream_cache/wait_stream_complete）
// =========================================================================

pub fn get_stream_cache_info() -> String {
    serde_json::json!({
        "current": crate::player::stream_cache::current_cache_size(),
        "max": crate::player::stream_cache::max_cache_size(),
    })
    .to_string()
}

pub fn is_stream_cached(url: String) -> bool {
    crate::player::stream_cache::is_url_cached(&url)
}

pub fn copy_stream_cache(url: String, dest_path: String) -> Result<u64, String> {
    crate::player::stream_cache::copy_cache_to(&url, &dest_path)
}

pub async fn wait_stream_complete(url: String, timeout_secs: u64) -> bool {
    tokio::task::spawn_blocking(move || {
        crate::player::stream_cache::wait_url_complete(&url, timeout_secs)
    })
    .await
    .unwrap_or(false)
}

// =========================================================================
// 响度目标设置 + 云端时长合并（对齐桌面端 update_loudness_settings /
// merge_cloud_listen_duration）
// =========================================================================

pub fn update_loudness_settings(
    db_path: String,
    enabled: bool,
    song_id: Option<i64>,
    song_path: Option<String>,
    gain_offset_db: f32,
    prevent_clipping: bool,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let gain = if enabled {
        if song_id.is_none() || song_path.is_none() {
            return Ok(serde_json::json!({ "enabled": true, "targetGain": 1.0 }).to_string());
        }
        let record = crate::player::loudness::process_song_on_play(
            &conn,
            song_id.unwrap(),
            song_path.as_ref().unwrap(),
        )?;
        crate::player::loudness::calculate_playback_gain(&record, gain_offset_db, prevent_clipping)
    } else {
        1.0
    };
    Ok(serde_json::json!({ "enabled": enabled, "targetGain": gain }).to_string())
}

pub fn merge_cloud_listen_duration(db_path: String, total_seconds: i64) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::merge_cloud_listen_duration(&conn, total_seconds)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn stats_export_listen_snapshot(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::export_listen_stats_snapshot(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

pub fn stats_import_listen_snapshot(
    db_path: String,
    snapshot_json: String,
) -> Result<String, String> {
    let snapshot: crate::statistics::ListenStatsSnapshot =
        serde_json::from_str(&snapshot_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::import_listen_stats_snapshot(&mut conn, &snapshot)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn stats_import_listen_snapshot_add(
    db_path: String,
    snapshot_json: String,
) -> Result<String, String> {
    let snapshot: crate::statistics::ListenStatsSnapshot =
        serde_json::from_str(&snapshot_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::import_listen_stats_snapshot_add(&mut conn, &snapshot)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn stats_clear_listen_stats(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::clear_listen_stats(&conn)
}

// =========================================================================
// 插件引擎会话增强（对齐桌面端 store_import / cookie_header_for_domain /
// store_snapshot）
// =========================================================================

pub async fn plugin_engine_store_import(
    data_dir: String,
    payload_json: String,
) -> Result<(), String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct StoreImportPayload {
        cookies: std::collections::HashMap<String, crate::plugin_host::CookieEntry>,
        storage: std::collections::HashMap<String, String>,
        #[serde(default)]
        overwrite_cookies: bool,
    }
    let payload: StoreImportPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    let engine = crate::plugin_host::global_engine(&data_dir);
    if payload.overwrite_cookies {
        engine.store().upsert_cookies(payload.cookies);
        engine
            .store()
            .import_local(std::collections::HashMap::new(), payload.storage);
    } else {
        engine
            .store()
            .import_local(payload.cookies, payload.storage);
    }
    Ok(())
}

pub async fn plugin_engine_cookie_header_for_domain(
    data_dir: String,
    domain: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    Ok(engine.store().cookie_header_for_domain(&domain))
}

pub async fn plugin_engine_store_snapshot(data_dir: String) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = serde_json::json!({
        "cookies": engine.store().cookie_snapshot(),
        "storage": engine.store().storage_snapshot(),
    });
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

// =========================================================================
// =========================================================================

use crate::dlna::{DlnaCore, DlnaDevice, MediaPayload, TransportState};

fn parse_device(device_json: &str) -> Result<DlnaDevice, String> {
    serde_json::from_str(device_json).map_err(|e| format!("设备参数解析失败: {e}"))
}

fn parse_media(media_json: &str) -> Result<MediaPayload, String> {
    serde_json::from_str(media_json).map_err(|e| format!("媒体参数解析失败: {e}"))
}

pub async fn dlna_search_devices(timeout_ms: u64) -> Result<String, String> {
    let devices = DlnaCore::shared().search_devices(timeout_ms).await;
    serde_json::to_string(&devices).map_err(|e| e.to_string())
}

pub async fn dlna_cast_set_uri(
    device_json: String,
    media_json: String,
    cover_json: Option<String>,
    title: String,
    artist: String,
    album: String,
    duration_ms: u64,
) -> Result<String, String> {
    let device = parse_device(&device_json)?;
    let media = parse_media(&media_json)?;
    let cover = match cover_json {
        Some(s) => Some(parse_media(&s)?),
        None => None,
    };
    let info = DlnaCore::shared()
        .cast_set_uri(&device, media, cover, &title, &artist, &album, duration_ms)
        .await?;
    serde_json::to_string(&info).map_err(|e| e.to_string())
}

pub async fn dlna_cast_play(device_json: String) -> Result<(), String> {
    DlnaCore::shared().cast_play(&parse_device(&device_json)?).await
}

pub async fn dlna_cast_pause(device_json: String) -> Result<(), String> {
    DlnaCore::shared().cast_pause(&parse_device(&device_json)?).await
}

pub async fn dlna_cast_stop(device_json: String) -> Result<(), String> {
    DlnaCore::shared().cast_stop(&parse_device(&device_json)?).await
}

pub async fn dlna_cast_seek(device_json: String, secs: f64) -> Result<(), String> {
    DlnaCore::shared().cast_seek(&parse_device(&device_json)?, secs).await
}

pub async fn dlna_cast_set_volume(device_json: String, percent: u8) -> Result<(), String> {
    DlnaCore::shared()
        .cast_set_volume(&parse_device(&device_json)?, percent)
        .await
}

pub async fn dlna_cast_get_state(device_json: String) -> Result<String, String> {
    let state = DlnaCore::shared()
        .cast_get_state(&parse_device(&device_json)?)
        .await?;
    serde_json::to_string(&state).map_err(|e| e.to_string())
}

pub fn dlna_update_media_token(token: String, payload_json: String) -> Result<bool, String> {
    let payload = parse_media(&payload_json)?;
    Ok(DlnaCore::shared().update_media_token(&token, payload))
}

pub async fn dlna_enable_renderer(friendly_name: String, udn: String) -> Result<u16, String> {
    DlnaCore::shared()
        .enable_renderer(
            crate::dlna::RendererConfig {
                friendly_name,
                udn,
            },
            crate::dlna::bridge::host(),
        )
        .await
}

pub async fn dlna_disable_renderer() -> Result<(), String> {
    DlnaCore::shared().disable_renderer().await;
    crate::dlna::bridge::reset_playback();
    Ok(())
}

pub fn dlna_renderer_status() -> String {
    let core = DlnaCore::shared();
    let running = core.renderer_running();
    let (friendly_name, port) = core.renderer_info().unwrap_or_default();
    serde_json::json!({
        "running": running,
        "friendlyName": friendly_name,
        "port": port,
    })
    .to_string()
}

pub async fn dlna_dmr_next_command(timeout_ms: u64) -> Option<String> {
    let cmd = DlnaCore::shared().dmr_next_command(timeout_ms).await?;
    serde_json::to_string(&cmd).ok()
}

pub fn dlna_dmr_report_playback(
    state: String,
    position_secs: f64,
    duration_secs: f64,
    volume_percent: u8,
    muted: bool,
) {
    let state = match state.as_str() {
        "playing" => TransportState::Playing,
        "paused" => TransportState::PausedPlayback,
        "stopped" => TransportState::Stopped,
        "transitioning" => TransportState::Transitioning,
        _ => TransportState::NoMedia,
    };
    crate::dlna::bridge::report_playback(state, position_secs, duration_secs, volume_percent, muted);
}

// =========================================================================
// 无损音频格式转换（纯 Rust，无需 FFmpeg）
// =========================================================================

pub async fn convert_audio_batch(
    input_paths: Vec<String>,
    out_dir: String,
    options_json: String,
) -> Result<String, String> {
    let opts: crate::audio_convert::ConvertOptions =
        serde_json::from_str(&options_json).map_err(|e| format!("options 解析失败：{e}"))?;
    let results = crate::audio_convert::convert_audio(input_paths, out_dir, opts).await;
    serde_json::to_string(&results).map_err(|e| e.to_string())
}

pub fn audio_convert_supported_inputs() -> Vec<String> {
    vec![
        "mp3".to_string(),
        "flac".to_string(),
        "m4a".to_string(),
        "aac".to_string(),
        "ogg".to_string(),
        "wav".to_string(),
        "aif".to_string(),
        "aiff".to_string(),
        "alac".to_string(),
        "ape".to_string(),
        "wv".to_string(),
    ]
}

pub fn audio_convert_supported_outputs() -> Vec<String> {
    vec!["wav".to_string(), "flac".to_string(), "mp3".to_string()]
}
