// 领取一天VIP（需要登录）
module.exports = (params, useAxios) => {
  const receiveDay = params?.body?.receive_day || params?.receive_day;
  console.log('[CLAIM_VIP] 请求:', JSON.stringify({
    receive_day: receiveDay,
    userid: params?.cookie?.userid,
    token: params?.cookie?.token ? '(已设置)' : '(未设置)',
  }));
  return useAxios({
    url: '/youth/v1/recharge/receive_vip_listen_song',
    encryptType: 'android',
    method: 'post',
    params: { source_id: 90139, receive_day: receiveDay },
    data: { receive_day: receiveDay },
    cookie: params?.cookie,
  }).then((res) => {
    console.log('[CLAIM_VIP] 酷狗返回:', JSON.stringify(res?.body || res)?.substring(0, 500));
    return res;
  }).catch((err) => {
    console.log('[CLAIM_VIP] 请求异常:', err?.message || err);
    throw err;
  });
};
