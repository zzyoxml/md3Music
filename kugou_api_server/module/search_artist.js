// 搜索歌手 - 使用歌手搜索接口，返回 singername + singerid
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
    plat: 0,
    sver: 5,
  };

  return useAxios({
    url: '/api/v3/search/singer',
    method: 'GET',
    params: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'x-router': 'msearchcdn.kugou.com' },
  });
};
