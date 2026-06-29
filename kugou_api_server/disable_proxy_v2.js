const fs = require('fs');
const filePath = 'server.js';

let content = fs.readFileSync(filePath, 'utf8');

// 1. 在动态路由回调开头（第 436 行附近）插入 /audio/proxy 拦截
//    找到 "app.use(moduleDef.route, async (req, res) => {" 之后的位置
const dynamicRouteStart = "  for (const moduleDef of moduleDefinitions) {\n    app.use(moduleDef.route, async (req, res) => {";
const interceptCode = `\n    // 🚨 安全：禁用音频代理端点，避免服务器流量耗尽\n    if (req.path === '/audio/proxy') {\n      console.warn('[AUDIO_PROXY] Disabled - client should use URL from /song/url directly');\n      return res.status(403).json({\n        error: 'Audio proxy is disabled. Use the URL from /song/url directly.',\n        reason: 'Server traffic limit exceeded. Clients must play audio directly from CDN.',\n      });\n    }\n`;

if (content.includes(dynamicRouteStart)) {
  const insertPos = content.indexOf(dynamicRouteStart) + dynamicRouteStart.length;
  content = content.slice(0, insertPos) + interceptCode + content.slice(insertPos);
  console.log('✅ 已在动态路由开头插入 /audio/proxy 拦截');
} else {
  console.error('❌ 找不到动态路由起始位置');
}

// 2. 替换 /audio/proxy 端点定义为禁用版本
const oldEndpoint = `  app.get('/audio/proxy', async (req, res) => {
    const audioUrl = req.query.url;
    if (!audioUrl) {
      return res.status(400).json({ error: 'url parameter is required' });
    }

    try {
      const axios = require('axios');
      const response = await axios.get(audioUrl, {
        responseType: 'stream',
        timeout: 30000,
        headers: {
          'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRMProtocol-wifi',
          'Referer': 'https://www.kugou.com/',
        },
      });

      res.set({
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Range',
        'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges',
        'Content-Type': response.headers['content-type'] || 'audio/mpeg',
        'Accept-Ranges': 'bytes',
      });

      if (response.headers['content-length']) {
        res.set('Content-Length', response.headers['content-length']);
      }
      if (response.headers['content-range']) {
        res.set('Content-Range', response.headers['content-range']);
      }

      response.data.pipe(res);
    } catch (e) {
      console.error('Audio proxy error:', e.message);
      if (!res.headersSent) {
        res.status(502).json({ error: 'Failed to fetch audio' });
      }
    }
  });`;

const newEndpoint = `  app.get('/audio/proxy', async (req, res) => {
    // 🚨 安全：禁用音频代理，避免服务器流量耗尽
    console.warn('[AUDIO_PROXY] Disabled - client should use URL from /song/url directly');
    return res.status(403).json({
      error: 'Audio proxy is disabled. Use the URL from /song/url directly.',
      reason: 'Server traffic limit exceeded. Clients must play audio directly from CDN.',
    });
  });`;

if (content.includes(oldEndpoint)) {
  content = content.replace(oldEndpoint, newEndpoint);
  console.log('✅ 已替换 /audio/proxy 端点为禁用版本');
} else {
  console.log('⚠️ 未找到完整的旧端点代码，尝试模糊匹配...');
  // 模糊匹配：找到 app.get(\'/audio/proxy\' 到下一个 app. 或 }); 的位置
  const idx = content.indexOf("  app.get('/audio/proxy'");
  if (idx !== -1) {
    let endIdx = idx;
    let braceCount = 0;
    for (let i = idx; i < content.length; i++) {
      if (content[i] === '{') braceCount++;
      if (content[i] === '}') {
        braceCount--;
        if (braceCount === 0) { endIdx = i; break; }
      }
    }
    content = content.slice(0, idx) + newEndpoint + content.slice(endIdx + 1);
    console.log('✅ 已模糊匹配替换 /audio/proxy 端点');
  } else {
    console.error('❌ 找不到 /audio/proxy 端点');
  }
}

fs.writeFileSync(filePath, content, 'utf8');
console.log('✅ 修改完成，运行 node -c server.js 检查语法...');
