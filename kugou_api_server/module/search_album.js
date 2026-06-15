// 搜索专辑
module.exports = (params, useAxios) => {
  const keyword = params?.keyword || params?.keywords || '';
  const page = params?.page || 1;
  const pagesize = params?.pagesize || 20;

  const dataMap = {
    keyword,
    page,
    pagesize,
    iscorrection: 1,
    highlight: 'em',
    plat: 0,
  };

  return useAxios({
    url: '/api/v3/search/album',
    method: 'GET',
    params: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'x-router': 'msearch.kugou.com' },
  });
};
