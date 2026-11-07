#ifndef RUNNER_FLOATING_LYRIC_WINDOW_H_
#define RUNNER_FLOATING_LYRIC_WINDOW_H_

#include <windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM

#include <cstdint>
#include <string>
#include <vector>

struct FloatingLyricWord { std::wstring text; int start_ms; int duration_ms; };

// Windows 桌面歌词：独立置顶工具窗口，不依赖 Android 悬浮窗服务。
//
// 与 Android `FloatingLyricService` 的行为对齐：
// - 歌词文字走**水平线性渐变**（gradientStart → gradientEnd），非纯色。
// - `opacity` 是**背板不透明度**（0~100），只作用于背板，文字始终全不透明。
//   0% 透出壁纸，100% 纯黑，中间线性。
// - 点击窗口展开/收起内嵌设置面板（配色、字号、行数、不透明度、锁定）。
// - 未锁定时可拖动窗口；**锁定只锁位置，不锁交互**（否则解锁按钮点不到）。
//
// ## 渲染管线：32bpp ARGB DIB + UpdateLayeredWindow
//
// 早期实现直接在窗口 DC 上 Paint，后果是两条硬伤：
//  1. 背板透明度做不到真透明。`CreateSolidBrush` 没有 alpha 通道，
//     而 `AlphaBlend` 的源若用 `CreateCompatibleBitmap`（DDB，无 alpha）
//     更是错得离谱——它只能靠 SourceConstantAlpha 整块变淡，
//     无法只淡背板而保文字。
//  2. **重影 + 越拖越黑**。`InvalidateRect(..., bErase=FALSE)` 不擦背景，
//     WM_PAINT 拿到的是上一帧残留；每帧在其上再叠一次半透明黑 / 再画一次
//     文字，就累积成截图里的"文字重影、背景越来越黑"（opacity 拖到 0 也黑，
//     因为残留已经叠了 N 层黑）。
//
// 现在统一渲染到一块 **32bpp ARGB 的 DIBSection**，逐像素写入 alpha：
// 背板写 `(alpha_percent, 0, 0, 0)`，文字写 `0xFF` alpha 的渐变色，
// 面板写不透明深色。最后一次性 `UpdateLayeredWindow` 提交。
// 每帧先 `memset` 整个位图为全透明，绝无残留可能。
class FloatingLyricWindow {
 public:
  ~FloatingLyricWindow();

  /// 配置回调：面板里的控件改动后回调 Dart 侧落盘 + 重新下发。
  /// 参数为 Dart 侧 `DesktopLyricService` 的字段名对应的 snake_case。
  using ConfigCallback = void (*)(void* user_data, const char* key, int value);

  /// 创建并显示悬浮歌词窗口。父窗口用于首次定位（取其所在显示器）。
  /// 返回 false 表示窗口创建失败。
  bool Start(HWND owner, const std::wstring& lyric, const std::wstring& title);

  void Stop();
  void UpdateLyric(const std::wstring& lyric, const std::wstring& next,
                   const std::vector<FloatingLyricWord>& words, int position_ms);
  void UpdateProgress(int position_ms);
  void UpdatePlaying(bool playing);
  void UpdateTitle(const std::wstring& title);

  /// 下发完整配置。参数与 Dart 侧 `setDesktopLyricConfig` 的字段一一对应。
  void SetConfig(double font_size, double display_scale, bool double_line,
                 int opacity, bool locked, std::uint32_t gradient_start,
                 std::uint32_t gradient_end, std::uint32_t unplayed_color,
                 int color_mode, std::uint32_t custom_start,
                 std::uint32_t custom_end, std::uint32_t custom_unplayed,
                 bool allow_horizontal_move = true);

  void SetConfigCallback(ConfigCallback callback, void* user_data);

  /// 覆盖位置持久化用的注册表键（默认 `Software\MD3Music\FloatingLyric`）。
  ///
  /// 存在的理由：独立 C++ 探针（tmp/floating_lyric_probe.cpp）会真实调用
  /// 拖动与持久化，若与生产共用一个键，测试就会把窗口位置写进用户的
  /// 真实注册表 —— 上线后每次开 App 都被吸到 (0,0)（左上角），
  /// 症状正是"固定在左上角不能移动"。探针应先 `SetPositionKey(kProbeKey)`
  /// 再跑，测试数据与用户数据彻底隔离。
  void SetPositionKey(const wchar_t* key) { position_key_ = key; }

 private:
  /// 内嵌设置面板高度（像素）。窗口展开面板时高度 +该值，
  /// LayoutButtons / HitTestPanel / Position 三处共用，避免尺寸走偏。
  static constexpr int kPanelHeight = 150;

  /// 设置面板控件数量（4 预设 + A− + A+ + 单双行 + 锁定 + 滑杆）。
  static constexpr int kControlCount = 9;

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  /// 渲染一帧到 ARGB 位图并提交到屏幕。尺寸变化时重建位图。
  void Paint();
  void PaintPanel(HDC dc, const RECT& rect);
  void PaintButton(HDC dc, const RECT& rect, const std::wstring& label,
                   bool active, bool hovered);
  bool EnsureBitmap(int width, int height);
  void ReleaseBitmap();

  /// 32bpp ARGB 位图与内存 DC。`bitmap_size_` 记录已分配尺寸，
  /// 窗口尺寸变化时才重建（每帧重建会明显掉帧）。
  ///
  /// `mem_bmp_old_` 必须是 HGDIOBJ：`SelectObject` 返回 HGDIOBJ(void*)，
  /// 声明成 HBITMAP 无法隐式转换（C2440）。
  HDC mem_dc_ = nullptr;
  HBITMAP mem_bmp_ = nullptr;
  HGDIOBJ mem_bmp_old_ = nullptr;
  std::uint32_t* pixels_ = nullptr;
  int bitmap_w_ = 0;
  int bitmap_h_ = 0;

  void Position(HWND owner);
  bool HitTestPanel(int x, int y) const;
  bool HitTestButton(int x, int y, int index) const;
  void OnPanelClick(int x, int y);
  void OnPanelDrag(int x, int y, bool pressed);
  void LayoutButtons();
  void Invalidate();
  void ApplyInteractionStyle();
  void Emit(const char* key, int value);
  void BeginDrag(HWND window);
  void PersistPosition();
  /// 从注册表恢复上次拖动后的位置（带可见性校验）。
  /// 返回 false 表示无可用记录或记录已失效，调用方应回退到默认位置。
  bool RestorePosition(int width, int height);

  HWND window_ = nullptr;
  std::wstring lyric_;
  std::wstring next_;
  std::wstring title_;
  std::vector<FloatingLyricWord> words_;
  int position_ms_ = 0;
  ULONGLONG position_tick_ = 0;
  bool playing_ = false;

  // ---- 配置（与 Dart 侧字段一一对应） ----
  double font_size_ = 40.0;
  double display_scale_ = 1.0;
  bool double_line_ = true;
  /// 背板不透明度 0~100。0 = 完全透出壁纸，100 = 纯黑。
  int opacity_ = 50;
  bool locked_ = false;
  bool allow_horizontal_move_ = true;
  std::uint32_t gradient_start_ = 0xFF00E5FF;
  std::uint32_t gradient_end_ = 0xFFFF00FF;
  std::uint32_t unplayed_color_ = 0xFFFFFFFF;
  /// 0 = 预设，1 = 自定义。
  int color_mode_ = 0;
  std::uint32_t custom_start_ = 0xFF00E5FF;
  std::uint32_t custom_end_ = 0xFFFF00FF;
  std::uint32_t custom_unplayed_ = 0xFFFFFFFF;

  ConfigCallback config_callback_ = nullptr;
  void* config_callback_data_ = nullptr;

  // ---- 交互状态 ----
  /// 设置面板是否展开。
  bool panel_expanded_ = false;
  bool dragging_ = false;
  bool hover_button_ = false;
  int pressed_button_ = -1;
  POINT drag_offset_{0, 0};
  int drag_origin_x_ = 0;
  /// 拖动滑杆时的临时值，松手才落盘。
  int dragging_opacity_ = -1;
  /// 按下时的位置；与松手位置比对判定"点击"还是"拖动窗口"。
  POINT press_point_{0, 0};
  /// 位移超过该像素数才算拖动（Windows 的 click 定义约 4px）。
  static constexpr int kDragThreshold = 4;

  /// 是否已完成过首次定位。
  ///
  /// Position() 会被 Start / SetConfig / 面板展开频繁调用（歌词每更新一次
  /// 就可能走一遍 SetConfig），若无条件重算 x/y，用户刚拖到屏幕左上角就会
  /// 被立刻拽回"底部居中"，表现为"固定在左上角不能移动"。
  /// 为true 之后 Position() 只改尺寸（SWP_NOMOVE），位置交给用户。
  /// Stop() 时重置，下次开启重新居中。
  bool positioned_ = false;
  /// 位置持久化的注册表键。默认指向生产键；探针会覆盖成独立键，
  /// 避免测试把用户窗口位置写坏。详见 SetPositionKey。
  const wchar_t* position_key_ = nullptr;

  /// 面板控件命中区，**客户区坐标**（由 LayoutButtons() 依据 GetClientRect 填充）。
  /// 索引含义见 .cpp 的 `enum ButtonIndex`。
  RECT button_rects_[kControlCount]{};
  int button_count_ = 0;

  /// 字号数值的绘制区（不是按钮，只显示当前字号）。
  RECT font_value_rect_{};

 public:
  /// 最近一次收到的鼠标消息（诊断用）。
  ///
  /// 排查"点了没反应"时，光看行为无法区分「消息没进来」与「进来了但
  /// 判定条件不满足」——这两者的修法完全不同。暴露出来让测试能直接断言。
  UINT last_mouse_message() const { return last_mouse_message_; }

  /// 设置面板当前是否展开（诊断用）。
  bool panel_expanded() const { return panel_expanded_; }

  /// 诊断：最近一次 WM_LBUTTONUP 时各判定输入的快照。
  bool diag_dragging() const { return diag_dragging_; }
  int diag_pressed() const { return diag_pressed_; }
  int diag_moved() const { return diag_moved_ ? 1 : 0; }

  /// 诊断：ARGB 位图某点是否已写入内容（用于验证"透明区确实是透明的"）。
  bool PixelHasContent(int x, int y) const {
    return PixelAlpha(x, y) != 0;
  }

  /// 诊断：读回 ARGB 位图某点的 alpha 分量（0~255）。
  /// 验证背板半透明度必须用它 —— 只看"有没有内容"无法区分
  /// "1% 的半透明"与 "100% 的全黑"，两者都只是"非零"。
  int PixelAlpha(int x, int y) const {
    if (pixels_ == nullptr) return 0;
    if (x < 0 || y < 0 || x >= bitmap_w_ || y >= bitmap_h_) return 0;
    return static_cast<int>((pixels_[y * bitmap_w_ + x] >> 24) & 0xFFu);
  }

 private:
  UINT last_mouse_message_ = 0;
  bool diag_dragging_ = false;
  int diag_pressed_ = -99;
  bool diag_moved_ = false;
};

#endif  // RUNNER_FLOATING_LYRIC_WINDOW_H_
