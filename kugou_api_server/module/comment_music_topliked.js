// 歌曲评论-最热（按点赞数降序）
//
// 上游 /mcomment/r/v1/rank/topliked 是客户端「最热」标签页背后的接口，返回全局
// 按点赞数降序的评论排名，并支持翻页继续往下排；/comment/music（cmtlist）返回的
// 是加权混排，与点赞数无关，同一页内点赞数可能是 198、986、77，因此不能靠客户端
// 对单页重排来代替本接口。
//
// 必传 childrenid（评论区 id，即 cmtlist 响应顶层的 childrenid、也就是评论项的
// special_child_id）。上游不接受用 mixsongid 代替 childrenid，只传 mixsongid 会
// 返回 err_code=10002「参数错误」。
module.exports = (params, useAxios) => {

  const paramsMap = {
    childrenid: params?.childrenid || params?.special_id || params?.id,
    need_show_image: 1,
    p: params.page || 1,
    pagesize: params.pagesize || 30,
    extdata: '0',
    code: 'fc4be23b4e972707f36b8a828a93ba8a'
  }

  return useAxios({
    url: '/mcomment/r/v1/rank/topliked',
    encryptType: 'android',
    method: 'POST',
    params: paramsMap,
    cookie: params?.cookie || {},
  });
};
