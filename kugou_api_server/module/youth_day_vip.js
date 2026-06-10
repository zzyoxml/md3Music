// 领取vip(领取一天) 需要登录
// 官方 KuGouMusicApi 标准用法: POST
// receive_day 在 query.body 里 (因为是 POST body)
// data 必须与 body 严格一致, 否则服务端验签失败 (20006)
module.exports = (params, useAxios) => {
  // body 在 query.body (server.js 把 req.body 合并到 query.body)
  const receiveDay = params?.body?.receive_day || params?.receive_day;
  return useAxios({
    url: '/youth/v1/recharge/receive_vip_listen_song',
    encryptType: 'android',
    method: 'post',
    params: { source_id: 90139, receive_day: receiveDay },
    // 把 data 也传进去, 这样后端签名时知道 body 内容
    data: { receive_day: receiveDay },
    cookie: params?.cookie,
  });
};
