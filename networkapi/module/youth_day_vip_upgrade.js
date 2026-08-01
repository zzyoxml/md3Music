// 升级概念版VIP（需要登录，需要先领取一天VIP）
module.exports = (params, useAxios) => {
  const paramsMap = {
    kugouid: Number(params?.userid || params?.cookie?.userid || 0),
    ad_type: 1,
  };

  console.log('[UPGRADE_VIP] 请求参数:', JSON.stringify({
    kugouid: paramsMap.kugouid,
    ad_type: paramsMap.ad_type,
    hasCookie: !!params?.cookie,
    userid: params?.cookie?.userid,
    token: params?.cookie?.token ? '(已设置)' : '(未设置)',
    vipToken: params?.cookie?.vip_token ? '(已设置)' : '(未设置)',
  }));

  return useAxios({
    url: '/youth/v1/listen_song/upgrade_vip_reward',
    encryptType: 'android',
    method: 'post',
    params: paramsMap,
    cookie: params?.cookie,
  }).then((res) => {
    console.log('[UPGRADE_VIP] 酷狗返回:', JSON.stringify(res?.body || res)?.substring(0, 500));
    return res;
  }).catch((err) => {
    console.log('[UPGRADE_VIP] 请求异常:', err?.message || err);
    throw err;
  });
};
