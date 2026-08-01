/**
 * 最小化公网 API 服务器
 * 仅处理登录相关接口，部署在云服务器 115.29.236.96:5621
 */
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const decode = require('safe-decode-uri-component');
const { cookieToJson, randomString, getGuid, calculateMid } = require('./util/util');
const { cryptoMd5 } = require('./util/crypto');
const { createRequest } = require('./util/request');
const dotenv = require('dotenv');
const cache = require('./util/apicache').middleware;
const deviceConfig = require('./device_config');

const guid = cryptoMd5(getGuid());
const serverDev = randomString(10).toUpperCase();

const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  dotenv.config({ path: envPath, quiet: true });
}

// 仅加载登录相关模块
const loginModules = {};
const moduleFiles = [
  'captcha_sent',
  'login_cellphone',
  'login_qr_key',
  'login_qr_check',
  'login_qr_create',
  'login_token',
  'login',
  'login_device',
  'login_device_kick',
  'login_openplat',
  'login_wx_create',
  'login_wx_check',
  'register_dev',
  'server_now',
  'user_detail',
  'user_vip_detail',
  'user_playlist',
  'youth_day_vip_upgrade',
  'youth_day_vip',
  'youth_month_vip_record',
];

const moduleDefs = [];
for (const name of moduleFiles) {
  try {
    const mod = require(`./module/${name}.js`);
    moduleDefs.push({
      identifier: name,
      route: `/${name.replace(/_/g, '/')}`,
      module: mod,
    });
  } catch (e) {
    console.warn(`Module ${name} not found, skipping`);
  }
}

async function startService() {
  const port = Number(process.env.PORT || 3000);
  const host = process.env.HOST || '0.0.0.0';

  const app = express();

  // CORS
  app.use((req, res, next) => {
    if (req.path !== '/' && !req.path.includes('.')) {
      res.set({
        'Access-Control-Allow-Credentials': true,
        'Access-Control-Allow-Origin': req.headers.origin || '*',
        'Access-Control-Allow-Headers': 'Authorization,X-Requested-With,Content-Type,Cache-Control',
        'Access-Control-Allow-Methods': 'PUT,POST,GET,DELETE,OPTIONS',
        'Content-Type': 'application/json; charset=utf-8',
      });
    }
    req.method === 'OPTIONS' ? res.status(204).end() : next();
  });

  // Cookie 解析
  app.use((req, _, next) => {
    req.cookies = {};
    (req.headers.cookie || '').split(/;\s+|(?<!\s)\s+$/g).forEach((pair) => {
      const crack = pair.indexOf('=');
      if (crack < 1 || crack === pair.length - 1) return;
      req.cookies[decode(pair.slice(0, crack)).trim()] = decode(pair.slice(crack + 1)).trim();
    });
    next();
  });

  // 平台标识 Cookie 注入
  app.use((req, res, next) => {
    const cookies = req.cookies || {};
    const isHttps = req.protocol === 'https';
    const cookieSuffix = isHttps ? '; PATH=/; SameSite=None; Secure' : '; PATH=/';
    const ensureCookie = (key, value) => {
      if (Object.prototype.hasOwnProperty.call(cookies, key)) return;
      cookies[key] = String(value);
      res.append('Set-Cookie', `${key}=${cookies[key]}${cookieSuffix}`);
    };
    const mid = calculateMid(process.env.KUGOU_API_GUID ?? guid);
    ensureCookie('KUGOU_API_PLATFORM', process.env.platform);
    ensureCookie('KUGOU_API_MID', mid);
    ensureCookie('KUGOU_API_GUID', process.env.KUGOU_API_GUID ?? guid);
    ensureCookie('KUGOU_API_DEV', (process.env.KUGOU_API_DEV ?? serverDev).toUpperCase());
    ensureCookie('KUGOU_API_MAC', (process.env.KUGOU_API_MAC ?? '02:00:00:00:00:00').toUpperCase());
    req.cookies = cookies;
    next();
  });

  app.use(express.json());
  app.use(express.urlencoded({ extended: false }));
  app.use(cache('2 minutes', (_, res) => res.statusCode === 200));

  // 注册路由
  for (const moduleDef of moduleDefs) {
    app.use(moduleDef.route, async (req, res) => {
      [req.query, req.body].forEach((item) => {
        if (typeof item.cookie === 'string') {
          item.cookie = cookieToJson(decode(item.cookie));
        }
      });
      const { cookie, ...params } = req.query;
      const query = Object.assign({}, { cookie: Object.assign({}, req.cookies, cookie) }, params, { body: req.body });
      const authHeader = req.headers['authorization'];
      if (authHeader) {
        const authCookie = cookieToJson(authHeader);
        query.cookie = { ...query.cookie, ...authCookie };
      }
      try {
        const moduleResponse = await moduleDef.module(query, (config) => {
          let ip = req.ip;
          if (ip.substring(0, 7) === '::ffff:') ip = ip.substring(7);
          config.ip = ip;
          return createRequest(config);
        });
        const cookies = moduleResponse.cookie;
        if (Array.isArray(cookies) && cookies.length > 0) {
          res.append('Set-Cookie', cookies.map((c) => `${c}; PATH=/`));
        }
        res.header(moduleResponse.headers).status(moduleResponse.status).send(moduleResponse.body);
      } catch (e) {
        const moduleResponse = e;
        if (!moduleResponse.body) {
          return res.status(404).send({ code: 404, data: null, msg: 'Not Found' });
        }
        res.header(moduleResponse.headers).status(moduleResponse.status).send(moduleResponse.body);
      }
    });
  }

  app.listen(port, host, () => {
    console.log(`Network API running @ http://${host}:${port}`);
  });
}

startService();
