#!/usr/bin/env python3
"""把只支持 stdio 的 MCP 客户端接到 MD3Music 的 HTTP MCP 端点。

用法（Claude Desktop 的 mcpServers 配置）：
{
  "mcpServers": {
    "md3music": {
      "command": "python",
      "args": ["scripts/tools/mcp_stdio_bridge.py", "http://127.0.0.1:17888/mcp"],
      "env": {"MD3MCP_TOKEN": "<设置页里的令牌>"}
    }
  }
}
"""
import json
import os
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: mcp_stdio_bridge.py <url>", file=sys.stderr)
        return 2
    url = sys.argv[1]
    token = os.environ.get("MD3MCP_TOKEN", "")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = urllib.request.Request(
            url,
            data=line.encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                **({"Authorization": f"Bearer {token}"} if token else {}),
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8")
                status = resp.status
        except Exception as exc:  # 网络错误也要回一条 JSON-RPC 错误，别静默
            sys.stdout.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32000, "message": f"bridge error: {exc}"},
                    }
                )
                + "\n"
            )
            sys.stdout.flush()
            continue
        if status in (202, 204) or not body:
            continue  # 通知 / 空响应：stdio 端无需输出
        sys.stdout.write(body + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
