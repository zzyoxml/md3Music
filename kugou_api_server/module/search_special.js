// 搜索歌单
module.exports = (params, useAxios) => {
  const keyword = params?.keyword || params?.keywords || '';
  const page = params?.page || 1;
  const pagesize = params?.pagesize || 20;

  const dataMap = {
    keyword,
    page,
    pagesize,
    filter: 0,
    highlight: 'em',
  };

  return useAxios({
    url: '/api/v3/search/special',
    method: 'GET',
    params: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'x-router': 'mobilecdnbj.kugou.com' },
  });
};
