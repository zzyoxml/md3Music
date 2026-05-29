#!/bin/bash

# 构建Docker镜像
echo "🔧 构建Docker镜像..."
docker build -t kugou-api-server .

# 停止旧容器
echo "⏹️ 停止旧容器..."
docker stop kugou-api 2>/dev/null || true
docker rm kugou-api 2>/dev/null || true

# 运行新容器
echo "🚀 启动API服务器容器..."
docker run -d \
  --name kugou-api \
  -p 3000:3000 \
  -e NODE_ENV=production \
  --restart=always \
  kugou-api-server

echo "✅ 部署完成！"
echo "API服务器已启动在: http://localhost:3000"
