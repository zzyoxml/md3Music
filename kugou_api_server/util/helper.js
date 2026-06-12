const { cryptoMd5 } = require('./crypto');
const { appid: useAppid, liteAppid, clientver: useClientver, liteClientver } = require('./config.json');
const { isPlatformLite } = require('./platform');

/**
 * web版本 signature 加密
 * @param {HelperParams} params
 * @returns {string} 加密后的signature
 */
const signatureWebParams = (params) => {
  const str = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
  const paramsString = Object.keys(params)
    .map((key) => `${key}=${params[key]}`)
    .sort()
    .join('');
  return cryptoMd5(`${str}${paramsString}${str}`);
};

/**
 * Android版本 signature 加密
 * @param {HelperParams} params
 * @param {string?} data
 * @param {object?} cookie 可选，请求 cookie，用于动态判断是否走 lite
 * @returns {string} 加密后的signature
 */
const signatureAndroidParams = (params, data, cookie) => {
  const isLite = isPlatformLite(cookie);
  const str = isLite ? 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA' : `OIlwieks28dk2k092lksi2UIkp`;
  const paramsString = Object.keys(params)
    .sort()
    .map((key) => `${key}=${typeof params[key] === 'object' ? JSON.stringify(params[key]) : params[key]}`)
    .join('');
  return cryptoMd5(`${str}${paramsString}${data || ''}${str}`);
};

/**
 * Register版本 signature 加密
 * @param {HelperParams} params
 * @returns {string} 加密后的signature
 */
const signatureRegisterParams = (params) => {
  const paramsString = Object.keys(params)
    .map((key) => params[key])
    .sort()
    .join('');
  return cryptoMd5(`1014${paramsString}1014`);
};

/**
 * sign 加密
 * @param {HelperParams} params
 * @param {string?} data
 * @returns {string} 加密后的sign
 */
const signParams = (params, data) => {
  const str = 'R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza';
  const paramsString = Object.keys(params)
    .sort()
    .map((key) => `${key}${params[key]}`)
    .join('');
  return cryptoMd5(`${paramsString}${data || ''}${str}`);
};

/**
 * signKey 加密
 * @param {string} hash
 * @param {string} mid
 * @param {(string | number)?} userid
 * @param {(string | number)?} appid
 * @returns {string} 加密后的sign
 */
const signKey = (hash, mid, userid, appid) => {
  // 强制走 lite 协议
  const str = '185672dd44712f60bb1736df5a377e82';
  return cryptoMd5(`${hash}${str}${appid || useAppid}${mid}${userid || 0}`);
};

/**
 * signKey 加密云盘key
 * @param {string} hash
 * @param {string} pid
 * @returns {string} 加密后的sign
 */
const signCloudKey = (hash, pid) => {
  const str = 'ebd1ac3134c880bda6a2194537843caa0162e2e7';
  return cryptoMd5(`musicclound${hash}${pid}${str}`);
};

/**
 * signParams 加密
 * @param {string | number} data
 * @param {(string | number)?} appid
 * @param {(string | number)?} clientver
 * @returns {string} 加密后的signParams
 */

const signParamsKey = (data, appid, clientver) => {
  // 强制走 lite 协议
  const str = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  appid = appid || liteAppid;

  clientver = clientver || liteClientver;

  return cryptoMd5(`${appid}${str}${clientver}${data}`);
};

module.exports = {
  signKey,
  signParams,
  signParamsKey,
  signCloudKey,
  signatureAndroidParams,
  signatureRegisterParams,
  signatureWebParams,
};
