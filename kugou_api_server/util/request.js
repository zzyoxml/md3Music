const axios = require('axios');
const { cryptoMd5 } = require('./crypto');
const { signKey, signatureAndroidParams, signatureRegisterParams, signatureWebParams } = require('./helper');
const { parseCookieString } = require('./util');
const { isPlatformLite } = require('./platform');
const { appid, clientver, liteAppid, liteClientver } = require('./config.json');
const { resolveProxy } = require('./runtime');
const { generateSimulate } = require('./generate_simulate');

/**
 * @typedef {{status: number;body: any, cookie: string[], headers?: Record<string, string>}} UseAxiosResponse
 */

/**
 * 请求创建
 * @param {Object} options
 * @param {'get' | 'GET' | 'post' | 'POST'} options.method 请求方法
 * @param {string} options.url 请求 url
 * @param {string?} options.baseURL
 * @param {Record<string, any>?} options.params 请求参数
 * @param {Record<string, any>?} options.data 请求Body
 * @param {Record<string, string | number>?} options.headers 请求headers
 * @param {'android' | 'web' | 'register'} options.encryptType signature加密方式
 * @param {{ [key: string]: string | number }} options.cookie 请求cookie
 * @param {boolean?} options.encryptKey
 * @param {boolean?} options.clearDefaultParams 清除默认请求参数
 * @param {boolean?} options.notSignature
 * @param {string?} options.ip
 * @param {string?} options.realIP
 * @returns {Promise<UseAxiosResponse>}
 */

const createRequest = (options) => {
  return new Promise(async (resolve, reject) => {
    // 平台类型: 强制走概念版（lite）协议
    const isLite = isPlatformLite(options?.cookie);
    const dfid = options?.cookie?.dfid || '-'; // 自定义
    const mid = `${options?.cookie?.KUGOU_API_MID}`;
    const uuid = '-'; //cryptoMd5(`${dfid}${mid}`); // 可以自定义
    const token = options?.cookie?.token || '';
    const userid = Number(options?.cookie?.userid || 0);
    const clienttime = Math.floor(Date.now() / 1000);
    const ip = options?.realIP || options?.ip || '';
    const cookieStr = options?.cookie
      ? Object.entries(options.cookie)
          .filter(([k, v]) => k && v !== undefined)
          .map(([k, v]) => `${k}=${v}`)
          .join('; ')
      : '';
    const headers = {
      dfid, clienttime, mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': 1,
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    };
    if (cookieStr) headers['Cookie'] = cookieStr;

    if (ip) {
      headers['X-Real-IP'] = ip;
      headers['X-Forwarded-For'] = ip;
    }

    const defaultParams = {
      dfid,
      mid,
      uuid,
      appid: isLite ? liteAppid : appid,
      clientver: isLite ? liteClientver : clientver,
      clienttime,
    };

    if (token) defaultParams['token'] = token;
    if (userid && userid !== 0) defaultParams['userid'] = userid;
    const params = options?.clearDefaultParams ? options?.params || {} : Object.assign({}, defaultParams, options?.params || {});

    headers['clienttime'] = params.clienttime;

    if (options?.encryptKey) {
      params['key'] = signKey(params['hash'], params['mid'], params['userid'], params['appid']);
    }

    // 签名数据：Buffer 类型直接传入（在 helper.js 中用增量 MD5 处理），
    // 其他类型转为字符串
    const sigData = Buffer.isBuffer(options?.data)
      ? options.data
      : (typeof options?.data === 'object' ? JSON.stringify(options.data) : options?.data || '');

    if (!params['signature'] && !options.notSignature) {
      switch (options?.encryptType) {
        case 'register':
          params['signature'] = signatureRegisterParams(params);
          break;
        case 'web':
          params['signature'] = signatureWebParams(params);
          break;
        case 'android':
        default:
          params['signature'] = signatureAndroidParams(params, sigData);
          break;
      }
    }

    // options.params = params;
    options['params'] = params;
    options['baseURL'] = options?.baseURL || 'https://gateway.kugou.com';
    options['headers'] = Object.assign({ 'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi' }, options?.headers || {}, {
      dfid,
      clienttime: params.clienttime,
      mid,
    });

    const requestOptions = {
      params,
      data: options?.data,
      method: options.method,
      baseURL: options?.baseURL,
      url: options.url,
      headers: Object.assign({}, options?.headers || {}, headers),
      withCredentials: true,
      responseType: options.responseType,
    };

    const proxyConfig = resolveProxy();
    if (proxyConfig) {
      requestOptions.proxy = proxyConfig;
    }

    if (options.data) requestOptions.data = options.data;
    if (params) requestOptions.params = params;

    if (options.baseURL?.includes('openapicdn')) {
      const url = requestOptions.url;
      const _params = Object.keys(params)
        .map((key) => `${key}=${params[key]}`)
        .join('&');
      requestOptions.url = `${url}?${_params}`;
      requestOptions.params = {};
    }

    const answer = { status: 500, body: {}, cookie: [], headers: {} };
    try {
      let response = await axios(requestOptions);
      let ssaCode = response.headers['ssa-code'] || response.headers['SSA-CODE'];

      // ========== SSA 安全验证重试 ==========
      // 当酷狗返回 ssa-code 且请求失败时（如 error_code 20028 "需进行验证"），
      // 生成模拟行为指纹（edt/sid）并重试一次
      const isError = response.data?.status === 0 || (response.data?.error_code && response.data.error_code !== 0);
      if (isError && ssaCode && !options._ssaRetried) {
        console.log(`[SSA] ssa-code detected (url=${options.url}, error_code=${response.data?.error_code}), generating fingerprint for retry...`);
        const webglHash = options?.cookie?.KUGOU_API_WEBGL;
        const { edt, sid } = generateSimulate(mid, userid, dfid, webglHash);

        // 在请求头中添加 edt/sid 进行重试
        requestOptions.headers['edt'] = edt;
        requestOptions.headers['sid'] = sid;
        options._ssaRetried = true;

        response = await axios(requestOptions);
        ssaCode = response.headers['ssa-code'] || response.headers['SSA-CODE'];
        console.log(`[SSA] Retry result: status=${response.data?.status}, error_code=${response.data?.error_code}`);
      }

      // ========== 诊断日志：关注歌手接口失败时打印详细信息 ==========
      if (options.url?.includes('follow_singer') && isError) {
        console.log(`[FOLLOW_SINGER] url=${options.url}`);
        console.log(`[FOLLOW_SINGER] response headers=`, JSON.stringify(response.headers));
        console.log(`[FOLLOW_SINGER] response body=`, JSON.stringify(response.data));
        console.log(`[FOLLOW_SINGER] cookie keys=`, Object.keys(options?.cookie || {}));
        console.log(`[FOLLOW_SINGER] dfid=${dfid}, mid=${mid}, userid=${userid}, token=${token ? 'yes' : 'no'}`);
      }

      const body = response.data;

      answer.cookie = (response.headers['set-cookie'] || []).map((x) => parseCookieString(x));

      if (ssaCode) {
        answer.headers['ssa-code'] = ssaCode;
      }

      try {
        answer.body = JSON.parse(body.toString());
      } catch (error) {
        answer.body = body;
      }

      if (response.data.status === 0 || (response.data?.error_code && response.data.error_code !== 0)) {
        if (response.data.status === 2) {
          answer.status = 200;
          resolve(answer);
        } else {
          answer.status = 502;
          // 如果仍有 ssa-code，附加 edt/sid 到响应体（供客户端后续使用）
          if (ssaCode) {
            const webglHash = options?.cookie?.KUGOU_API_WEBGL;
            const { edt, sid } = generateSimulate(mid, userid, dfid, webglHash);
            if (edt) answer.body.edt = edt;
            if (sid) answer.body.sid = sid;
            answer.body.ssaCode = ssaCode;
          }
          reject(answer);
        }
      } else {
        answer.status = 200;
        resolve(answer);
      }
    } catch (e) {
      answer.status = 502;
      answer.body = { status: 0, msg: e };
      reject(answer);
    }
  });
};

module.exports = { createRequest };
