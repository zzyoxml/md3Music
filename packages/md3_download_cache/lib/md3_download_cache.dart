/// md3_download_cache — MD3Music 私有功能包。
///
/// 仅承载「下载」与「边听边存缓存」的引擎与持久化（自包含，不依赖主工程类型）：
/// - `download/`：DownloadManager（dio 下载）+ DownloadTask 模型 + DownloadsRepository（任务持久化）
/// - `cache/`：StreamCacheManager（audio/lyrics/artwork 三类磁盘缓存 + LRU 清理）
///   + StreamCacheRepository（index.json 索引）+ LyricData（歌词最小 DTO）
///
/// 该包随主工程以 path 依赖引用，导出公开版本时整体排除，永不进入公开仓库。
library;

export 'cache/lyric_data.dart';
export 'cache/stream_cache_manager.dart';
export 'cache/stream_cache_repository.dart';
export 'download/download_manager.dart';
export 'download/download_task.dart';
export 'download/downloads_repository.dart';
