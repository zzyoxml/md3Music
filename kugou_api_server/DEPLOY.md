# 酷狗API服务器部署指南

## 🎯 部署到云服务器

### 服务器信息
- **公网IP**: `115.29.236.96`
- **端口**: `3000`

---

### 步骤1: 打包项目

在本地执行以下命令打包Docker镜像：

```bash
cd e:\Documents\Trae\project_Flutter\echomusic_player\kugou_api_server

# 构建Docker镜像
docker build -t kugou-api-server .

# 保存镜像为tar文件
docker save kugou-api-server > kugou-api-server.tar

# 或者直接推送到Docker Hub（如果有账号）
# docker tag kugou-api-server yourusername/kugou-api-server
# docker push yourusername/kugou-api-server
```

### 步骤2: 上传到云服务器

**方法A: 使用scp上传**
```bash
scp kugou-api-server.tar root@115.29.236.96:/root/
```

**方法B: 使用Docker Hub**
```bash
# 在云服务器上拉取
docker pull yourusername/kugou-api-server
```

### 步骤3: 在云服务器上部署

```bash
# 登录云服务器
ssh root@115.29.236.96

# 加载镜像
docker load < kugou-api-server.tar

# 停止旧容器（如果存在）
docker stop kugou-api
docker rm kugou-api

# 启动容器
docker run -d \
  --name kugou-api \
  -p 3000:3000 \
  -e NODE_ENV=production \
  --restart=always \
  kugou-api-server

# 检查运行状态
docker ps
```

### 步骤4: 测试API

```bash
# 测试服务器是否正常运行
curl http://115.29.236.96:3000/

# 测试搜索功能
curl "http://115.29.236.96:3000/search?keywords=海阔天空"
```

---

## 📱 配置Flutter应用

### Android/Web应用设置

1. 打开应用 → 设置 → 在线音乐
2. 将API服务器地址改为：
   ```
   http://115.29.236.96:3000
   ```
3. 点击"测试连接"验证

### 修改默认配置（可选）

如果希望应用默认使用云服务器地址，可以修改：

**文件**: `lib/services/kugou_api/kugou_endpoints.dart`

```dart
class KugouEndpoints {
  KugouEndpoints._();
  
  // 修改默认地址为云服务器
  static String baseUrl = 'http://115.29.236.96:3000';
  
  // ... 其他代码
}
```

---

## 🔧 云服务器配置

### 开放防火墙端口

```bash
# 开放3000端口
firewall-cmd --add-port=3000/tcp --permanent
firewall-cmd --reload

# 或者使用iptables
iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
```

### 设置反向代理（可选）

如果使用Nginx，可以添加以下配置：

```nginx
server {
    listen 80;
    server_name api.yourdomain.com;
    
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

---

## 📊 管理命令

```bash
# 查看日志
docker logs kugou-api
docker logs -f kugou-api  # 实时查看

# 重启容器
docker restart kugou-api

# 停止容器
docker stop kugou-api

# 删除容器
docker rm kugou-api

# 查看容器状态
docker ps
docker inspect kugou-api
```

---

## ✅ 部署验证

| 功能 | 测试URL | 预期结果 |
|------|---------|----------|
| 服务状态 | `http://115.29.236.96:3000/` | 返回HTML页面 |
| 搜索 | `http://115.29.236.96:3000/search?keywords=test` | 返回搜索结果 |
| 热门搜索 | `http://115.29.236.96:3000/search/hot` | 返回热门关键词 |
| 歌曲URL | `http://115.29.236.96:3000/song/url?hash=xxx` | 返回歌曲链接 |

---

## 📝 更新部署

```bash
# 在本地重新构建
docker build -t kugou-api-server .
docker save kugou-api-server > kugou-api-server.tar

# 上传到服务器
scp kugou-api-server.tar root@115.29.236.96:/root/

# 在服务器上更新
ssh root@115.29.236.96
docker stop kugou-api
docker rm kugou-api
docker load < kugou-api-server.tar
docker run -d --name kugou-api -p 3000:3000 --restart=always kugou-api-server
```
