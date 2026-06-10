const { srcappid } = require("../util");

//升级vip
// 已确认: 扫码 token 无权调此接口, 需切换登录方式
module.exports = (params, useAxios) => {
  const paramsMap = {
    kugouid: Number(params?.userid || params?.cookie?.userid || 0),
    ad_type: 1,
  }

  return useAxios({
    url: '/youth/v1/listen_song/upgrade_vip_reward',
    encryptType: 'android',
    method: 'post',
    params: paramsMap,
    cookie: params?.cookie,
  });
};
