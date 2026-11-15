/// MCP Prompt：预置提示词模板，客户端可在会话中直接选用。
class McpPromptArgument {
  const McpPromptArgument({
    required this.name,
    required this.description,
    this.required = false,
  });

  final String name;
  final String description;
  final bool required;
}

class McpPrompt {
  const McpPrompt({
    required this.name,
    required this.description,
    required this.arguments,
    required this.messages,
  });

  final String name;
  final String description;
  final List<McpPromptArgument> arguments;

  /// args 的值已按 argument 名收齐（缺失的 required 参数由 dispatcher 拒绝）。
  final List<Map<String, Object?>> Function(Map<String, String> args) messages;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'arguments': arguments
            .map((a) => <String, Object?>{
                  'name': a.name,
                  'description': a.description,
                  'required': a.required,
                })
            .toList(growable: false),
      };
}

List<Map<String, Object?>> _userText(String text) => <Map<String, Object?>>[
      <String, Object?>{
        'role': 'user',
        'content': <String, Object?>{'type': 'text', 'text': text},
      },
    ];

/// 内置模板。
List<McpPrompt> buildMcpPrompts() => <McpPrompt>[
      McpPrompt(
        name: 'sleep_assistant',
        description: '睡前助眠：设置睡眠定时并放轻音乐',
        arguments: const [
          McpPromptArgument(
              name: 'minutes', description: '多少分钟后暂停播放', required: true),
        ],
        messages: (args) => _userText(
          '请帮我进入睡前模式：先用 md3_set_sleep_timer 设置 ${args['minutes']} 分钟后自动暂停，'
          '再用 md3_search_songs 搜几首轻音乐或白噪音，挑一首用 md3_play_song 播放，'
          '音量用 md3_set_volume 调到 0.4 左右。完成后简短告诉我安排。',
        ),
      ),
      McpPrompt(
        name: 'now_playing_qa',
        description: '正在播放问答：解读当前曲目与歌词',
        arguments: const [],
        messages: (args) => _userText(
          '用 md3_get_player_state 看现在放的是什么，再取这首歌的歌词（先用快照里的 hash，'
          '没有就用歌名 md3_search_songs），给我讲讲这首歌在唱什么。不要切歌。',
        ),
      ),
      McpPrompt(
        name: 'queue_curator',
        description: '队列整理：按主题续歌',
        arguments: const [
          McpPromptArgument(
              name: 'theme', description: '想听的主题，如「华语老歌」「下雨天」', required: true),
        ],
        messages: (args) => _userText(
          '主题：「${args['theme']}」。先用 md3_get_player_state 和 md3_get_queue 了解当前队列，'
          '再搜 3-5 首符合主题的歌，用 md3_enqueue_song 依次加到当前曲目之后（不要打断正在播的）。'
          '最后列出你加了哪些歌。',
        ),
      ),
    ];
