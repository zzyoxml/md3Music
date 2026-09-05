package com.md3music.md3music

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.CircularProgressIndicator
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.SnackbarHost
import top.yukonga.miuix.kmp.basic.SnackbarHostState
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.theme.ColorSchemeMode
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.ThemeController
import top.yukonga.miuix.kmp.theme.miuixShape
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar

/**
 * Miuix（MIUI 风格组件库）发现页测试页 —— HyperOS 音乐页风格重设计（原生 Kotlin + Compose）。
 *
 * 入口：设置 → 关于 → Miuix 发现页测试（开发）。
 *
 * 设计要点（miuix 审美 / 哲学）：
 * - 全部使用 MiuixTheme.colorScheme 语义色 token + MiuixTheme.textStyles 字阶，杜绝硬编码颜色/字号；
 * - 使用 miuix 内置平滑连续圆角 miuixShape()，替代生硬的 RoundedCornerShape；
 * - 顶部「每日推荐」Hero 大卡（封面 + 渐变遮罩 + 问候语 + 播放全部），取代纯色横幅；
 * - 各信息区块（每日推荐 / 主题歌单 / 场景音乐 / 热门歌单 / 排行榜）用 SmallTitle 分区 +
 *   横向滚动卡片，强调留白与柔和容器；
 * - 手绘 MIUI 风细线图标（AppIcon），替代文本符号。
 *
 * 数据直连本地 Rust API 服务器（http://127.0.0.1:<port>，端口由 Flutter 侧经
 * Intent extra 传入），仅改 UI，不动 Dart / 数据模型 / 接口。
 */
class MiuixDiscoverActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 沉浸式 + 深色模式：状态栏/导航栏纯透明，图标明暗跟随系统深浅色
        // （与 MiuixTheme ColorSchemeMode.System 保持一致，避免浅色图标在深色背景上不可见）
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ) { resources ->
                (resources.configuration.uiMode and
                    android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                    android.content.res.Configuration.UI_MODE_NIGHT_YES
            },
            navigationBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ) { resources ->
                (resources.configuration.uiMode and
                    android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                    android.content.res.Configuration.UI_MODE_NIGHT_YES
            },
        )
        val port = intent.getIntExtra(EXTRA_PORT, 0)
        setContent {
            MiuixDiscoverScreen(port = port, onBack = { finish() })
        }
    }

    companion object {
        const val EXTRA_PORT = "port"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 数据模型与加载（与 Dart 端 KugouProvider 同源，保持不变）
// ─────────────────────────────────────────────────────────────────────────────

/** 每日推荐歌曲行 */
private data class SongItem(val name: String, val artist: String, val cover: String? = null)

/** 通用封面项（主题歌单 / 热门歌单 / 排行榜） */
private data class CoverItem(val name: String, val cover: String?, val count: Int)

/** 场景音乐项 */
private data class SceneItem(val name: String)

private data class DiscoverData(
    val songs: List<SongItem> = emptyList(),
    val themes: List<CoverItem> = emptyList(),
    val scenes: List<SceneItem> = emptyList(),
    val playlists: List<CoverItem> = emptyList(),
    val ranks: List<CoverItem> = emptyList(),
)

private sealed interface DiscoverUiState {
    data object Loading : DiscoverUiState
    data class Success(val data: DiscoverData) : DiscoverUiState
    data class Error(val message: String) : DiscoverUiState
}

/** 直连本地 Rust API 服务器拉取发现页数据。 */
private object DiscoverRepository {

    suspend fun load(port: Int): DiscoverData = withContext(Dispatchers.IO) {
        if (port <= 0) throw IllegalStateException("本地服务器端口无效")
        // BASE 必须带上随机端口，否则会请求到 80 端口
        val base = "http://127.0.0.1:$port"
        // 各端点独立容错：单个接口失败（未登录 / 上游异常等）不影响其他区块展示
        fun <T> safe(block: () -> T): T? = try { block() } catch (e: Exception) { null }
        DiscoverData(
            songs = safe { parseSongList(get("$base/everyday/recommend")) } ?: emptyList(),
            themes = safe { parseCoverList(get("$base/theme/playlist"), key = "theme") } ?: emptyList(),
            scenes = safe { parseSceneList(get("$base/scene/music")) } ?: emptyList(),
            playlists = safe { parseCoverList(get("$base/top/playlist?page=1"), key = "playlist") } ?: emptyList(),
            ranks = safe { parseCoverList(get("$base/rank/list?withsong=1"), key = "rank") } ?: emptyList(),
        )
    }

    private fun get(path: String): String {
        val conn = URL(path).openConnection() as HttpURLConnection
        return try {
            conn.requestMethod = "GET"
            conn.connectTimeout = 5000
            conn.readTimeout = 8000
            // 非 2xx 也读 body（errorStream），交由解析层容错，而不是直接抛异常
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }

    /** 取 JSONObject 下首个命中的子对象（data 容器多为 { data: {...} }）。 */
    private fun dataObject(root: JSONObject): JSONObject {
        val d = root.optJSONObject("data") ?: return root
        // scene 等接口 data 下再套一层 scene：继续下探一层有 list/info 的对象
        return if (d.has("list") || d.has("info")) d else d.optJSONObject("data") ?: d
    }

    private fun listOf(root: JSONObject, vararg keys: String): JSONArray {
        val obj = dataObject(root)
        for (k in keys) {
            obj.optJSONArray(k)?.let { return it }
            obj.optJSONObject(k)?.optJSONArray("list")?.let { return it }
        }
        return JSONArray()
    }

    // 每日推荐：/everyday/recommend → data.song_list|songs|list|info
    private fun parseSongList(raw: String): List<SongItem> {
        val root = JSONObject(raw)
        val arr = listOf(root, "song_list", "songs", "list", "info")
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val name = o.optString("songname").ifEmpty { o.optString("name") }
                val artist = o.optString("singername").ifEmpty { o.optString("author_name") }
                // Hero 大卡需要封面：取常见封面字段，并把 {size} 占位符替换为具体尺寸
                // （与 Dart 端 _resolveArtworkUri 行为一致，否则 URL 含 {size} 无法加载）
                val cover = o.optString("imgurl")
                    .ifEmpty { o.optString("album_img") }
                    .ifEmpty { o.optString("albumpic") }
                    .ifEmpty { o.optString("img") }
                    .ifEmpty { o.optString("pic") }
                    .ifEmpty { o.optJSONObject("trans_param")?.optString("union_cover").orEmpty() }
                    .replace("{size}", "400")
                    .takeIf { it.isNotEmpty() }
                if (name.isNotEmpty()) add(SongItem(name, artist, cover))
            }
        }.take(5)
    }

    // 主题歌单 / 热门歌单 / 排行榜：name + cover + count
    private fun parseCoverList(raw: String, key: String): List<CoverItem> {
        val root = JSONObject(raw)
        val arr = when (key) {
            "theme" -> listOf(root, "list", "info")
            "playlist" -> listOf(root, "special_list", "plist", "list")
            else -> listOf(root, "info", "list", "ranks")
        }
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val name = o.optString("name")
                    .ifEmpty { o.optString("specialname") }
                    .ifEmpty { o.optString("rankname") }
                    .ifEmpty { o.optString("theme_name") }
                val cover = o.optString("imgurl")
                    .ifEmpty { o.optString("img") }
                    .ifEmpty { o.optString("cover") }
                    .ifEmpty { o.optString("sizable_cover") }
                    .ifEmpty { o.optString("bannerurl") }
                    .ifEmpty { o.optString("img_9") }
                    .ifEmpty { o.optJSONObject("trans_param")?.optString("union_cover").orEmpty() }
                    .replace("{size}", "400")
                    .takeIf { it.isNotEmpty() }
                val count = o.optInt("songcount", 0).takeIf { it > 0 } ?: o.optInt("song_count", 0)
                if (name.isNotEmpty()) add(CoverItem(name, cover, count))
            }
        }
    }

    // 场景音乐：/scene/music → data.list|info，每项 name
    private fun parseSceneList(raw: String): List<SceneItem> {
        val root = JSONObject(raw)
        val arr = listOf(root, "list", "info")
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val name = o.optString("name")
                if (name.isNotEmpty()) add(SceneItem(name))
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 手绘 MIUI 风细线图标（24x24 viewport，填充式路径）
// ─────────────────────────────────────────────────────────────────────────────

private object AppIcon {
    /** 返回（左箭头） */
    val Back: ImageVector by lazy {
        icon("Back") {
            moveTo(15.41f, 7.41f)
            lineTo(14f, 6f)
            lineTo(8f, 12f)
            lineTo(14f, 18f)
            lineTo(15.41f, 16.59f)
            lineTo(10.83f, 12f)
            close()
        }
    }

    /** 播放 */
    val Play: ImageVector by lazy {
        icon("Play") {
            moveTo(8f, 5f)
            verticalLineTo(19f)
            lineTo(19f, 12f)
            close()
        }
    }

    /** 音乐音符 */
    val Music: ImageVector by lazy {
        icon("Music") {
            moveTo(12f, 3f)
            verticalLineTo(13.55f)
            curveTo(11.41f, 13.21f, 10.73f, 13f, 10f, 13f)
            curveTo(7.79f, 13f, 6f, 14.79f, 6f, 17f)
            reflectiveCurveTo(7.79f, 21f, 10f, 21f)
            reflectiveCurveTo(14f, 19.21f, 14f, 17f)
            verticalLineTo(7f)
            horizontalLineTo(18f)
            verticalLineTo(3f)
            horizontalLineTo(12f)
            close()
        }
    }

    /** 耳机（场景音乐） */
    val Headphones: ImageVector by lazy {
        icon("Headphones") {
            moveTo(12f, 3f)
            curveTo(7.03f, 3f, 3f, 7.03f, 3f, 12f)
            curveTo(3f, 13.1f, 3.9f, 14f, 5f, 14f)
            horizontalLineTo(9f)
            verticalLineTo(6f)
            horizontalLineTo(5f)
            verticalLineTo(5f)
            curveTo(5f, 1.13f, 8.13f, -2f, 12f, -2f)
            reflectiveCurveTo(19f, 1.13f, 19f, 5f)
            verticalLineTo(6f)
            horizontalLineTo(15f)
            verticalLineTo(14f)
            horizontalLineTo(19f)
            curveTo(20.1f, 14f, 21f, 13.1f, 21f, 12f)
            curveTo(21f, 7.03f, 16.97f, 3f, 12f, 3f)
            close()
        }
    }

    /** 歌单 */
    val Playlist: ImageVector by lazy {
        icon("Playlist") {
            moveTo(15f, 6f)
            horizontalLineTo(3f)
            verticalLineTo(8f)
            horizontalLineTo(15f)
            verticalLineTo(6f)
            close()
            moveTo(15f, 10f)
            horizontalLineTo(3f)
            verticalLineTo(12f)
            horizontalLineTo(15f)
            verticalLineTo(10f)
            close()
            moveTo(3f, 16f)
            horizontalLineTo(11f)
            verticalLineTo(14f)
            horizontalLineTo(3f)
            verticalLineTo(16f)
            close()
            moveTo(17f, 6f)
            verticalLineTo(14.18f)
            curveTo(16.69f, 14.07f, 16.35f, 14f, 16f, 14f)
            curveTo(14.34f, 14f, 13f, 15.34f, 13f, 17f)
            reflectiveCurveTo(14.34f, 20f, 16f, 20f)
            reflectiveCurveTo(19f, 18.66f, 19f, 17f)
            verticalLineTo(8f)
            horizontalLineTo(22f)
            verticalLineTo(6f)
            horizontalLineTo(17f)
            close()
        }
    }

    /** 刷新（错误重试） */
    val Refresh: ImageVector by lazy {
        icon("Refresh") {
            moveTo(17.65f, 6.35f)
            curveTo(16.2f, 4.9f, 14.21f, 4f, 12f, 4f)
            curveTo(7.58f, 4f, 4.01f, 7.58f, 4.01f, 12f)
            reflectiveCurveTo(4.01f, 20f, 12f, 20f)
            curveTo(15.73f, 20f, 18.84f, 17.45f, 19.73f, 14f)
            verticalLineTo(12f)
            curveTo(16.83f, 14.33f, 14.61f, 16f, 12f, 16f)
            curveTo(8.69f, 16f, 6f, 13.31f, 6f, 10f)
            reflectiveCurveTo(8.69f, 4f, 12f, 4f)
            curveTo(13.66f, 4f, 15.14f, 4.69f, 16.22f, 5.78f)
            lineTo(13f, 11f)
            horizontalLineTo(20f)
            verticalLineTo(4f)
            lineTo(17.65f, 6.35f)
            close()
        }
    }

    /** 信息（错误提示） */
    val Info: ImageVector by lazy {
        icon("Info") {
            moveTo(11f, 7f)
            horizontalLineTo(13f)
            verticalLineTo(9f)
            horizontalLineTo(11f)
            close()
            moveTo(11f, 11f)
            horizontalLineTo(13f)
            verticalLineTo(17f)
            horizontalLineTo(11f)
            close()
            moveTo(12f, 2f)
            curveTo(6.48f, 2f, 2f, 6.48f, 2f, 12f)
            reflectiveCurveTo(6.48f, 22f, 12f, 22f)
            reflectiveCurveTo(22f, 17.52f, 22f, 12f)
            reflectiveCurveTo(17.52f, 2f, 12f, 2f)
            close()
            moveTo(12f, 20f)
            curveTo(7.59f, 20f, 4f, 16.41f, 4f, 12f)
            reflectiveCurveTo(7.59f, 4f, 12f, 4f)
            reflectiveCurveTo(20f, 7.59f, 20f, 12f)
            reflectiveCurveTo(16.41f, 20f, 12f, 20f)
            close()
        }
    }

    private fun icon(name: String, block: PathBuilder.() -> Unit): ImageVector =
        ImageVector.Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(fill = SolidColor(Color.Black), pathBuilder = block)
        }.build()
}

// ─────────────────────────────────────────────────────────────────────────────
// 页面
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun MiuixDiscoverScreen(port: Int, onBack: () -> Unit) {
    var state by remember { mutableStateOf<DiscoverUiState>(DiscoverUiState.Loading) }
    // 重试计数：失败后点击重试重新拉取
    var reloadKey by remember { mutableStateOf(0) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    // 测试页不接入播放器：所有内容点击统一给出轻提示
    val notify: (String) -> Unit = { msg ->
        scope.launch { snackbarHostState.showSnackbar(msg) }
    }

    LaunchedEffect(port, reloadKey) {
        state = DiscoverUiState.Loading
        state = try {
            DiscoverUiState.Success(DiscoverRepository.load(port))
        } catch (e: Exception) {
            // 显示异常类名 + 消息，便于定位（如 UnknownServiceException 明文拦截、
            // ConnectException 连不上、JSONException 结构不符等）
            DiscoverUiState.Error("${e::class.simpleName}: ${e.message}")
        }
    }

    val controller = remember { ThemeController(ColorSchemeMode.System) }
    MiuixTheme(controller = controller) {
        Scaffold(
            snackbarHost = { SnackbarHost(state = snackbarHostState) },
            topBar = {
                TopAppBar(
                    title = "发现",
                    largeTitle = "发现",
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(
                                AppIcon.Back,
                                contentDescription = "返回",
                                modifier = Modifier.size(22.dp),
                            )
                        }
                    },
                )
            },
        ) { innerPadding ->
            when (val s = state) {
                is DiscoverUiState.Loading -> Box(
                    modifier = Modifier.fillMaxSize().padding(innerPadding),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(size = 30.dp)
                }

                is DiscoverUiState.Error -> Box(
                    modifier = Modifier.fillMaxSize().padding(innerPadding),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 36.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(
                            AppIcon.Info,
                            contentDescription = null,
                            modifier = Modifier.size(56.dp),
                            tint = MiuixTheme.colorScheme.onBackgroundVariant,
                        )
                        Spacer(Modifier.height(14.dp))
                        Text(
                            "加载失败",
                            style = MiuixTheme.textStyles.title4,
                            color = MiuixTheme.colorScheme.onBackground,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "本地接口端口 $port，请确认 App 在线音乐已启用",
                            style = MiuixTheme.textStyles.footnote1,
                            color = MiuixTheme.colorScheme.onBackgroundVariant,
                            textAlign = TextAlign.Center,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            s.message,
                            style = MiuixTheme.textStyles.footnote2,
                            color = MiuixTheme.colorScheme.onBackgroundVariant,
                            textAlign = TextAlign.Center,
                        )
                        Spacer(Modifier.height(18.dp))
                        Button(
                            onClick = { reloadKey++ },
                            colors = ButtonDefaults.buttonColorsPrimary(),
                        ) {
                            Icon(
                                AppIcon.Refresh,
                                contentDescription = null,
                                tint = MiuixTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                "重试",
                                style = MiuixTheme.textStyles.button,
                                color = MiuixTheme.colorScheme.onPrimary,
                            )
                        }
                    }
                }

                is DiscoverUiState.Success -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        top = innerPadding.calculateTopPadding(),
                        // 底部补上系统导航栏 inset + 额外留白，避免内容被导航栏遮挡
                        bottom = innerPadding.calculateBottomPadding() + 36.dp,
                    ),
                ) {
                    item(key = "hero") {
                        HeroCard(
                            songs = s.data.songs,
                            onPlayAll = { notify("测试页：暂未接入播放器，无法播放全部") },
                        )
                    }
                    if (s.data.songs.isNotEmpty()) {
                        item(key = "dailyTitle") { SectionHeader("每日推荐") }
                        // miuix 克制列表：纯文本歌曲行，无需 Card 容器
                        items(s.data.songs.size) { i ->
                            SongRow(
                                index = i,
                                song = s.data.songs[i],
                                onClick = { notify("测试页：暂未接入播放器") },
                            )
                        }
                    }
                    if (s.data.themes.isNotEmpty()) {
                        item(key = "themeTitle") { SectionHeader("主题歌单") }
                        item(key = "theme") {
                            CoverRow(
                                items = s.data.themes,
                                onClick = { notify("测试页：暂未接入播放器") },
                            )
                        }
                    }
                    if (s.data.scenes.isNotEmpty()) {
                        item(key = "sceneTitle") { SectionHeader("场景音乐") }
                        item(key = "scene") {
                            LazyRow(
                                contentPadding = PaddingValues(horizontal = 16.dp),
                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                items(s.data.scenes.size) { i ->
                                    SceneTile(s.data.scenes[i].name)
                                }
                            }
                        }
                    }
                    if (s.data.playlists.isNotEmpty()) {
                        item(key = "playlistTitle") { SectionHeader("热门歌单") }
                        item(key = "playlist") {
                            CoverRow(
                                items = s.data.playlists,
                                onClick = { notify("测试页：暂未接入播放器") },
                            )
                        }
                    }
                    if (s.data.ranks.isNotEmpty()) {
                        item(key = "rankTitle") { SectionHeader("排行榜") }
                        item(key = "rank") {
                            LazyRow(
                                contentPadding = PaddingValues(horizontal = 16.dp),
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                items(s.data.ranks.size) { i ->
                                    CoverCard(
                                        item = s.data.ranks[i],
                                        badge = "${i + 1}",
                                        onClick = { notify("测试页：暂未接入播放器") },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 区块组件（HyperOS 音乐页风）
// ─────────────────────────────────────────────────────────────────────────────

/** 分区标题：与内容卡片 16dp 水平边距对齐，整体更整洁（替代默认 28dp 内缩）。 */
@Composable
private fun SectionHeader(text: String) {
    SmallTitle(
        text = text,
        insideMargin = PaddingValues(start = 16.dp, top = 8.dp),
    )
}

/**
 * 顶部「每日推荐」Hero 大卡：squircle 24dp 连续圆角。
 * 背景优先取每日推荐首曲封面 + 底部渐变遮罩，无封面时回退为柔和渐变；
 * 文字统一白色，保证深浅色主题下均可读。
 */
@Composable
private fun HeroCard(songs: List<SongItem>, onPlayAll: () -> Unit) {
    val greeting = when (Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) {
        in 0..5 -> "夜深了"
        in 6..11 -> "早上好"
        in 12..13 -> "中午好"
        in 14..17 -> "下午好"
        else -> "晚上好"
    }
    val cover = songs.firstOrNull()?.cover
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            // 用最小高度而非固定高度：内容（问候语换行/按钮）撑高时不裁切文字
            .heightIn(min = 180.dp)
            .clip(miuixShape(24.dp)),
    ) {
        // 底层：柔和渐变背景（fallback），始终存在——封面缺失/加载失败时颜色仍在
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            MiuixTheme.colorScheme.primaryContainer,
                            MiuixTheme.colorScheme.secondaryContainerVariant,
                        ),
                    ),
                ),
        )
        // 封面层：有则覆盖（加载失败时保持透明，露出底层渐变）
        if (!cover.isNullOrEmpty()) {
            AsyncImage(
                model = cover,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
        // 底部浅色遮罩：压暗保证文字可读（调浅，避免盖死背景色）
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colorStops = arrayOf(
                            0f to Color.Transparent,
                            0.6f to Color.Black.copy(alpha = 0.08f),
                            1f to Color.Black.copy(alpha = 0.5f),
                        ),
                    ),
                ),
        )
        Column(
            modifier = Modifier.align(Alignment.BottomStart).padding(20.dp),
        ) {
            Text(
                greeting,
                style = MiuixTheme.textStyles.title1,
                color = Color.White,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "发现你喜欢的音乐 · 每日推荐已更新",
                style = MiuixTheme.textStyles.footnote1,
                color = Color.White.copy(alpha = 0.85f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(14.dp))
            Button(
                onClick = onPlayAll,
                colors = ButtonDefaults.buttonColorsPrimary(),
                // 不强制高度：让 miuix Button 用默认高度，避免文本被固定高度裁切
            ) {
                Icon(
                    AppIcon.Play,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "播放全部 · ${songs.size} 首",
                    style = MiuixTheme.textStyles.footnote1,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** 横向封面卡片：squircle 16dp 封面 + 可选角标 + 名称 + 曲数。 */
@Composable
private fun CoverCard(item: CoverItem, badge: String? = null, onClick: () -> Unit = {}) {
    val shape = miuixShape(16.dp)
    Column(modifier = Modifier.width(112.dp)) {
        Box(
            modifier = Modifier
                .size(112.dp)
                .clip(shape)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            // 底层占位：封面缺失/加载失败时保持渐变+音符，不空白
            CoverPlaceholder()
            if (!item.cover.isNullOrEmpty()) {
                AsyncImage(
                    model = item.cover,
                    contentDescription = item.name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            badge?.let {
                Text(
                    text = it,
                    style = MiuixTheme.textStyles.subtitle,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(6.dp)
                        .background(Color.Black.copy(alpha = 0.35f), miuixShape(8.dp))
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            item.name,
            style = MiuixTheme.textStyles.body2,
            color = MiuixTheme.colorScheme.onSurfaceContainer,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (item.count > 0) {
            Text(
                "${item.count} 首",
                style = MiuixTheme.textStyles.footnote2,
                color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
            )
        }
    }
}

/** 通用横向封面行（主题歌单 / 热门歌单）。 */
@Composable
private fun CoverRow(items: List<CoverItem>, onClick: () -> Unit) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(items.size) { i ->
            CoverCard(item = items[i], onClick = onClick)
        }
    }
}

/** 场景音乐磁贴：squircle 图标块 + 名称。 */
@Composable
private fun SceneTile(name: String) {
    Column(
        modifier = Modifier.width(76.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(54.dp)
                .clip(miuixShape(18.dp))
                .background(MiuixTheme.colorScheme.tertiaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                AppIcon.Headphones,
                contentDescription = null,
                tint = MiuixTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp),
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            name,
            style = MiuixTheme.textStyles.footnote1,
            color = MiuixTheme.colorScheme.onSurfaceContainer,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

/** 歌曲行：序号（primary 点缀）+ 歌名 + 歌手，纯文本无彩色容器，符合 miuix 克制美学。 */
@Composable
private fun SongRow(index: Int, song: SongItem, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${index + 1}",
            style = MiuixTheme.textStyles.title4,
            color = MiuixTheme.colorScheme.primary,
            modifier = Modifier.width(24.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                song.name,
                style = MiuixTheme.textStyles.body2,
                color = MiuixTheme.colorScheme.onSurfaceContainer,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (song.artist.isNotEmpty()) {
                Text(
                    song.artist,
                    style = MiuixTheme.textStyles.footnote2,
                    color = MiuixTheme.colorScheme.onSurfaceContainerVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

/** 封面占位：柔和渐变 + 音乐音符图标。 */
@Composable
private fun CoverPlaceholder() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        MiuixTheme.colorScheme.tertiaryContainer,
                        MiuixTheme.colorScheme.secondaryContainer,
                    ),
                ),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            AppIcon.Music,
            contentDescription = null,
            tint = MiuixTheme.colorScheme.primary,
            modifier = Modifier.size(28.dp),
        )
    }
}
