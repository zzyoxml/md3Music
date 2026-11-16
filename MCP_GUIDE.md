# MD3Music AI 代理接口（MCP）使用指南

> 适用版本：MD3Music 5.7.0+（内置 MCP Server；v1 落地于 2026-09-27，v2 能力扩展于 2026-10-03）
> 配套实施计划：`docs/superpowers/plans/2026-09-27-mcp-agent-bridge.md`（v1）、
> `docs/superpowers/plans/2026-10-03-mcp-capability-expansion.md`（v2，44 个工具 + resources/prompts/会话）

---

## 1. 这是什么

MD3Music 内置了一个 **MCP（Model Context Protocol）服务端**。开启后，任何支持 MCP 的 AI 客户端
（Claude Desktop / Claude Code / Cursor / Cherry Studio 等）都能以**语义级工具**直接操作你的播放器：
搜歌、读播放状态、取歌词、播放/暂停/切歌/跳转/调音量。

它不是"截图 + 模拟点击"的 UI 自动化，而是 App 直接暴露的结构化接口——延迟低、结果准确、token 消耗小。

**三个关键特性：**

| 特性 | 说明 |
|------|------|
| 跑在 App 进程内 | 服务随 App 启动而可用，不需要电脑端常驻进程、不需要 root |
| 默认关闭 | 安装后默认**不监听任何端口**，必须你在设置里显式开启 |
| 默认只绑回环 | 未开启局域网访问时只监听 `127.0.0.1`，同一 WiFi 下的其他设备连不上 |

**架构一句话**：Flutter（Dart）侧起一个 `HttpServer`，固定端口 **17888**，单端点 `/mcp`
（`POST` 走 Streamable HTTP 的 JSON 响应模式；`initialize` 建立会话并下发 `Mcp-Session-Id`，
客户端可带该头用 `GET /mcp` 打开 SSE 下行接收服务端通知）。协议能力覆盖 **tools / resources /
prompts** 三类。检索类工具复用 App 已有的本地 Rust 服务器 → 酷狗上游；播放控制类工具直接驱动
`PlayerProvider`；App 功能类工具驱动均衡器 / 桌面歌词等单例服务。

> **端到端实测基线（2026-10-03 扩展后）**：tools/list 返回 44 个工具；新增
> `resources/list`（3 个内置资源）、`prompts/list`（3 个模板）、会话 SSE 下行
> （`notifications/tools/list_changed`）。写操作默认需 App 内二次确认（30s 超时视为拒绝）。

> **端到端已实测（2026-09-27 真机）**：initialize 0.11s / tools/list 13 个工具 /
> tools/call 0.04s 返回真实播放状态；无令牌访问返回 401 带信封错误体。

---

## 2. 三分钟上手

### 第 1 步：手机上开启

`设置 → 应用与管理 → AI 代理` → 打开 **启用 MCP 服务**。

开启后页面会展开三段：

- **访问控制**：只读模式、允许局域网访问
- **连接**：监听端口、连接地址、访问令牌
- **状态**：服务状态、最近调用记录

记下页面上的 **连接地址**，形如 `http://127.0.0.1:17888/mcp`。

> ⚠️ 端口可能被占用而自动顺延到 17889–17892，**以页面显示为准**，不要照抄本文的 17888。

### 第 2 步：让 AI 客户端能连到手机（三选一）

| 方式 | 适用 | 做法 | 要令牌 |
|------|------|------|--------|
| **USB + adb forward**（推荐） | 手机插着 USB 线 | `adb forward tcp:17888 tcp:17888`，客户端填 `http://127.0.0.1:17888/mcp` | 否 |
| **局域网直连**（无线推荐） | 手机与电脑同一 WiFi | 开「允许局域网访问」，客户端填页面显示的 `http://<手机IP>:17888/mcp` | **是** |
| **stdio 桥接** | 只认 stdio 的旧客户端 | 用 `scripts/tools/mcp_stdio_bridge.py` 转发 | 回环否/局域网要 |

> ⚠️ **实测重要限制（2026-09-27，USB 与无线均验证）**：`adb reverse` **只有规则能建立，数据路径不通**——
> 连接约 2 秒后被静默断开，客户端表现为"超时"。请一律改用 **`adb forward`**（实测 0.02s 即通）：
>
> ```bash
> adb forward tcp:17888 tcp:17888    # 客户端填 http://127.0.0.1:17888/mcp
> ```
> 手机是无线调试时，请直接用**局域网直连**。

### 第 3 步：配置 AI 客户端

**Claude Code（命令行）**

```bash
# USB 方式：
claude mcp add --transport http md3music http://127.0.0.1:17888/mcp

# 局域网方式（URL 换成设置页显示的地址）：
claude mcp add --transport http md3music http://192.168.x.x:17888/mcp \
  --header "Authorization: Bearer <访问令牌>"
```

**Claude Desktop / Cursor / 其它支持 HTTP 的客户端**（`mcp.json`）

```json
{
  "mcpServers": {
    "md3music": {
      "type": "http",
      "url": "http://127.0.0.1:17888/mcp",
      "headers": { "Authorization": "Bearer <访问令牌>" }
    }
  }
}
```

（`headers` 字段客户端不一定都支持；不支持时用下面的桥接脚本。）

**只支持 stdio 的旧客户端**——用仓库自带的桥接脚本：

```json
{
  "mcpServers": {
    "md3music": {
      "command": "python",
      "args": ["<仓库路径>/scripts/tools/mcp_stdio_bridge.py", "http://<地址>:17888/mcp"],
      "env": { "MD3MCP_TOKEN": "<设置页里的访问令牌>" }
    }
  }
}
```

配好后对 AI 说一句「现在在放什么歌」或「搜一下周杰伦的晴天并播放」，即可验证。

---

## 3. 局域网模式详解

开启「允许局域网访问」后：

1. 服务改绑 `0.0.0.0:17888`，同一 WiFi 下的设备都能访问
2. **强制校验令牌**：请求头必须带 `Authorization: Bearer <令牌>`，否则 401
   （401 响应体是带信封的 JSON-RPC 错误：`{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Unauthorized"}}`）
3. 手机 IP 可能随 DHCP 变化，以设置页「连接地址」实时显示为准
4. 验证连通（电脑上执行）：

```bash
curl -s -m 10 http://<手机IP>:17888/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer <令牌>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

返回 `serverInfo.name = "MD3Music"` 即为打通。

---

## 4. 功能总览：44 个工具 + Resources + Prompts

工具按**分组**组织，设置页可逐组开关（关掉的组既不出现在 `tools/list`，调用也会被拒）。
下表为全部开启时的完整清单。

### 4.1 `player` — 播放与队列控制（18 个）

| 工具 | 类型 | 作用 |
|------|------|------|
| `md3_get_player_state` | 读 | 当前曲目（含 `hash`/`quality`）、播放态、进度、音量、循环/随机、队列长度与索引 |
| `md3_get_queue` | 读 | 当前播放队列（含当前索引） |
| `md3_resume` / `md3_pause` / `md3_toggle` | 写 | 继续 / 暂停 / 二合一切换 |
| `md3_next` / `md3_previous` | 写 | 下一首 / 上一首 |
| `md3_seek` | 写 | 跳转到指定位置 |
| `md3_skip` | 写 | 基于当前进度快进/快退 N 秒（结果钳制在曲目范围内） |
| `md3_set_volume` / `md3_adjust_volume` | 写 | 绝对设音量 / 相对增减（-1.0~1.0，自动钳制） |
| `md3_set_loop_mode` / `md3_set_shuffle` | 写 | 设循环模式（off/one/all）/ 设随机播放 |
| `md3_play_song` / `md3_play_keyword` / `md3_enqueue_song` | 写 | 按 hash 播放 / 搜关键词播放 / 插入到当前曲目之后 |
| `md3_play_queue_index` / `md3_remove_queue_item` / `md3_move_queue_item` | 写 | 队列跳转 / 移除 / 调整顺序 |
| `md3_clear_queue` | 写 | 清空队列并停止（**需二次确认**，不可恢复） |
| `md3_wait_for_player_event` | 读 | 阻塞等待切歌/开始播放/暂停（长轮询，≤55s） |

### 4.2 `discovery` — 检索与发现（17 个）

| 工具 | 类型 | 作用 |
|------|------|------|
| `md3_search_songs` / `md3_search_albums` / `md3_search_artists` / `md3_search_playlists` | 读 | 四维搜索；歌单结果含 `list_id`（加歌入参）与 `global_collection_id` |
| `md3_get_song_detail` | 读 | 按 hash 取完整详情 |
| `md3_get_lyric` | 读 | 按 hash 取 LRC 歌词明文（≤8000 字符） |
| `md3_get_playlist_songs` / `md3_play_playlist` | 读/写 | 读歌单内容 / 整单播放（前 30 首） |
| `md3_get_daily_recommend` / `md3_play_daily_recommend` | 读/写 | 每日推荐读取 / 一键播放 |
| `md3_play_personal_fm` | 写 | 私人 FM 一轮并播放 |
| `md3_get_toplist` / `md3_play_rank` | 读/写 | 榜单列表 / 播放指定榜单 |
| `md3_get_listen_history` | 读 | 听歌列表（结构未文档化，识别不了时返回截断原文） |
| `md3_search_local_songs` / `md3_play_local_song` | 读/写 | 本地曲库搜索 / 按 id 播放本地歌曲 |

### 4.3 `library_write` — 曲库修改（2 个）

| 工具 | 类型 | 作用 |
|------|------|------|
| `md3_add_song_to_playlist` | 写 | 把歌曲加入指定歌单（**需二次确认**） |
| `md3_create_playlist` | 写 | 创建新歌单（**需二次确认**） |

> **为什么没有"收藏歌曲"工具**：经上游复核，酷狗开放接口**不存在单曲收藏写端点**
> （只有收藏数查询），故不做一个必然失败的工具。收藏/取消收藏请在 App 内操作。

### 4.4 `app_features` — 应用功能（5 个）

| 工具 | 类型 | 作用 |
|------|------|------|
| `md3_get_app_features` | 读 | 睡眠定时 / 均衡器（含预设列表）/ 桌面歌词 / 输出模式（**只读**） |
| `md3_set_sleep_timer` | 写 | 设置 N 分钟后自动暂停（0 = 取消） |
| `md3_set_eq_enabled` / `md3_apply_eq_preset` | 写 | 均衡器开关 / 切预设（**需二次确认**） |
| `md3_set_desktop_lyric` | 写 | 桌面歌词开关（**需二次确认**） |

> **输出模式为什么不提供切换**：`usbdevfs` 直写 / `direct_pcm` / 系统默认三档切换会
> 中断正在播放的音频（见 AGENTS §4.11 的切换代价），因此只允许 AI **读**，切换留给用户。

开启**只读模式**后只剩 17 个非 mutating 工具（状态、队列、四类搜索、详情、歌词、歌单内容、
每日推荐、榜单、听歌历史、本地搜索、App 功能查询、事件等待）。

---

## 5. 工具详解

### 读工具

**`md3_get_player_state`** — 无参数

```json
{
  "title": "晴天", "artist": "周杰伦", "album": "叶惠美",
  "playing": true, "position_ms": 42000, "duration_ms": 269000,
  "volume": 0.8, "loop_mode": "all", "shuffle": false,
  "queue_length": 12, "current_index": 3
}
```

- 无曲目时各字段为空、`playing=false`、`current_index=-1`
- `position_ms` / `playing` 取的是**平台真实值**（非乐观缓存），可作为判断依据
- `loop_mode` 取值：`off`（不循环）/ `one`（单曲循环）/ `all`（列表循环）

**`md3_get_queue`** — `limit`（1–50，默认 20）

返回 `{current_index, total, items:[{index,title,artist,album}]}`，从当前曲目开始截取。

**`md3_search_songs`** — `keyword`（必填）、`limit`（1–30，默认 10）

```json
{ "keyword": "晴天", "count": 3,
  "items": [ { "hash": "A1B2C3...", "name": "晴天", "artist": "周杰伦",
               "album": "叶惠美", "duration_ms": 269000 } ] }
```

> 结果已做字段投影（只保留 5 个字段），避免每轮对话吃掉大量 token。
> 返回的 `hash` 是后续 `md3_play_song` / `md3_enqueue_song` / `md3_get_lyric` 的入参。

**`md3_get_lyric`** — `hash`（必填）

返回 LRC 明文（带时间轴），最长 8000 字符，超出会截断并在 `truncated` 字段标出。

### 写工具

| 工具 | 参数 | 约束 |
|------|------|------|
| `md3_resume` / `md3_pause` / `md3_next` / `md3_previous` | 无 | `resume` 在没有任何曲目时返回错误 |
| `md3_seek` | `position_ms` | 绝对毫秒，`>= 0` |
| `md3_set_volume` | `volume` | `0.0`–`1.0` |
| `md3_play_song` | `hash` | 取自搜索结果 |
| `md3_play_keyword` | `keyword` | 等价于"先搜后播第一条" |
| `md3_enqueue_song` | `hash` | 插入当前曲目之后 |

参数非法（越界、类型错、缺失）会返回带中文原因的错误，例如
`参数错误：参数 "volume" 不能大于 1.0`，AI 通常能据此自我纠正。

### 5.1 v2 新增工具参数速查

| 工具 | 参数 | 约束 / 说明 |
|------|------|------|
| `md3_toggle` | 无 | 播放中→暂停，暂停中→继续 |
| `md3_set_loop_mode` | `mode` | `off` / `one` / `all` |
| `md3_set_shuffle` | `enabled` | 布尔 |
| `md3_adjust_volume` | `delta` | -1.0~1.0，超界值收敛到 0/1 边界 |
| `md3_skip` | `seconds` | -3600~3600，基于当前进度偏移 |
| `md3_play_queue_index` | `index` | 0 起，越界报错 |
| `md3_remove_queue_item` | `index` | 0 起；队列空时报错 |
| `md3_move_queue_item` | `from`、`to` | 均 0 起且在队列范围内 |
| `md3_clear_queue` | 无 | 需二次确认 |
| `md3_wait_for_player_event` | `event`、`timeout_ms` | `event` ∈ `track_change`/`play`/`pause`；`timeout_ms` 1000~55000（默认 30000）；超时返回 `timed_out: true` |
| `md3_search_albums` | `keyword`、`limit` | limit 1~20 |
| `md3_search_artists` / `md3_search_playlists` | `keyword`、`limit` | limit 1~20；歌单结果含 `list_id` / `global_collection_id` |
| `md3_get_song_detail` | `hash` | — |
| `md3_get_playlist_songs` | `global_collection_id`、`limit` | limit 1~30 |
| `md3_play_playlist` | `global_collection_id` | 取前 30 首整单播放，立即返回 |
| `md3_get_daily_recommend` / `md3_play_daily_recommend` | 无 | 需登录；整单播放立即返回 |
| `md3_play_personal_fm` | 无 | 需登录；取一轮 FM 立即播放 |
| `md3_get_toplist` | `limit` | 1~30（默认 20） |
| `md3_play_rank` | `rank_id`、`limit` | limit 1~30 |
| `md3_get_listen_history` | `limit` | 1~30（默认 10） |
| `md3_search_local_songs` | `keyword`、`limit` | limit 1~30 |
| `md3_play_local_song` | `id` | 来自 `md3_search_local_songs` |
| `md3_add_song_to_playlist` | `hash`、`listid` | 需二次确认；歌单需登录后可见 |
| `md3_create_playlist` | `name` | 需二次确认 |
| `md3_get_app_features` | 无 | 只读快照 |
| `md3_set_sleep_timer` | `minutes` | 1~480；0 = 取消 |
| `md3_set_eq_enabled` | `enabled` | 需二次确认 |
| `md3_apply_eq_preset` | `name` | 预设名取自 `md3_get_app_features` 的 `eq.presets`；需二次确认 |
| `md3_set_desktop_lyric` | `enabled` | 需二次确认 |

### 5.2 Resources 与 Prompts

- **Resources**（`resources/list` / `resources/read`）：`md3://player/state`（播放器状态 JSON）、
  `md3://player/queue`（队列 JSON）、`md3://player/lyric`（当前在线曲目歌词纯文本）。
- **Prompts**（`prompts/list` / `prompts/get`）：`sleep_assistant`（参数 `minutes`）、
  `now_playing_qa`、`queue_curator`（参数 `theme`）。客户端可在会话中一键选用。

---

## 6. 典型对话示例

| 你说 | AI 会调 |
|------|---------|
| 「现在在放什么」 | `md3_get_player_state` |
| 「帮我搜一下周杰伦的晴天」 | `md3_search_songs` |
| 「播放周杰伦的晴天」 | `md3_play_keyword`（或先搜再 `md3_play_song`） |
| 「暂停一下 / 下一首 / 声音小一点」 | `md3_pause` / `md3_next` / `md3_set_volume` |
| 「跳到 1 分 30 秒」 | `md3_seek`（`position_ms: 90000`） |
| 「把这首歌加到下一首播」 | 先 `md3_search_songs` 拿 hash → `md3_enqueue_song` |
| 「这首歌的歌词是什么」 | 先拿 hash → `md3_get_lyric` |
| 「接下来 30 分钟随机放点轻音乐，别让我操作」 | 组合调用（需关闭只读模式） |

---

## 7. 安全模型

五重闸门，逐层收紧：

| 闸门 | 默认 | 作用 |
|------|------|------|
| **总开关**（启用 MCP 服务） | **关** | 关闭时完全不监听端口，零攻击面 |
| **绑定范围**（允许局域网访问） | **关**（仅回环） | 关闭时只有本机/USB 转发能连；开启后强制校验令牌 |
| **只读模式** | 关 | 开启后只暴露 17 个非写工具，AI 无法改变播放状态 |
| **写操作二次确认** | **开** | 高风险工具（清空队列、加歌单、建歌单、均衡器、桌面歌词）执行前在手机上弹窗；**30s 超时视为拒绝**，且同一时刻只允许一个挂起请求 |
| **工具分组开关** | 全开 | 可单独关闭「播放与队列 / 检索与发现 / 曲库修改 / 应用功能」任一组 |

其它安全设计：

- **令牌**：首次启用时自动生成（32 随机字节 → base64url，43 字符），可在设置页一键重置；
  **存于 `flutter_secure_storage` 加密存储**（v1 为 SharedPreferences 明文，升级后首次读取自动
  搬移并清除旧明文），可随时重置；重置后旧客户端需更新
- **无破坏性工具**：不提供清空曲库、删除文件、修改 App 设置等能力；输出模式只读不写
- **防抖**：同一写工具 400ms 内重复调用直接拒绝（挡掉客户端超时重试与多客户端打架）
- **单次调用无自动重试**：工具执行失败不会自动重试（遵循项目写操作约定）
- **调用可审计**：设置页「最近调用」显示最近 **50** 条（时间 / 工具名 / 成功与否 / **参数摘要**），
  可一键复制

**已知取舍**：关闭二次确认开关意味着接受"AI 可直接执行高风险写操作"（不再弹窗）；令牌加密后
已 root 设备或整机备份仍可读取。如需最高安全级别：只读模式 + 仅回环 + USB forward（不联网）。

---

## 8. 设置项参考

| 设置项 | 持久化 key | 默认值 | 说明 |
|--------|-----------|--------|------|
| 启用 MCP 服务 | `settings_mcp_enabled` | `false` | 总开关 |
| 监听端口 | `settings_mcp_port` | `17888` | 被占用时自动顺延至 +4 |
| 允许局域网访问 | `settings_mcp_bind_lan` | `false` | 开启后绑 `0.0.0.0` 并强制令牌鉴权 |
| 只读模式 | `settings_mcp_read_only` | `false` | 隐藏并拒绝全部写工具 |
| 写操作二次确认 | `settings_mcp_require_confirm` | `true` | 高风险写工具弹窗确认，30s 超时拒绝 |
| 工具组：播放与队列 | `settings_mcp_group_player` | `true` | 播放控制与队列工具 |
| 工具组：检索与发现 | `settings_mcp_group_discovery` | `true` | 搜索/歌词/歌单/榜单/推荐/历史/本地曲库 |
| 工具组：曲库修改 | `settings_mcp_group_library_write` | `true` | 加歌单、建歌单 |
| 工具组：应用功能 | `settings_mcp_group_app_features` | `true` | 睡眠定时、均衡器、桌面歌词、输出模式查询 |
| 访问令牌 | （`flutter_secure_storage`） | 首次生成 | 局域网模式必填；重置后需更新客户端 |

入口：`设置 → 应用与管理 → AI 代理`。

---

## 9. 常见问题 Q&A

**Q1：客户端报 connection refused / 连不上 / 超时？**
按序排查：① 设置页状态是否为「运行中」；② `adb shell "ss -ltn | grep 17888"` 确认设备在监听
（无输出 = 服务没起来）；③ 检查接入方式——**无线 ADB 下 `adb reverse` 不可用**（见 Q2），
无线时改局域网直连；④ 客户端 URL 的端口与 IP 是否与**页面显示**一致（端口可能被顺延、IP 可能变化）。

**Q2：`adb reverse` 为什么不通？手机用 WiFi 调试怎么办？**
**实测结论（2026-09-27，USB 与无线均验证）**：`adb reverse` 只有规则能建立，数据路径不通——
连接约 2 秒后被静默断开，客户端表现为超时。同机对照实验中 **`adb forward` 完全可用**（0.02s 即通）。
所以：PC 上的客户端一律用 `adb forward tcp:17888 tcp:17888` + `http://127.0.0.1:17888/mcp`；
forward 规则在 USB 断开后丢失，需重跑。

**Q3：端口 17888 被别的程序占了怎么办？**
服务端会自动尝试 17889–17892；全部失败时设置页显示「启动失败：端口 N 绑定失败」。
也可在设置页手动改成别的端口（1024–65535）。

**Q4：我的客户端只支持 stdio，不支持 HTTP？**
用 `scripts/tools/mcp_stdio_bridge.py`（Python 标准库实现，零依赖），配置见第 2 步第三种写法。

**Q5：能不能完全不连电脑？**
可以：开「允许局域网访问」，用同一 WiFi 下的另一台设备直连 `http://<手机IP>:<端口>/mcp`
（IP 在设置页「连接地址」里能看到），并带上令牌。手机上本机的客户端也可以直接连
`http://127.0.0.1:<端口>/mcp`（回环永远可用，无需令牌）。

**Q6：局域网模式一定要令牌吗？**
是的。开启局域网访问后服务端强制校验，没有 `Authorization: Bearer <令牌>` 一律 401。
回环/USB reverse 模式不需要令牌。

**Q7：令牌在哪看？忘了/想换？**
设置页「访问令牌」一行；点进去可重置。重置后所有已配置客户端都要更新令牌。

**Q8：App 划掉之后还能用吗？**
不能。服务活在 App 进程里，进程被系统回收或你主动划掉，端口就没了。
播放中因为有前台媒体服务，存活概率更高；长时间不用建议接受这个限制。

**Q9：点了播放但没反应？**
最常见原因是**未登录**：在线播放需要登录态，未登录时播放器会直接返回、不播。
其它可能：该曲目无版权/需要付费、音频链接解析失败、当前处于一起听房间受房主守卫限制。
可先调 `md3_get_player_state` 看状态，再让 AI 换一首试试。

**Q10：搜索返回空？**
确认关键词准确（可换更短的关键词）；部分内容受版权/地区限制不返回。
`md3_play_keyword` 在空结果时会直接返回"没有搜索到……匹配的歌曲"。

**Q11：歌词为空？**
该曲目在酷狗侧没有 LRC 歌词，或歌词接口未返回内容。工具会返回「未找到该歌曲的歌词」。

**Q12：只读模式开了会怎样？**
`tools/list` 只剩 17 个非写工具；强行调写工具会返回 `只读模式已开启，工具 xxx 被禁用`。
想让 AI 只做查询、不碰播放状态，就开它。

**Q13：为什么客户端只列出少量工具？**
多半开了只读模式，或某个工具分组被关掉。关掉对应开关即可恢复；分组关闭时调用会返回
`工具 xxx 所属分组未启用`。

**Q13b：AI 执行写操作时手机上弹出的框是什么？**
二次确认弹窗（标题形如「AI 请求执行「md3_clear_queue」」）。点「允许」继续、点「拒绝」或
30 秒不操作都会让工具返回"用户未确认该操作"。只想让 AI 查不动听，把「写操作二次确认」关掉即可。

**Q14：AI 会不会乱操作？**
写工具只覆盖播放控制（播放/暂停/切歌/跳转/音量/加队列），没有破坏性能力。
担心就开只读模式，或干脆用完即关总开关。

**Q15：暴露在局域网安全吗？**
有令牌校验，且是家庭/办公内网。但仍建议：只在需要时开启、用完关闭、定期重置令牌。
**不建议**配合内网穿透把 17888 暴露到公网（无 TLS、无限流、无访问频率限制）。

**Q16：能公网访问 / 穿透吗？**
官方不支持也不建议。服务端无 TLS、无频率限制，公网暴露风险不可控。

**Q17：耗电吗？**
服务是被动监听，无轮询、无常驻计算，空闲开销可忽略。真正的耗电来自 AI 触发的实际播放。

**Q18：延迟多大？**
本机回环 + 进程内处理，工具调用通常在毫秒级（实测 `tools/call` 约 40ms）；
`md3_search_songs` / `md3_get_lyric` 的实际耗时取决于本地 Rust 服务器到酷狗上游的网络往返。

**Q19：能多个客户端同时连吗？**
可以，服务端无会话状态，每个请求独立处理。但多客户端同时下发控制指令会互相打架（这是预期行为）。

**Q20：这跟 App 里那个"本地数据接口"是一回事吗？**
不是。设置页「缓存与数据 → 本地数据接口」是**随机的** Rust API 服务器端口（每次启动都变），
供 App 自身调酷狗接口用；MCP 是**固定端口** 17888 的独立服务，供外部 AI 调用。两者互不影响。

**Q21：需要 root 吗？**
不需要。

**Q22：支持 SSE / 长连接推送吗？**
支持。`initialize` 的响应会带 `Mcp-Session-Id` 头；带上该头发 `GET /mcp`（`Accept:
text/event-stream`）即可打开下行流，服务端通过它推送 `notifications/tools/list_changed`
（组开关/只读等改变 tools/list 时触发）。`DELETE /mcp` 带会话头可注销会话并断流。
不带会话头的 `GET` 返回 400。`POST` 响应仍为 JSON（主流客户端两种都支持）。

**Q23：能看到 AI 调了什么吗？**
能。设置页「最近调用（50 条）」列出时间 / 工具名 / 成功与否 / 参数摘要，可一键复制。

**Q24：怎么彻底关掉？**
设置页关掉「启用 MCP 服务」即可，端口立即释放。可用
`adb shell "ss -ltn | grep 17888"` 确认（无输出 = 未监听）。

**Q25：升级 App 后客户端配置要改吗？**
一般不用：端口与令牌都持久化。除非你手动改过端口，或端口被占用而顺延了。

**Q26：支持哪些 MCP 协议版本？**
`2025-06-18`（默认）、`2025-03-26`、`2024-11-05`；服务端按客户端声明回显，未知版本回落最新。

**Q27：`loop_mode` 的 off / one / all 是什么？**
分别对应不循环、单曲循环、列表循环，即 App 里的循环模式。

**Q28：进度看起来滞后？**
工具返回的是平台真实播放位置（不是乐观估算值），偶有几十毫秒级采样延迟属正常。

**Q29：MCP 播放会影响我在 App 里的操作吗？**
会，而且是同步的：AI 触发的播放在 App UI、通知栏、媒体会话上都会同步体现——这是设计意图，不是 bug。

**Q30：我可以自己加工具吗？**
可以。工具按域拆在 `mcp_tools_player.dart`（播放/队列）、`mcp_tools_library.dart`（检索/发现/
本地曲库）、`mcp_tools_app.dart`（应用功能）、`mcp_tools_library_write.dart`（曲库写），
新增后由 `buildMcpTools()` 装配。端口接口在 `mcp_ports.dart`，真实实现在 `mcp_player_control.dart` /
`mcp_library_source.dart` / `mcp_local_library.dart` / `mcp_app_features.dart`。
新工具记得选好 `group`、按需置 `isMutating` / `requiresConfirmation`；
若改到设置项重跑 `dart run scripts/tools/gen_settings_search_index.dart`。

**Q31：AI 播放了一首歌，过一会儿又从头播放了一次？**
旧版本的播放工具会等待整条播放链路（链接解析 + 音频加载，实测可达 60 秒以上）才返回，
AI 客户端等不到响应就判定超时并**重试同一调用**，正在播的歌被切回开头。
现版本播放工具已改为**异步触发、立即返回**（实测 0.2s），且同工具 400ms 内重复调用会被防抖拒绝，
不会再触发客户端重试风暴；播放成败请用 `md3_get_player_state` 查询（起播有几秒延迟属正常）。

---

## 10. 故障排查

### 错误码对照

| 现象 | 含义 | 处理 |
|------|------|------|
| HTTP 401 | 缺令牌或令牌错（局域网模式） | 请求头加 `Authorization: Bearer <令牌>` |
| HTTP 400 | `GET /mcp` 没带 `Mcp-Session-Id` | 先 `initialize` 拿响应头里的会话 id |
| HTTP 404 | 路径不是 `/mcp`，或会话 id 未知/已注销 | URL 末尾应为 `/mcp`；重新 `initialize` |
| HTTP 405 | 用了 GET 但方法不是 GET/POST/DELETE/OPTIONS（如 PUT） | 换用 POST |
| HTTP 406 | `Accept` 头不含 `application/json` / `text/event-stream` | 客户端问题，一般无需处理 |
| JSON-RPC `-32601` | 方法不存在（如客户端请求了 completion 等未实现能力） | 只实现 tools/resources/prompts |
| JSON-RPC `-32602` | 参数非法（`prompts/get` 缺参数、未知模板名等） | 看 `message` 字段 |
| JSON-RPC `-32002` | `resources/read` 的 uri 不存在 | 用 `resources/list` 里列出的 uri |
| JSON-RPC `-32700` | 请求体不是合法 JSON | 客户端问题 |
| JSON-RPC `-32000` | 业务错误（未授权 / 会话不存在 / 未找到） | 看 `message` 字段 |
| 响应里 `isError: true` | 工具执行失败 | `content[0].text` 里有中文原因 |

所有错误响应都带完整 JSON-RPC 信封：
`{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"..."}}`

### 分步排查清单

```bash
# 1) App 内是否真的在监听（用 ss，别用 /proc/net/tcp——字段解析易误判）
adb shell "ss -ltn | grep 17888"
#    127.0.0.1:17888 → 只绑回环；0.0.0.0:17888 → 开了局域网；无输出 → 服务未运行

# 2) 局域网直连测试（先在设置页开「允许局域网访问」）
curl -s -m 10 http://<手机IP>:17888/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer <令牌>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# 3) USB 方式：先建正向转发再握手（实测 reverse 不通，见 Q2）
adb forward tcp:17888 tcp:17888 && curl -s -m 10 http://127.0.0.1:17888/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 4) 会话与 SSE 下行（可选）：initialize 拿会话 id，再开流收通知
curl -si -m 10 http://127.0.0.1:17888/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
  | grep -i mcp-session-id
```

### 排查设置页崩溃

若进入「AI 代理」页显示「此处内容加载出错」，项目全局错误捕获会把堆栈写到设备上：

```bash
adb shell tail -60 /sdcard/flutter_error.txt
```

---

## 11. 给开发者：目录结构

```
lib/modules/mcp/
├── mcp_jsonrpc.dart           JSON-RPC 2.0 模型 + McpDispatcher（tools/resources/prompts/会话 id）
├── mcp_tool.dart              McpTool（group/requiresConfirmation）/ Registry（分组/只读/确认/防抖）
├── mcp_ports.dart             端口接口 + 快照（McpPlayerControl / McpLibrarySource /
│                              McpLocalLibrarySource / McpAppFeaturesPort / McpLibraryWriteSource）
├── mcp_player_control.dart    PlayerProvider 适配实现（含事件等待长轮询）
├── mcp_library_source.dart    KugouApiClient 读/写适配（可注入网关接缝）
├── mcp_local_library.dart     LibraryProvider 适配（本地曲库只读）
├── mcp_app_features.dart      睡眠定时/均衡器/桌面歌词/输出模式适配
├── mcp_tools_player.dart      播放与队列工具（18 个，含 md3_wait_for_player_event）
├── mcp_tools_library.dart     检索/发现/歌单/本地曲库工具 + buildMcpTools 装配入口
├── mcp_tools_app.dart         应用功能工具（5 个）
├── mcp_tools_library_write.dart 曲库写工具（2 个，均需确认）
├── mcp_resource.dart          McpResource
├── mcp_resources_md3.dart     三个内置资源（状态/队列/歌词）
├── mcp_prompt.dart            McpPrompt + 三个预置模板
├── mcp_confirmation.dart      写操作二次确认 broker（挂起/超时/裁决）
├── mcp_confirm_dialog.dart    全局确认弹窗宿主（挂在 MaterialApp.builder）
├── mcp_http_server.dart       HttpServer 传输层（POST/GET SSE/DELETE/OPTIONS + 会话表）
├── mcp_settings.dart          设置模型与持久化（令牌走 secure storage）
└── mcp_service.dart           总控（启停、状态、令牌、50 条调用日志、通知广播）

lib/modules/settings/mcp_agent_section.dart   「AI 代理」分类的二级界面
scripts/tools/mcp_stdio_bridge.py             stdio 桥接脚本（Python，零依赖）
```

> 会话约定：`initialize` 的响应头带 `Mcp-Session-Id`；后续 POST 可带该头（未知会话 404），
> `GET /mcp` 带该头开 SSE 下行，`DELETE /mcp` 带该头注销。带会话头的 initialize 复用既有会话，
> 不重新下发。

**扩展一个新工具**：在 `mcp_tools_player.dart` 或 `mcp_tools_library.dart` 的返回列表里加一个
`McpTool`（含 `name` / `description` / `inputSchema` / `handler` / `isMutating`），
在 handler 里抛 `ArgumentError` 表达参数错误，其余交给 `McpToolRegistry.execute` 收敛。
对应单测在 `test/modules/mcp/mcp_tools_test.dart`（用 `FakePlayerControl` / `FakeApiClient`）。

> ⚠️ 新建 UI 文件必须 `import 'package:material_ui/material_ui.dart'`，
> **不能**用 `package:flutter/material.dart`（官方 `ListTile` 会检查 Flutter 的 `Material` 祖先，
> 而本项目用的是解耦后的 material_ui，会直接抛 "No Material widget found"）。
