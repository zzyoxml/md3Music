const { apiver, appid, wx_appid, wx_lite_appid, wx_secret, wx_lite_secret, srcappid, clientver, liteAppid, liteClientver } = require('./config.json');
const { isPlatformLite } = require('./platform');
const {
  cryptoAesDecrypt,
  cryptoAesEncrypt,
  cryptoMd5,
  cryptoRSAEncrypt,
  cryptoSha1,
  rsaEncrypt2,
  playlistAesEncrypt,
  playlistAesDecrypt,
  publicLiteRasKey,
  publicRasKey,
} = require('./crypto');
const { createRequest } = require('./request');
const { signKey, signParams, signParamsKey, signCloudKey, signatureAndroidParams, signatureRegisterParams, signatureWebParams } = require('./helper');
const { randomString, decodeLyrics, parseCookieString, cookieToJson, randomNumber, calculateMid } = require('./util');

// 模块加载时的兜底值（用于一些启动期常量的场景）
// 强制走概念版（lite）协议
const isLite = true;
const useAppid = liteAppid;
const useClientver = liteClientver;

module.exports = {
  apiver,
  appid: useAppid,
  // liteAppid,
  // liteClientver,
  wx_appid,
  wx_lite_appid,
  wx_secret,
  wx_lite_secret,
  srcappid,
  clientver: useClientver,
  isLite,
  isPlatformLite,
  cryptoAesDecrypt,
  cryptoAesEncrypt,
  cryptoMd5,
  cryptoRSAEncrypt,
  cryptoSha1,
  rsaEncrypt2,
  playlistAesEncrypt,
  playlistAesDecrypt,
  createRequest,
  signKey,
  signParams,
  signParamsKey,
  signCloudKey,
  signatureAndroidParams,
  signatureRegisterParams,
  signatureWebParams,
  randomString,
  decodeLyrics,
  parseCookieString,
  cookieToJson,
  publicLiteRasKey,
  publicRasKey,
  randomNumber,
  calculateMid
};
