const { srcappid, appid } = require('../util');

// 酷狗二维码状态检测
// 0 为二维码过期，1 为等待扫码，2 为待确认，4 为授权登录成功（4 状态码下会返回 token）
module.exports = (params, useAxios) => {
  return new Promise((resolve, reject) => {
    useAxios({
      baseURL: 'https://login-user.kugou.com',
      url: '/v2/get_userinfo_qrcode',
      method: 'GET',
      params: { plat: 4, appid, srcappid, qrcode: params?.key },
      encryptType: 'web',
      cookie: params?.cookie || {},
    }).then(resp => {
      if (resp.body?.data?.status == 4) {
        resp.cookie.push(`token=${resp.body?.data?.token}`);
        resp.cookie.push(`userid=${resp.body?.data?.userid}`);
        if (!resp.body.token) resp.body.token = resp.body.data.token;
        if (!resp.body.userid) resp.body.userid = resp.body.data.userid;
        // 概念版 VIP 必须带 vip_token，否则 /v6/priv_url 会降级为试听。
        if (resp.body?.data?.vip_token) {
          resp.cookie.push(`vip_token=${resp.body.data.vip_token}`);
          if (!resp.body.vip_token) resp.body.vip_token = resp.body.data.vip_token;
        }
        if (resp.body?.data?.vip_type != null) {
          resp.cookie.push(`vip_type=${resp.body.data.vip_type}`);
          if (resp.body.vip_type == null) resp.body.vip_type = resp.body.data.vip_type;
        }
      }
      resolve(resp);
    }).catch(e => reject(e));
  });
};
