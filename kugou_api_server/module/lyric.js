// 歌词获取
const { decodeLyrics } = require('../util');
const axios = require('axios');

module.exports = (params, useAxios) => {
  const dataMap = {
    ver: 1,
    client: params?.client || 'android',
    id: params?.id,
    accesskey: params?.accesskey,
    fmt: params?.fmt || 'lrc',
    charset: 'utf8',
  };

  return new Promise(async (resolve, reject) => {
    try {
      const response = await axios({
        baseURL: 'https://lyrics.kugou.com',
        url: '/download',
        method: 'GET',
        params: dataMap,
      });

      const body = response.data;
      if (params?.decode && body?.content) {
        body['decodeContent'] = params?.fmt == 'lrc' || Number(body?.contenttype) !== 0
          ? Buffer.from(body?.content, 'base64').toString()
          : decodeLyrics(body.content);
      }

      resolve({
        status: 200,
        body: body,
        cookie: [],
        headers: {},
      });
    } catch (e) {
      reject({
        status: 502,
        body: { status: 400, error_code: 20010, info: 'Bad Request' },
        cookie: [],
        headers: {},
      });
    }
  });
};
