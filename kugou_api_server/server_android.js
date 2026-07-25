const fs = require('node:fs');
const path = require('node:path');
const { cookieToJson, randomString, getGuid, calculateMid } = require('./util/util');
const { cryptoMd5 } = require('./util/crypto');
const { createRequest } = require('./util/request');
const dotenv = require('dotenv');
const cache = require('./util/apicache').middleware;
const deviceConfig = require('./device_config');

const express = require('express');
const decode = require('safe-decode-uri-component');

let registeredDfid = null;
let registeredMid = null;

function loadCachedDeviceInfo() {
  try {
    const serverDir = process.env.NODE_SERVER_DIR || __dirname;
    const cacheFile = path.join(serverDir, 'device_info.json');
    if (fs.existsSync(cacheFile)) {
      const data = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
      if (data.dfid) {
        registeredDfid = data.dfid;
        registeredMid = data.mid || null;
        deviceConfig.setDfid(registeredDfid);
        if (registeredMid) deviceConfig.setMid(registeredMid);
        deviceConfig.initDeviceInfo();
        console.log(`Loaded cached device: dfid=${registeredDfid}`);
        return true;
      }
    }
  } catch (e) {
    console.warn('Failed to load device cache:', e.message);
  }
  return false;
}

const guid = cryptoMd5(getGuid());
const serverDev = randomString(10).toUpperCase();

const envPath = path.join(process.env.NODE_SERVER_DIR || __dirname, '.env');
if (fs.existsSync(envPath)) {
  dotenv.config({ path: envPath, quiet: true });
}

// Pre-require ALL modules - they are bundled inline by esbuild
const moduleFiles = [
  'ai_recommend', 'album', 'album_detail', 'album_shop', 'album_songs',
  'artist_albums', 'artist_audios', 'artist_detail', 'artist_follow',
  'artist_follow_newsongs', 'artist_honour', 'artist_lists', 'artist_unfollow',
  'artist_videos', 'audio', 'audio_accompany_matching', 'audio_ktv_total',
  'audio_related', 'brush', 'captcha_sent', 'comment_album', 'comment_count',
  'comment_floor', 'comment_music', 'comment_music_classify', 'comment_music_hotword',
  'comment_playlist', 'everyday_friend', 'everyday_history', 'everyday_recommend',
  'everyday_style_recommend', 'favorite_count', 'fm_class', 'fm_image',
  'fm_recommend', 'fm_songs', 'images', 'images_audio', 'ip', 'ip_dateil',
  'ip_playlist', 'ip_zone', 'ip_zone_home', 'kmr_audio_mv', 'krm_audio',
  'lastest_songs_listen', 'login', 'login_cellphone', 'login_device',
  'login_device_kick', 'login_openplat', 'login_qr_check', 'login_qr_create',
  'login_qr_key', 'login_token', 'login_wx_check', 'login_wx_create',
  'longalbum_album_audios', 'longalbum_album_detail', 'longalbum_daily_recommend',
  'longalbum_rank_recommend', 'longalbum_vip_recommend', 'longalbum_week_recommend',
  'lyric', 'pc_diantai', 'personal_fm', 'playhistory_upload', 'playlist_add',
  'playlist_del', 'playlist_detail', 'playlist_effect', 'playlist_similar',
  'playlist_tags', 'playlist_track_all', 'playlist_track_all_new',
  'playlist_tracks_add', 'playlist_tracks_del', 'privilege_lite', 'rank_audio',
  'rank_info', 'rank_list', 'rank_top', 'rank_vol', 'recommend_songs',
  'register_dev', 'scene_audio_list', 'scene_collection_list', 'scene_lists',
  'scene_lists_v2', 'scene_module', 'scene_module_info', 'scene_music',
  'scene_video_list', 'search', 'search_album', 'search_artist', 'search_complex',
  'search_default', 'search_hot', 'search_lyric', 'search_mixed', 'search_special',
  'search_suggest', 'server_now', 'sheet_collection', 'sheet_detail', 'sheet_explore',
  'sheet_rank', 'sheet_song', 'sheet_tags', 'singer_list', 'song_climax',
  'song_ranking', 'song_ranking_filter', 'song_url', 'song_url_new', 'songlist_add',
  'theme_music', 'theme_music_detail', 'theme_playlist', 'theme_playlist_track',
  'top_album', 'top_card', 'top_card_youth', 'top_ip', 'top_playlist',
  'top_song', 'user_cloud', 'user_cloud_url', 'user_detail', 'user_follow',
  'user_follow_message', 'user_history', 'user_listen', 'user_playlist',
  'user_video_collect', 'user_video_love', 'user_vip_detail', 'video_detail',
  'video_privilege', 'video_url', 'youth_channel_all', 'youth_channel_amway',
  'youth_channel_detail', 'youth_channel_similar', 'youth_channel_song',
  'youth_channel_song_detail', 'youth_day_vip', 'youth_day_vip_upgrade',
  'youth_dynamic', 'youth_dynamic_recent', 'youth_listen_song',
  'youth_month_vip_record', 'youth_union_vip', 'youth_user_song', 'youth_vip',
  'yueku', 'yueku_banner', 'yueku_fm'
];

// Build module definitions array for consturctServer
const moduleDefs = moduleFiles.map((name) => {
  const route = `/${name.replace(/_/g, '/')}`;
  let module;
  try {
    // Use require with a path that esbuild can resolve
    module = require(`./module/${name}.js`);
  } catch (e) {
    // Some modules may not exist in all versions, skip them
    console.warn(`Module ${name} not found, skipping`);
    return null;
  }
  return { identifier: name, route, module };
}).filter(Boolean);

// Reverse to match original server.js ordering
moduleDefs.reverse();

async function consturctServer() {
  const app = express();
  const { CORS_ALLOW_ORIGIN } = process.env;
  app.set('trust proxy', true);

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

  app.use((req, _, next) => {
    req.cookies = {};
    (req.headers.cookie || '').split(/;\s+|(?<!\s)\s+$/g).forEach((pair) => {
      const crack = pair.indexOf('=');
      if (crack < 1 || crack === pair.length - 1) return;
      req.cookies[decode(pair.slice(0, crack)).trim()] = decode(pair.slice(crack + 1)).trim();
    });
    next();
  });

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
  // 解析 application/octet-stream 类型的二进制请求体（用于听歌识曲 /audio/match）
  app.use(express.raw({ type: 'application/octet-stream', limit: '10mb' }));
  app.use(cache('2 minutes', (_, res) => res.statusCode === 200));

  for (const moduleDef of moduleDefs) {
    app.use(moduleDef.route, async (req, res) => {
      if (req.originalUrl && req.originalUrl.startsWith('/audio/proxy')) {
        return res.status(403).json({ error: 'Audio proxy disabled.' });
      }
      [req.query, req.body].forEach((item) => {
        if (typeof item?.cookie === 'string') {
          item.cookie = cookieToJson(decode(item.cookie));
        }
      });
      const { cookie, ...params } = req.query;
      const query = Object.assign({}, { cookie: Object.assign({}, req.cookies, cookie) }, params, { body: req.body });
      // 二进制请求体（如听歌识曲 PCM 数据）通过 data 字段传给模块
      if (Buffer.isBuffer(req.body)) {
        query.data = req.body;
      }
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

  return app;
}

async function startService() {
  const port = Number(process.env.PORT || '8080');
  const host = process.env.HOST || '127.0.0.1';

  const app = await consturctServer();
  app.listen(port, host, async () => {
    console.log(`server running @ http://${host || 'localhost'}:${port}`);
    console.log('Initializing device info...');
    if (!loadCachedDeviceInfo()) {
      console.log('No cached device found, registering...');
      try {
        const axios = require('axios');
        const response = await axios.get(`http://127.0.0.1:${port}/register/dev`, {
          timeout: 10000,
          headers: { 'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi' }
        });
        if (response.data?.data?.dfid) {
          registeredDfid = response.data.data.dfid;
          registeredMid = response.data.data.mid || null;
          deviceConfig.setDfid(registeredDfid);
          if (registeredMid) deviceConfig.setMid(registeredMid);
          deviceConfig.initDeviceInfo();
          const serverDir = process.env.NODE_SERVER_DIR || __dirname;
          const deviceInfo = {
            dfid: registeredDfid,
            mid: registeredMid || deviceConfig.getMid(),
            uuid: deviceConfig.getUuid(),
            guid: deviceConfig.getGuid(),
            serverDev: deviceConfig.getServerDev(),
            mac: deviceConfig.getMac()
          };
          fs.writeFileSync(path.join(serverDir, 'device_info.json'), JSON.stringify(deviceInfo, null, 2));
          console.log(`Device registered: dfid=${registeredDfid}`);
        }
      } catch (e) {
        console.warn('Device registration failed:', e.message);
      }
    }
  });
}

startService();
