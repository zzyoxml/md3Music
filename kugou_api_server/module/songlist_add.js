// 收藏专辑 - 使用 /v2/songlist/add 接口
const { createRequest } = require('../util/request');

module.exports = (params, useAxios) => {
  const userid = params?.cookie?.userid || params?.userid || 0;
  const token = params?.cookie?.token || params?.token || '';

  const dataMap = {
    userid,
    token,
    name: params.name || '',
    type: params.type || 1,
    source: params.source || 2,
    is_pri: 0,
    list_create_userid: params.list_create_userid || 0,
    list_create_listid: params.list_create_listid || 0,
    list_create_gid: params.list_create_gid || '',
    total_ver: 0,
    from_shupinmv: 0,
  };

  console.log('[songlist_add] dataMap:', JSON.stringify(dataMap));

  return useAxios({
    url: '/v2/songlist/add',
    data: dataMap,
    method: 'post',
    encryptType: 'android',
    cookie: params?.cookie || {},
  }).catch(err => {
    // 打印上游 API 的完整错误信息
    console.error('[songlist_add] upstream error:', JSON.stringify(err?.body || err?.message || err));
    throw err;
  });
};
