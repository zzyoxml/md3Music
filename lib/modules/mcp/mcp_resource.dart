/// MCP Resource：客户端可经 resources/list 与 resources/read 浏览的只读数据。
class McpResource {
  const McpResource({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
    required this.read,
  });

  final String uri;
  final String name;
  final String description;
  final String mimeType;
  final Future<String> Function() read;

  Map<String, Object?> toJson() => <String, Object?>{
        'uri': uri,
        'name': name,
        'description': description,
        'mimeType': mimeType,
      };
}
