module.exports = (params, useAxios) => {
  const keyword = params?.keywords || params?.keyword || '';
  const page = params?.page || 1;
  const pagesize = params?.pagesize || 30;

  const dataMap = {
    keyword,
    page,
    pagesize,
    platform: 'WebFilter',
    iscorrection: 1,
    albumhide: 0,
    nocollect: 0,
  };

  return useAxios({
    url: '/song_search_v2',
    method: 'GET',
    params: dataMap,
    encryptType: 'android',
    headers: { 'x-router': 'songsearch.kugou.com' },
    cookie: params?.cookie || {},
  });
};
