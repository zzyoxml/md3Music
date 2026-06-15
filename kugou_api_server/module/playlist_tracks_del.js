// 对歌单删除歌曲
// listid, fileids(支持 fileid 或 hash，逗号分隔)

module.exports = (params, useAxios) => {
  const userid = params?.userid || params?.cookie?.userid || 0;
  const token = params?.token || params?.cookie?.token || '';
  const clienttime = Math.floor(Date.now() / 1000);

  const fileids = params.fileids || '';
  const resource = fileids.split(',').filter(Boolean).map((s) => {
    const num = Number(s);
    if (!isNaN(num) && num > 0) {
      return { fileid: num };
    }
    return { fileid: 0, hash: s };
  });

  const dataMap = {
    listid: params.listid,
    userid,
    data: resource,
    type: 0,
    token,
    list_ver: 0,
  };

  return useAxios({
    url: '/cloudlist.service/v4/delete_songs',
    data: dataMap,
    params: { last_time: clienttime, last_area: 'gztx', userid, token },
    method: 'post',
    encryptType: 'android',
    cookie: params?.cookie || {},
  });
};
