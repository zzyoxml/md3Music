/// 胶囊文案「逐字擦出」的共用公式。
///
/// 顶栏尾部胶囊（`lib/widgets/player_top_bar_actions.dart`）与发现页的问候胶囊
/// （`lib/modules/discover/discover_page.dart`）都按这条公式给每个字算 alpha：
/// 第 i 个字在 reveal 的 `[0.7·i/n, 0.7·i/n + 0.3]` 区间淡入，相邻字重叠半拍，
/// 于是形成从左到右的级联；收回时同一函数自然镜像成自右向左逐字渐隐。
///
/// 两处**只共用这一条数学**，擦出时长各自决定（顶栏 240/160ms，问候胶囊 720ms）：
/// 前者每次点击都要播，短；后者一次 App 运行只播一遍，可以慢。
library;

double labelCharAlpha(double reveal, int i, int n) {
  if (n <= 0) return 0;
  final start = 0.7 * i / n;
  return ((reveal - start) / 0.3).clamp(0.0, 1.0);
}
