// 搜索歌手 - 使用搜索歌曲接口，解析歌手信息
module.exports = (params, useAxios) => {
  const keyword = params?.keyword || params?.keywords || '';
  const page = params?.page || 1;
  const pagesize = params?.pagesize || 20;

  const dataMap = {
    keyword,
    page,
    pagesize,
    showtype: 14,
    highlight: 'em',
    tag_aggr: 1,
    tagtype: '全部',
    plat: 0,
    sver: 5,
    correct: 1,
    api_ver: 1,
    area_code: 1,
    tag: 1,
  };

  return useAxios({
    url: '/api/v3/search/song',
    method: 'GET',
    params: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'x-router': 'msearchcdn.kugou.com' },
  });
};
