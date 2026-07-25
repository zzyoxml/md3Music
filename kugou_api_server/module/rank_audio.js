// 获取排行榜音乐列表
module.exports = (params, useAxios) => {
  const dataMap = {
    show_portrait_mv: 1,
    show_type_total: 1,
    filter_original_remarks: 1,
    area_code: 1,
    pagesize: params.pagesize || 30,
    rank_cid: params.rank_cid || 0,
    type: 1,
    page: params.page || 1,
    rank_id: params.rankid,
  };
  return useAxios({
    url: '/openapi/kmr/v2/rank/audio',
    method: 'post',
    data: dataMap,
    encryptType: 'android',
    cookie: params?.cookie || {},
    headers: { 'kg-tid': '369' },
  }).then((res) => {
    if (!res || !res.body) return res;
    const body = res.body;
    // kmr/v2 API 返回的歌曲数据可能使用嵌套结构（base/audio_info/authors/album_info），
    // 转换为扁平结构，确保前端 KugouSongDetail.fromJson 能正确解析 album_name 等字段。
    const songs = body?.data?.songlist || body?.data?.list || body?.data?.songs || [];
    if (Array.isArray(songs) && songs.length > 0) {
      const transformed = songs.map((s) => {
        // 如果已经是扁平格式（有 songname/hash），直接返回
        if (s.songname || s.SongName || s.filename) return s;

        const ai = s.audio_info || {};
        const base = s.base || {};
        const authors = s.authors || [];
        const albumInfo = s.album_info || {};
        const singerinfo = authors.map((a) => ({
          name: a.author_name || '',
          id: a.author_id || 0,
        }));
        return {
          hash: ai.hash || s.hash || '',
          songname: base.audio_name || s.songname || '',
          author_name: authors.map((a) => a.author_name || '').join(',') || s.author_name || '',
          singerinfo,
          album_id: base.album_id || s.album_id || '',
          album_name: albumInfo.album_name || s.album_name || '',
          album_audio_id: base.album_audio_id || s.album_audio_id || '',
          duration: ai.duration || s.duration || 0,
          filesize: ai.filesize || s.filesize || 0,
          bitrate: ai.bitrate || s.bitrate || 128,
          hash_128: ai.hash_128 || ai.hash || s.hash_128 || '',
          hash_320: ai.hash_320 || s.hash_320 || '',
          hash_flac: ai.hash_flac || s.hash_flac || '',
          cover: albumInfo.cover || s.cover || '',
          sizable_cover: albumInfo.sizable_cover || s.sizable_cover || '',
          audio_id: base.audio_id || s.audio_id || 0,
          privilege: s.copyright?.privilege || s.privilege || 0,
        };
      });
      if (body.data.songlist) {
        body.data.songlist = transformed;
      } else if (body.data.list) {
        body.data.list = transformed;
      } else if (body.data.songs) {
        body.data.songs = transformed;
      } else {
        body.data.songlist = transformed;
      }
    }
    return res;
  });
};
