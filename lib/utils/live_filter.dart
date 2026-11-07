import '../data/models/song.dart';

/// 「过滤 Live/现场版本」的标题识别（MD3 fork）。
///
/// 酷狗曲库没有可直接判别的来源标志位（Song 上无 type/remark），只能靠标题
/// 启发式，分三支：
/// ① 括号内的 live：`(Live)`、`(Live at Wembley)`、`（Live 2020）`——括号里
///    Live 无论跟什么都按现场版（该形态几乎不会是正经歌名）；
/// ② 无括号的独立 live 词：前面必须是分界（行首/空白/横杠/斜杠），后面到
///    下一个中文字符之前不允许出现英文字母——`Live and Let Die`、`Livehouse`、
///    `Live, Laugh, Love` 这类 Live 开头的正经歌名不再误伤，而
///    ` - Live`、` - Live 2020`、`Live版` 照常命中；
/// ③ 独立的现场词：`(现场)`、`(现场版)`、`现场版`、` - 现场`、`/现场`。
/// ponytail: 仍是标题启发式（事实:无 API 标志位），无括号裸标题
/// `Live at Wembley`（Live 后接英文场地短语且整题不进括号）不覆盖，出现
/// 真实误伤/漏网样本后再迭代。
final RegExp liveTitlePattern = RegExp(
  // ① 括号内 live：内部跟什么都算，以配对的收括号收尾
  r'[\[（(【]\s*live(?:版|本)?(?:\s+[^)）)】\]】]*?)?\s*[)）)】\]】]'
  // ② 无括号独立 live 词：core 后到下一个中文字符之间不允许英文字母
  r'|(?:^|[\s\-—–·\/|])live(?:版|本)?(?![^\u4e00-\u9fa5]*[A-Za-z])'
  r'(?:$|[\s\-—–·\/|，,。；;：:!！?？（(【\[)）\]】])'
  // ③ 现场词（中文标题里歧义低，后跟正文也按现场版处理）
  r'|(?:^|[\s（(【\[\-—–·\/|])现场(?:版|本)?\s*($|[\s\-—–·\/|（）()【\[\]】\]，,。；;：:!！?？])',
  caseSensitive: false,
);

/// 歌曲标题是否为 Live/现场版本（如 "XXX (Live)"、"XXX - Live"、
/// "XXX (现场版)"、"XXX (Live at Wembley)"）。
bool isLiveSong(Song song) => liveTitlePattern.hasMatch(song.displayName);
