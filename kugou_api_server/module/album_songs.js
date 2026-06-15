// 专辑音乐列表
module.exports = (params, useAxios) => {
  const dataMap = {
    album_id: params.album_id || params.id,
    is_buy:  params?.is_buy || '',
    page: params?.page || 1,
    pagesize: params?.pagesize || 30,
  };

  return useAxios({
    url: '/v1/album_audio/lite',
    method: 'POST',
    data: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'x-router': 'openapi.kugou.com', 'kg-tid': '255' },
  }).then((res) => {
    if (!res || !res.body) return res;
    const body = res.body;
    const songs = body?.data?.songs || [];
    if (Array.isArray(songs)) {
      body.data.songs = songs.map((s) => {
        const ai = s.audio_info || {};
        const base = s.base || {};
        const authors = s.authors || [];
        const albumInfo = s.album_info || {};
        const singerinfo = authors.map((a) => ({
          name: a.author_name || '',
          id: a.author_id || 0,
        }));
        return {
          hash: ai.hash || '',
          songname: base.audio_name || '',
          author_name: authors.map((a) => a.author_name || '').join(','),
          singerinfo,
          album_id: base.album_id || '',
          album_name: albumInfo.album_name || '',
          album_audio_id: base.album_audio_id || '',
          duration: ai.duration || 0,
          filesize: ai.filesize || 0,
          bitrate: ai.bitrate || 128,
          hash_128: ai.hash_128 || ai.hash || '',
          hash_320: ai.hash_320 || '',
          hash_flac: ai.hash_flac || '',
          cover: albumInfo.cover || '',
          audio_id: base.audio_id || 0,
          privilege: s.copyright?.privilege || 0,
        };
      });
    }
    return res;
  });
};
