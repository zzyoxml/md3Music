/**
 * @fileoverview 酷狗音乐 API 行为指纹模拟生成器（Node.js 版）
 *
 * 本模块用于在服务端生成模拟的用户行为指纹数据，替代浏览器端 WASM 的功能。
 * 主要用于自动化请求场景，绕过酷狗的行为检测机制（SSA 验证）。
 *
 * 核心功能：
 * 1. 生成模拟的鼠标移动轨迹（贝塞尔曲线 + 随机抖动）
 * 2. 生成模拟的页面交互事件（滚动、窗口 resize 等）
 * 3. 使用 AES-128-CBC 加密行为数据得到 EDT（Encrypted Data Token）
 * 4. 使用 RSA-OAEP SHA-256 加密 AES 密钥得到 SID（Session ID）
 *
 * @module generate_simulate
 * @requires crypto-js - AES 加密库
 * @requires node-forge - RSA 加密库
 * @requires ./util - 工具函数（randomString）
 */
const { randomString } = require('./util');
const CryptoJS = require('crypto-js');
const forge = require('node-forge');

/**
 * RSA 公钥（PEM 格式）
 * 从酷狗 WASM 二进制中提取的 SPKI 公钥，用于 RSA-OAEP SHA-256 加密 AES 密钥
 */
const publicKey = `-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoW2+Ylo8ALePSQTP0xBF\nlFmEOHvBD9tS+s7DBlfKEu3RzzvZTaX1JtYbX4+AVUqj6ARz8IM+CKByqGFvbHN/\nW64XxNI+q7z36ajCL3VTJ2W5G9MCJitc6oGbire4NQfhaEq0nC+hxBWQvCbIFflA\n2ItrLUbSU7z1bHA/a+jlQm4OWvY+IKnTryOJTPuT1yNOVjbJ8wBLKy2DgQr9pPqW\nPmEQtGpR5IM9V8Kao6PaSdKYOWGbX3i2+RzIKhvZUxxtJwdVbqPlDPlW9h4/xIBc\n56Lgvr4aIl8nFtwbj4UJVUTFuGrs0tY9H/tXvZ22dUCKuGxW/gW7ZF+gXz6vHtYa\nrQIDAQAB\n-----END PUBLIC KEY-----`;

/**
 * AES 初始化向量（固定值）
 * ASCII 解码为 "kugousecurity123"
 */
const iv = 'kugousecurity123';

/**
 * 哨兵值（接近 0xFFFFFFFF 的随机值）
 */
let SENTINEL = 0xffffffff - Math.floor(Math.random() * 20);

/**
 * 生成模拟的 WebGL 渲染器指纹哈希
 * @returns {string} MD5 哈希
 */
function generateWebGLHash() {
  const renderers = [
    'ANGLE (Intel, Intel(R) UHD Graphics 620 Direct3D11 vs_5_0 ps_5_0, D3D11)',
    'ANGLE (NVIDIA, NVIDIA GeForce GTX 1060 Direct3D11 vs_5_0 ps_5_0, D3D11)',
    'ANGLE (AMD, AMD Radeon RX 580 Direct3D11 vs_5_0 ps_5_0, D3D11)',
    'Mali-G52',
    'Adreno (TM) 650',
  ];
  const renderer = renderers[Math.floor(Math.random() * renderers.length)];
  return CryptoJS.MD5(renderer).toString(CryptoJS.enc.Hex);
}

/**
 * 生成 EDT 中的 data 字段（用户行为指纹数据）
 *
 * 模拟真实用户在页面上的交互行为，包括：
 * - 窗口加载/resize 事件（type 6）
 * - 页面滚动事件（type 5）
 * - 鼠标移动轨迹（type 3，贝塞尔曲线生成）
 */
function generateEDTData(opts) {
  const { startX, startY, endX, endY, mousePoints } = opts;
  const entries = [];
  let ts = 0;
  let ei = 0;

  // 初始化: 两个 type-5 零事件
  entries.push(f5(0, 0));
  entries.push(fs5(0));
  entries.push(f5(0, 0));
  entries.push(fs5(0));

  // 窗口事件 (type 6)
  ts += ri(5, 20);
  entries.push(f6(ts, ei, 750, 500));
  entries.push(fs6(ei, 750, 500));
  ei++;

  // 滚动事件 (type 5)
  for (let i = 0; i < 3; i++) {
    ts += ri(80, 600);
    entries.push(f5(ts, ei));
    entries.push(fs5(ei));
    ei++;
  }

  // 鼠标轨迹 (type 3) - 贝塞尔曲线
  const path = bezierPath(startX, startY, endX, endY, mousePoints);
  let si = 0;
  for (let i = 0; i < path.length; i++) {
    const { x, y } = path[i];
    ts += ri(8, 50);
    entries.push(f3(ts, si, Math.round(x), Math.round(y)));
    entries.push(fs3(si, Math.round(x), Math.round(y)));
    if (i > 0 && i % 12 === 0) {
      ts += ri(20, 60);
      entries.push(f5(ts, ei));
      entries.push(fs5(ei));
      ei++;
    }
    si = (si + 1) % 2;
  }

  // 结束事件
  ts += ri(5, 30);
  entries.push(f3(ts, 1, Math.round(endX + ri(-5, 5)), Math.round(endY + ri(-5, 5))));
  entries.push(fs3(1, Math.round(endX), Math.round(endY)));
  return entries.join(':');
}

/**
 * 用三阶贝塞尔曲线生成模拟真人的鼠标移动路径
 */
function bezierPath(sx, sy, ex, ey, n) {
  const c1x = sx + (ex - sx) * 0.3 + ri(-80, 80);
  const c1y = sy + (ey - sy) * 0.2 + ri(-60, 60);
  const c2x = sx + (ex - sx) * 0.7 + ri(-60, 60);
  const c2y = sy + (ey - sy) * 0.8 + ri(-40, 40);
  const pts = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const u = 1 - t;
    const x = u * u * u * sx + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * ex;
    const y = u * u * u * sy + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * ey;
    const jitter = Math.max(0.5, 3 - t * 2.5);
    pts.push({
      x: x + (Math.random() - 0.5) * jitter,
      y: y + (Math.random() - 0.5) * jitter,
    });
  }
  return pts;
}

// ============================================================
// 事件记录格式化函数
// ============================================================
function f3(t, i, x, y) { return `3,${t},${i},${x},${y}`; }
function f5(t, i) { return `5,${t},${i}`; }
function f6(t, i, x, y) { return `6,${t},${i},${x},${y}`; }
function fs3(i, x, y) { return `3,${SENTINEL},${i},${x},${y}`; }
function fs5(i) { return `5,${SENTINEL},${i}`; }
function fs6(i, x, y) { return `6,${SENTINEL},${i},${x},${y}`; }

/**
 * 生成 [min, max] 范围内的随机整数
 */
function ri(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

/**
 * 生成模拟的 sid 和 edt 加密数据
 *
 * @param {string|number} mid - 设备 MID 标识
 * @param {string|number} userid - 用户 ID
 * @param {string|number} dfid - 设备指纹 ID
 * @param {string} [webglHash] - WebGL 指纹哈希
 * @returns {{ edt: string, sid: string }} 加密后的数据对象
 */
const generateSimulate = (mid, userid, dfid, webglHash) => {
  SENTINEL = 0xffffffff - Math.floor(Math.random() * 20);

  const key = CryptoJS.MD5(randomString(16)).toString(CryptoJS.enc.Hex).substring(0, 16);

  const points = ri(30, 60);
  const startX = ri(200, 600);
  const startY = ri(200, 500);
  const endX = ri(500, 700);
  const endY = ri(80, 150);

  mid = mid || 0;
  userid = userid || 0;
  dfid = dfid || 0;
  webglHash = webglHash || generateWebGLHash();

  const ts = Date.now();
  const data = generateEDTData({ startX, startY, endX, endY, mousePoints: points });

  const sidPlaintext = `mid=${mid};userid=${userid};dfid=${dfid};webgl=${webglHash};webdriver=0;ts=${ts};data=${data}`;

  // AES-128-CBC 加密行为指纹明文 → EDT
  const edtData = CryptoJS.AES.encrypt(sidPlaintext, CryptoJS.enc.Utf8.parse(key), {
    iv: CryptoJS.enc.Utf8.parse(iv),
    mode: CryptoJS.mode.CBC,
    padding: CryptoJS.pad.Pkcs7,
  }).toString();

  // RSA-OAEP SHA-256 加密 AES 密钥 → SID
  const rsaKey = forge.pki.publicKeyFromPem(publicKey);
  const encrypted = rsaKey.encrypt(key, 'RSA-OAEP', {
    md: forge.md.sha256.create(),
    mgf1: { md: forge.md.sha256.create() },
  });
  const ciphertext = forge.util.encode64(encrypted);

  return { edt: edtData, sid: ciphertext };
};

module.exports = { generateSimulate };
