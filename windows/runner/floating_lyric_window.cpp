#include "floating_lyric_window.h"

#include <windows.h>

#include <cstddef>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>

namespace {

constexpr wchar_t kWindowClass[] = L"MD3MUSIC_FLOATING_LYRIC";

/// GDI 笔迹标记色（RGB，alpha 恒为 0）。
///
/// 整帧先填成这个色，GDI 以 TRANSPARENT 背景绘制后，
/// 「RGB 不再等于它」即精确代表「GDI 在此画过」。选一个现实中
/// 不可能出现在文字里的值（RGB = 1,2,3）避免误判。
constexpr std::uint32_t kDrawMarker = 0x00010203u;

/// 配色预设，与 Dart 侧 `DesktopLyricService.gradientPresets` 逐项一致。
struct PresetColor {
  std::uint32_t start;
  std::uint32_t end;
};
const PresetColor kPresets[] = {
    {0xFF00E5FF, 0xFFFF00FF},  // 青 → 洋红（默认）
    {0xFFFF4081, 0xFFFFC400},  // 粉 → 琥珀
    {0xFF00E676, 0xFF00B0FF},  // 绿 → 天蓝
    {0xFFFFFFFF, 0xFFFFFFFF},  // 纯白
};
constexpr int kPresetCount = 4;

/// 面板命中区索引（LayoutButtons 填充 button_rects_ 的顺序）。
enum ButtonIndex {
  kBtnPreset0 = 0,   // 0..3：4 个配色预设
  kBtnFontMinus = 4,  // 字号 −
  kBtnFontPlus = 5,   // 字号 +
  kBtnDoubleLine = 6, // 单双行切换
  kBtnLock = 7,       // 锁定
  kBtnOpacity = 8,    // 不透明度滑杆
  kBtnCount = 9,
};

/// ARGB 拆成 A/R/G/B 分量。
struct Argb {
  int a, r, g, b;
};

Argb SplitArgb(std::uint32_t argb) {
  Argb c;
  c.a = static_cast<int>((argb >> 24) & 0xff);
  c.r = static_cast<int>((argb >> 16) & 0xff);
  c.g = static_cast<int>((argb >> 8) & 0xff);
  c.b = static_cast<int>(argb & 0xff);
  return c;
}

/// 两个 ARGB 之间线性插值，t ∈ [0, 1]。
COLORREF LerpArgb(std::uint32_t from, std::uint32_t to, double t) {
  const Argb a = SplitArgb(from);
  const Argb b = SplitArgb(to);
  const auto mix = [t](int x, int y) {
    return static_cast<int>(x + (y - x) * t + 0.5);
  };
  return RGB(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b));
}

/// 限制到 [low, high]。自实现而非 std::clamp / std::min：windows.h 在未定义
/// NOMINMAX 时会注入 min/max 宏把调用改写成非法表达式，本文件的编译正确性
/// 不应依赖 CMake 里的 target_compile_definitions。
int ClampInt(int value, int low, int high) {
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

double ClampDouble(double value, double low, double high) {
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

/// GDI 绘制「笔迹标记色」：整帧 memset 成 RGB=标记色、alpha=0。
///
/// GDI 在 32bpp DIB 上只写 RGB、**从不写 alpha**。绘制前整块填成
/// 唯一的标记色（0x010203，现实中不可能是文字颜色），
/// `TRANSPARENT` 背景模式下 GDI 只会改写文字覆盖到的像素，
/// 于是「RGB 不再等于标记色」精确等价于「GDI 在这里画过东西」。
void ClearToMarker(std::uint32_t* pixels, int width, int height) {
  if (pixels == nullptr) return;
  const std::uint32_t total = static_cast<std::uint32_t>(width) * height;
  for (std::uint32_t i = 0; i < total; i++) {
    pixels[i] = kDrawMarker;
  }
}

/// 背板/面板：直接写 ARGB（含 alpha），会覆盖标记色。
void FillArgbRect(std::uint32_t* pixels, int width, int height, const RECT& r,
                  std::uint32_t argb) {
  if (pixels == nullptr) return;
  const int x0 = r.left < 0 ? 0 : r.left;
  const int y0 = r.top < 0 ? 0 : r.top;
  const int x1 = r.right > width ? width : r.right;
  const int y1 = r.bottom > height ? height : r.bottom;
  for (int y = y0; y < y1; y++) {
    std::uint32_t* row = pixels + static_cast<std::size_t>(y) * width;
    for (int x = x0; x < x1; x++) {
      row[x] = argb;
    }
  }
}

/// GDI 画完后，把「被画过」的像素 alpha 补成不透明。
///
/// 判据是「RGB 不再等于 [kDrawMarker]」。不能用 `rgb != 0` 判断：
/// 抗锯齿边缘的过渡像素很暗（可能是纯黑），漏判会让文字出现断裂/锯齿。
///
/// **必须跳过已由 [FillArgbRect] 写好的背板/面板区域**：
/// 背板是纯黑 RGB=0，不等于标记色，若一并提升成 alpha=255，
/// 半透明背板就变成了全黑 —— 表现为"不透明度 1% 也是全黑"
/// （0% 时 alpha 本就是 0，才看不出问题）。
/// 故判据加上「alpha 仍为 0」：只有"alpha 没被 FillArgbRect 写过、
/// 且 RGB 被 GDI 改过"的像素才是纯文字，才需要提升。
void PromoteDrawnPixels(std::uint32_t* pixels, int width, int height) {
  if (pixels == nullptr) return;
  const std::uint32_t total = static_cast<std::uint32_t>(width) * height;
  for (std::uint32_t i = 0; i < total; i++) {
    const std::uint32_t px = pixels[i];
    // alpha 非 0：这是 FillArgbRect 写的背板/面板，保留其原有不透明度。
    if ((px >> 24) != 0) continue;
    if ((px & 0x00FFFFFFu) == kDrawMarker) continue;  // 没被 GDI 碰过
    pixels[i] = 0xFF000000u | (px & 0x00FFFFFFu);
  }
}

/// 带水平线性渐变的居中文本。
///
/// GDI 没有「文字渐变」API（D2D/DirectWrite 才有），这里按字符测量宽度
/// 逐字符插值着色：视觉上与 Android 的 LinearGradient(0→width) 等价，
/// 且不需要给 Windows 桌面版引入 Direct2D/DirectWrite 依赖。
///
/// **必须用 ANTIALIASED_QUALITY 而非 CLEARTYPE_QUALITY**：ClearType 会把
/// alpha 通道写进 32bpp ARGB 位图（子像素抗锯齿要靠 alpha 合成），
/// 导致同一行文字出现"彩色描边 + 重影"。改用灰度抗锯齿后 alpha 由调用方
/// 的 `ForceOpaque` 统一补齐。
std::vector<std::wstring> WrapTextByChars(HDC dc, const std::wstring& text,
                                           int max_width) {
  std::vector<std::wstring> lines(1);
  int line_width = 0;
  for (size_t i = 0; i < text.size();) {
    if (text[i] == L'\r') {
      i++;
      continue;
    }
    if (text[i] == L'\n') {
      lines.emplace_back();
      line_width = 0;
      i++;
      continue;
    }
    std::wstring glyph(1, text[i++]);
    if (!glyph.empty() && glyph[0] >= 0xD800 && glyph[0] <= 0xDBFF &&
        i < text.size() && text[i] >= 0xDC00 && text[i] <= 0xDFFF) {
      glyph.push_back(text[i++]);
    }
    SIZE extent{};
    GetTextExtentPoint32W(dc, glyph.c_str(), static_cast<int>(glyph.size()),
                          &extent);
    const int glyph_width = extent.cx > 0 ? extent.cx : 1;
    if (!lines.back().empty() && line_width + glyph_width > max_width) {
      lines.emplace_back();
      line_width = 0;
    }
    lines.back() += glyph;
    line_width += glyph_width;
  }
  return lines;
}

struct TimedWordPart {
  std::wstring text;
  int width = 0;
  int word_index = 0;
  int char_offset = 0;
  int word_offset = 0;
  int word_width = 0;
};

using TimedLyricLine = std::vector<TimedWordPart>;

std::vector<TimedLyricLine> LayoutTimedWords(
    HDC dc, const std::vector<FloatingLyricWord>& words, int max_width) {
  std::vector<TimedLyricLine> lines(1);
  int line_width = 0;
  for (size_t word_index = 0; word_index < words.size(); word_index++) {
    const std::wstring& text = words[word_index].text;
    std::vector<TimedWordPart> fragments;
    TimedWordPart part;
    part.word_index = static_cast<int>(word_index);
    int word_char_offset = 0;
    for (size_t i = 0; i < text.size();) {
      std::wstring glyph(1, text[i++]);
      if (glyph[0] >= 0xD800 && glyph[0] <= 0xDBFF && i < text.size() &&
          text[i] >= 0xDC00 && text[i] <= 0xDFFF) {
        glyph.push_back(text[i++]);
      }
      SIZE extent{};
      GetTextExtentPoint32W(dc, glyph.c_str(), static_cast<int>(glyph.size()),
                            &extent);
      const int glyph_width = extent.cx > 0 ? extent.cx : 1;
      if (!part.text.empty() && part.width + glyph_width > max_width) {
        fragments.push_back(std::move(part));
        part = TimedWordPart{};
        part.word_index = static_cast<int>(word_index);
        part.char_offset = word_char_offset;
      }
      part.text += glyph;
      part.width += glyph_width;
      ++word_char_offset;
    }
    if (!part.text.empty()) fragments.push_back(std::move(part));
    for (auto& fragment : fragments) {
      SIZE extent{};
      GetTextExtentPoint32W(dc, fragment.text.c_str(),
                            static_cast<int>(fragment.text.size()), &extent);
      fragment.width = extent.cx > 0 ? extent.cx : 1;
    }
    int word_width = 0;
    for (const auto& fragment : fragments) word_width += fragment.width;
    int word_offset = 0;
    for (auto& fragment : fragments) {
      if (line_width > 0 && line_width + fragment.width > max_width) {
        lines.emplace_back();
        line_width = 0;
      }
      fragment.word_offset = word_offset;
      fragment.word_width = word_width;
      word_offset += fragment.width;
      line_width += fragment.width;
      lines.back().push_back(std::move(fragment));
    }
  }
  return lines;
}

/// 给浅色歌词加细暗色描边，避免桌面背景偏白时歌词融入背景。
void DrawReadableText(HDC dc, const std::wstring& text, RECT rect,
                      UINT format, COLORREF color) {
  constexpr int kOutlineOffsets[][2] = {
      {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1},
  };
  SetTextColor(dc, RGB(18, 18, 18));
  for (const auto& offset : kOutlineOffsets) {
    RECT outline_rect{rect.left + offset[0], rect.top + offset[1],
                      rect.right + offset[0], rect.bottom + offset[1]};
    DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &outline_rect,
              format);
  }
  SetTextColor(dc, color);
  DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &rect, format);
}

void DrawReadableTextLifted(HDC dc, const std::wstring& text, RECT rect,
                            UINT format, COLORREF color, double lift_px) {
  if (lift_px <= 0.001) {
    DrawReadableText(dc, text, rect, format, color);
    return;
  }
  const int saved = SaveDC(dc);
  if (SetGraphicsMode(dc, GM_ADVANCED) != 0) {
    XFORM transform{1.0f, 0.0f, 0.0f, 1.0f, 0.0f,
                    static_cast<FLOAT>(-lift_px)};
    if (SetWorldTransform(dc, &transform)) {
      DrawReadableText(dc, text, rect, format, color);
    } else {
      rect.top -= static_cast<int>(std::lround(lift_px));
      rect.bottom -= static_cast<int>(std::lround(lift_px));
      DrawReadableText(dc, text, rect, format, color);
    }
  } else {
    rect.top -= static_cast<int>(std::lround(lift_px));
    rect.bottom -= static_cast<int>(std::lround(lift_px));
    DrawReadableText(dc, text, rect, format, color);
  }
  RestoreDC(dc, saved);
}

void DrawGradientText(HDC dc, const std::wstring& text, RECT rect,
                      std::uint32_t start_color, std::uint32_t end_color,
                      int font_height) {
  if (text.empty()) return;
  SetBkMode(dc, TRANSPARENT);
  HFONT font = CreateFontW(font_height, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                           FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                           DEFAULT_PITCH, L"Microsoft YaHei UI");
  HGDIOBJ old_font = SelectObject(dc, font);

  TEXTMETRICW metrics{};
  GetTextMetricsW(dc, &metrics);
  const int line_height = metrics.tmHeight + metrics.tmExternalLeading;
  const auto lines = WrapTextByChars(dc, text, rect.right - rect.left);
  const int total_height = line_height * static_cast<int>(lines.size());
  int y = rect.top + ((rect.bottom - rect.top) - total_height) / 2;
  for (const auto& line : lines) {
    SIZE extent{};
    GetTextExtentPoint32W(dc, line.c_str(), static_cast<int>(line.size()),
                          &extent);
    const int total = extent.cx > 0 ? extent.cx : 1;
    int x = rect.left + ((rect.right - rect.left) - total) / 2;
    for (size_t i = 0; i < line.size();) {
      std::wstring glyph(1, line[i++]);
      if (glyph[0] >= 0xD800 && glyph[0] <= 0xDBFF && i < line.size() &&
          line[i] >= 0xDC00 && line[i] <= 0xDFFF) {
        glyph.push_back(line[i++]);
      }
      SIZE glyph_extent{};
      GetTextExtentPoint32W(dc, glyph.c_str(), static_cast<int>(glyph.size()),
                            &glyph_extent);
      const int glyph_width = glyph_extent.cx > 0 ? glyph_extent.cx : 1;
      const double t = ClampDouble((x + glyph_width / 2.0 - rect.left) / total,
                                   0.0, 1.0);
      RECT glyph_rect{x, y, x + glyph_width + 1, y + line_height};
      DrawReadableText(dc, glyph, glyph_rect,
                       DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
                       LerpArgb(start_color, end_color, t));
      x += glyph_width;
    }
    y += line_height;
  }

  SelectObject(dc, old_font);
  DeleteObject(font);
}

int WrappedTextLineCount(HDC dc, const std::wstring& text, int max_width) {
  return static_cast<int>(WrapTextByChars(dc, text, max_width).size());
}

int TimedTextLineCount(HDC dc, const std::vector<FloatingLyricWord>& words,
                       int max_width) {
  return static_cast<int>(LayoutTimedWords(dc, words, max_width).size());
}

void DrawWrappedText(HDC dc, const std::wstring& text, RECT rect,
                     std::uint32_t color, int font_height) {
  if (text.empty()) return;
  SetBkMode(dc, TRANSPARENT);
  HFONT font = CreateFontW(font_height, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                           FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                           DEFAULT_PITCH, L"Microsoft YaHei UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  TEXTMETRICW metrics{};
  GetTextMetricsW(dc, &metrics);
  const int line_height = metrics.tmHeight + metrics.tmExternalLeading;
  const auto lines = WrapTextByChars(dc, text, rect.right - rect.left);
  const int total_height = line_height * static_cast<int>(lines.size());
  int y = rect.top + ((rect.bottom - rect.top) - total_height) / 2;
  SetTextColor(dc, RGB((color >> 16) & 0xff, (color >> 8) & 0xff,
                       color & 0xff));
  for (const auto& line : lines) {
    RECT line_rect{rect.left, y, rect.right, y + line_height};
    DrawReadableText(dc, line, line_rect,
                     DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
                     RGB((color >> 16) & 0xff, (color >> 8) & 0xff,
                         color & 0xff));
    y += line_height;
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
}

double CubicBezierProgress(double t, double p1, double p2) {
  const double inverse = 1.0 - t;
  return 3.0 * inverse * inverse * t * p1 +
         3.0 * inverse * t * t * p2 + t * t * t;
}

int CountTimedGlyphs(const std::wstring& text) {
  int count = 0;
  for (size_t i = 0; i < text.size(); ++count) {
    if (text[i] >= 0xD800 && text[i] <= 0xDBFF && i + 1 < text.size() &&
        text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
      i += 2;
    } else {
      ++i;
    }
  }
  return count;
}

double AmGlyphLiftPx(const FloatingLyricWord& word, int position_ms,
                     int char_index, int char_count, int font_px,
                     bool is_last_word) {
  if (word.duration_ms <= 0 || char_count <= 0) return 0;
  const double duration = static_cast<double>(std::max(1000, word.duration_ms));
  const double char_delay = duration / 2.5 / char_count * char_index;
  const double word_de = word.start_ms + char_delay;
  const double bump_phase = (position_ms - word_de) / duration;
  const double float_phase =
      (position_ms - (word_de - 400.0)) / (duration * 1.4);
  const bool bump_active = bump_phase >= 0.0 && bump_phase <= 1.0;
  const bool float_active = float_phase >= 0.0 && float_phase <= 1.0;

  double edge_fade = 0.0;
  if (bump_active) {
    if (bump_phase < 0.15) {
      edge_fade = bump_phase / 0.15;
    } else if (bump_phase > 0.85) {
      edge_fade = (1.0 - bump_phase) / 0.15;
    } else {
      edge_fade = 1.0;
    }
  }
  const double float_em = float_active
      ? std::sin(3.14159265358979323846 * float_phase) * 0.075 * edge_fade
      : 0.0;

  double bump = 0.0;
  if (bump_active) {
    if (bump_phase < 0.5) {
      bump = CubicBezierProgress(bump_phase * 2.0, 0.2, 0.4);
    } else {
      bump = 1.0 - CubicBezierProgress((bump_phase - 0.5) * 2.0, 0.3, 0.0);
    }
  }
  double amount = std::min(1.2, std::sqrt(word.duration_ms / 2000.0) * 0.6);
  if (is_last_word) amount *= 1.6;
  // AM 的 0.05em 浮层提高到 0.075em，并保留其 0.025em 凸起。
  return (float_em + bump * amount * 0.025) * font_px;
}

void DrawTimedWords(HDC dc, const std::wstring& full_text,
                    const std::vector<FloatingLyricWord>& words,
                    int position_ms, RECT rect, std::uint32_t unplayed_color,
                    std::uint32_t gradient_start, std::uint32_t gradient_end,
                    int font_height) {
  if (words.empty()) {
    DrawGradientText(dc, full_text, rect, gradient_start, gradient_end,
                     font_height);
    return;
  }
  std::wstring joined;
  for (const auto& word : words) joined += word.text;
  if (joined != full_text) {
    DrawWrappedText(dc, full_text, rect, unplayed_color, font_height);
    return;
  }

  SetBkMode(dc, TRANSPARENT);
  HFONT font = CreateFontW(font_height, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                           FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                           DEFAULT_PITCH, L"Microsoft YaHei UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  TEXTMETRICW metrics{};
  GetTextMetricsW(dc, &metrics);
  const int line_height = metrics.tmHeight + metrics.tmExternalLeading;
  const int font_px = std::abs(font_height);
  const int max_width = rect.right - rect.left;
  const auto lines = LayoutTimedWords(dc, words, max_width);
  const int total_height = line_height * static_cast<int>(lines.size());
  int y = rect.top + ((rect.bottom - rect.top) - total_height) / 2;
  for (const auto& line : lines) {
    int line_width = 0;
    for (const auto& part : line) line_width += part.width;
    int x = rect.left + (max_width - line_width) / 2;
    for (const auto& part : line) {
      const auto& word = words[part.word_index];
      double progress = 0.0;
      if (word.duration_ms <= 0) {
        progress = position_ms >= word.start_ms ? 1.0 : 0.0;
      } else if (position_ms >= word.start_ms + word.duration_ms) {
        progress = 1.0;
      } else if (position_ms > word.start_ms) {
        progress = static_cast<double>(position_ms - word.start_ms) /
                   word.duration_ms;
      }
      const int char_count = CountTimedGlyphs(word.text);
      const int part_x = x;
      double glyph_word_offset = part.word_offset;
      int char_index = part.char_offset;
      for (size_t i = 0; i < part.text.size();) {
        std::wstring glyph(1, part.text[i++]);
        if (glyph[0] >= 0xD800 && glyph[0] <= 0xDBFF && i < part.text.size() &&
            part.text[i] >= 0xDC00 && part.text[i] <= 0xDFFF) {
          glyph.push_back(part.text[i++]);
        }
        SIZE extent{};
        GetTextExtentPoint32W(dc, glyph.c_str(), static_cast<int>(glyph.size()),
                              &extent);
        const int glyph_width = extent.cx > 0 ? extent.cx : 1;
        const double glyph_progress = ClampDouble(
            progress * part.word_width - glyph_word_offset, 0.0, glyph_width);
        const double reveal = glyph_progress / glyph_width;
        const double gradient_t = ClampDouble(
            (x + glyph_width / 2.0 - rect.left) / max_width, 0.0, 1.0);
        const COLORREF played = LerpArgb(gradient_start, gradient_end, gradient_t);
        const COLORREF unplayed = RGB((unplayed_color >> 16) & 0xff,
                                      (unplayed_color >> 8) & 0xff,
                                      unplayed_color & 0xff);
        const auto mix = [reveal](int from, int to) {
          return static_cast<int>(from + (to - from) * reveal + 0.5);
        };
        const double lift = AmGlyphLiftPx(
            word, position_ms, char_index, char_count, font_px,
            part.word_index == static_cast<int>(words.size()) - 1);
        RECT glyph_rect{x, y, x + glyph_width + 2, y + line_height};
        DrawReadableTextLifted(
            dc, glyph, glyph_rect,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
            RGB(mix(GetRValue(unplayed), GetRValue(played)),
                mix(GetGValue(unplayed), GetGValue(played)),
                mix(GetBValue(unplayed), GetBValue(played))),
            lift);
        glyph_word_offset += glyph_width;
        ++char_index;
        x += glyph_width;
      }
      x = part_x + part.width;
    }
    y += line_height;
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
}
}  // namespace

FloatingLyricWindow::~FloatingLyricWindow() { Stop(); }

void FloatingLyricWindow::SetConfigCallback(ConfigCallback callback,
                                             void* user_data) {
  config_callback_ = callback;
  config_callback_data_ = user_data;
}

bool FloatingLyricWindow::Start(HWND owner, const std::wstring& lyric,
                                const std::wstring& title) {
  lyric_ = lyric;
  title_ = title;
  next_.clear();
  if (!window_) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WndProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kWindowClass;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = nullptr;
    // **必须**注册 CS_DBLCLKS：不带这个样式系统不会产生 WM_LBUTTONDBLCLK，
    // 锁定态"双击解锁"的逃生出口就形同虚设。
    window_class.style = CS_DBLCLKS;
    if (!RegisterClassW(&window_class) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    // **必须**用 WS_EX_LAYERED + UpdateLayeredWindow：这是唯一能让
    // 「背板真透明而文字保持清晰」的组合。此前用"普通窗口 + AlphaBlend
    // 叠黑块"，结果每帧都在上一帧残留上再叠一层 → 文字重影、
    // 背景越拖越黑（opacity 拉到 0 也是黑的）。
    //
    // **不要**加 WS_EX_NOACTIVATE：带该扩展样式的窗口收不到
    // WM_LBUTTONDOWN / WM_MOUSEMOVE（系统只在窗口激活后才派发鼠标消息），
    // 表现为"点悬浮窗毫无反应"。改用 WS_EX_TOOLWINDOW（不进任务栏/Alt-Tab）。
    window_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, kWindowClass,
        L"MD3Music 桌面歌词", WS_POPUP, 0, 0, 800, 96, nullptr, nullptr,
        GetModuleHandleW(nullptr), this);
    if (!window_) return false;
    SetTimer(window_, 1, 16, nullptr);
    ApplyInteractionStyle();
    // 跟踪鼠标离开，才能清掉悬停高亮
    TRACKMOUSEEVENT track{};
    track.cbSize = sizeof(track);
    track.dwFlags = TME_LEAVE;
    track.hwndTrack = window_;
    TrackMouseEvent(&track);
  }
  Position(owner);
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  Invalidate();
  return true;
}

void FloatingLyricWindow::Stop() {
  if (window_) {
    KillTimer(window_, 1);
    DestroyWindow(window_);
    window_ = nullptr;
  }
  ReleaseBitmap();
  button_count_ = 0;
  // 下次开启重新居中（用户若想固定位置，可拖后再开设置面板锁定）
  positioned_ = false;
}

void FloatingLyricWindow::UpdateLyric(
    const std::wstring& lyric, const std::wstring& next,
    const std::vector<FloatingLyricWord>& words, int position_ms) {
  lyric_ = lyric;
  next_ = next;
  words_ = words;
  position_ms_ = position_ms;
  position_tick_ = GetTickCount64();
  Position(window_);
  Invalidate();
}

void FloatingLyricWindow::UpdateProgress(int position_ms) {
  const ULONGLONG now = GetTickCount64();
  if (playing_) {
    const int estimated = position_ms_ + static_cast<int>(now - position_tick_);
    // 播放时滤掉常见的小幅音频时钟抖动，避免已高亮的字瞬间退回；
    // 明显跳变（用户 seek / 切段）仍立即校准。
    const int correction = position_ms - estimated;
    if (correction < 0 && correction >= -750) {
      position_ms_ = estimated;
    } else if (correction >= 0 && correction <= 120) {
      position_ms_ = estimated;
    } else {
      position_ms_ = position_ms;
    }
  } else {
    position_ms_ = position_ms;
  }
  position_tick_ = now;
  Invalidate();
}

void FloatingLyricWindow::UpdatePlaying(bool playing) {
  if (playing_ && !playing) {
    position_ms_ += static_cast<int>(GetTickCount64() - position_tick_);
  }
  position_tick_ = GetTickCount64();
  playing_ = playing;
  Invalidate();
}

void FloatingLyricWindow::UpdateTitle(const std::wstring& title) {
  title_ = title;
  Position(window_);
  Invalidate();
}

void FloatingLyricWindow::SetConfig(double font_size, double display_scale,
                                    bool double_line, int opacity, bool locked,
                                    std::uint32_t gradient_start,
                                    std::uint32_t gradient_end,
                                    std::uint32_t unplayed_color,
                                    int color_mode, std::uint32_t custom_start,
                                    std::uint32_t custom_end,
                                    std::uint32_t custom_unplayed,
                                    bool allow_horizontal_move) {
  font_size_ = ClampDouble(font_size, 10.0, 100.0);
  display_scale_ = ClampDouble(display_scale, 0.85, 1.6);
  double_line_ = double_line;
  opacity_ = ClampInt(opacity, 0, 100);
  locked_ = locked;
  allow_horizontal_move_ = allow_horizontal_move;
  gradient_start_ = gradient_start;
  gradient_end_ = gradient_end;
  unplayed_color_ = unplayed_color;
  color_mode_ = color_mode;
  custom_start_ = custom_start;
  custom_end_ = custom_end;
  custom_unplayed_ = custom_unplayed;

  if (window_) {
    ApplyInteractionStyle();
    Position(window_);
    Invalidate();
  }
}

void FloatingLyricWindow::Emit(const char* key, int value) {
  if (config_callback_) config_callback_(config_callback_data_, key, value);
}

void FloatingLyricWindow::Invalidate() {
  if (window_) InvalidateRect(window_, nullptr, FALSE);
}

void FloatingLyricWindow::ApplyInteractionStyle() {
  if (!window_) return;
  LONG ex_style = GetWindowLongW(window_, GWL_EXSTYLE);
  // **刻意不加 WS_EX_TRANSPARENT**。
  // 加了就是死锁：解锁按钮在窗口内部，锁定后鼠标整体穿透 → 永远点不到。
  // Android 侧同样有这个坑（`FLAG_NOT_TOUCHABLE` + 面板在窗内，
  // 设置页注释里明写"代价是再也点不到它"，只能从 App 设置页解锁），
  // 但那套代价在桌面端没必要照搬：
  // 桌面歌词是用户主动摆的浮窗，锁定只该锁住**位置**，不应锁掉交互。
  //故 locked 只在 BeginDrag() 里阻止拖动，点击与面板照常可用。
  ex_style &= ~WS_EX_TRANSPARENT;
  SetWindowLongW(window_, GWL_EXSTYLE, ex_style);
}

void FloatingLyricWindow::Position(HWND owner) {
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(
          MonitorFromWindow(owner ? owner : window_, MONITOR_DEFAULTTOPRIMARY),
          &monitor_info)) {
    return;
  }
  const RECT& work = monitor_info.rcWork;
  const int work_width = static_cast<int>(work.right - work.left);
  const int work_height = static_cast<int>(work.bottom - work.top);
  int width = work_width - 40;
  if (width > 0 && width < 320) width = work_width;

  // 字号（正数语义）。GDI 的 CreateFontW 要负高度表示字符高度，
  // 但布局计算全程用正值——早期版本在这里直接用负的 font_height 做加法，
  // 导致高度算反（双行反而更矮），面板区也会跟着错位。
  const int font_px = ClampInt(
      static_cast<int>(font_size_ * display_scale_ + 0.5), 10, 160);
  int current_lines = 1;
  int next_lines = double_line_ ? 1 : 0;
  HDC measure_dc = GetDC(window_);
  HFONT measure_font = CreateFontW(-font_px, 0, 0, 0, FW_SEMIBOLD, FALSE,
                                   FALSE, FALSE, DEFAULT_CHARSET,
                                   OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                   ANTIALIASED_QUALITY, DEFAULT_PITCH,
                                   L"Microsoft YaHei UI");
  if (measure_dc && measure_font) {
    HGDIOBJ old_font = SelectObject(measure_dc, measure_font);
    const int text_width = width - 40;
    const std::wstring& shown = lyric_.empty() ? title_ : lyric_;
    std::wstring joined_words;
    for (const auto& word : words_) joined_words += word.text;
    current_lines = !words_.empty() && joined_words == shown
                        ? TimedTextLineCount(measure_dc, words_, text_width)
                        : WrappedTextLineCount(measure_dc, shown, text_width);
    if (double_line_ && !next_.empty()) {
      next_lines = WrappedTextLineCount(measure_dc, next_, text_width);
    }
    SelectObject(measure_dc, old_font);
  }
  if (measure_font) DeleteObject(measure_font);
  if (measure_dc) ReleaseDC(window_, measure_dc);
  if (current_lines < 1) current_lines = 1;
  if (next_lines < 1 && double_line_) next_lines = 1;
  TEXTMETRICW metrics{};
  HDC line_dc = GetDC(window_);
  HFONT line_font = CreateFontW(-font_px, 0, 0, 0, FW_SEMIBOLD, FALSE,
                                FALSE, FALSE, DEFAULT_CHARSET,
                                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                ANTIALIASED_QUALITY, DEFAULT_PITCH,
                                L"Microsoft YaHei UI");
  if (line_dc && line_font) {
    HGDIOBJ old_font = SelectObject(line_dc, line_font);
    GetTextMetricsW(line_dc, &metrics);
    SelectObject(line_dc, old_font);
  }
  if (line_font) DeleteObject(line_font);
  if (line_dc) ReleaseDC(window_, line_dc);
  const int line_height = metrics.tmHeight > 0
                              ? metrics.tmHeight + metrics.tmExternalLeading
                              : font_px + 8;
  int height = 24 + current_lines * line_height;
  if (double_line_) height += 8 + next_lines * line_height;
  if (panel_expanded_) height += kPanelHeight;
  if (height > work_height) height = work_height;

  // **位置归用户所有**：Position() 会被 Start / SetConfig / 面板展开频繁调用
  // （歌词每更新一次就可能走一遍 SetConfig），若无条件重算 x/y，
  // 用户刚拖到屏幕左上角就会被立刻拽回"底部居中" —— 表现为
  // "固定在左上角不能移动"。故只有首次显示时才定位，
  // 且优先恢复上次拖动后持久化的位置。
  if (!positioned_) {
    positioned_ = true;
    if (!RestorePosition(width, height)) {
      const int x = work.left + (work_width - width) / 2;
      const int y = work.bottom - height - 24;
      SetWindowPos(window_, HWND_TOPMOST, x, y, width, height,
                   SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
  } else {
    // 之后只更新尺寸，保留用户设定的位置（SWP_NOMOVE）。
    // 尺寸会随字号/歌词换行/单双行/面板展开变化，必须同步给窗口，
    // 否则 UpdateLayeredWindow 会按旧尺寸提交，画面被裁。
    RECT current_rect{};
    GetWindowRect(window_, &current_rect);
    SetWindowPos(window_, HWND_TOPMOST, current_rect.left, current_rect.top,
                 width, height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
  LayoutButtons();
}

void FloatingLyricWindow::LayoutButtons() {
  button_count_ = 0;
  if (!panel_expanded_ || !window_) return;

  RECT client{};
  GetClientRect(window_, &client);

  const int panel_top = client.bottom - kPanelHeight;
  const int margin = 14;
  const int btn_h = 26;

  // 第一行：4 个配色预设
  int x = margin;
  for (int i = 0; i < kPresetCount; i++) {
    button_rects_[i] = RECT{x, panel_top, x + 54, panel_top + btn_h};
    x += 54 + 8;
  }

  // 第二行：字号 − [数值] 字号 +，单双行 / 锁定靠右
  //
  // 布局要点：字号数值必须留出**独立可读宽度**，否则 A− 与 A+ 只隔几像素，
  // 数值被两边按钮压住，截图里就是"A-A+"糊成一团。
  const int row2 = panel_top + btn_h + 12;
  const int kFontBtnW = 40;
  const int kFontValW = 46;
  const int kGap = 8;

  const int font_minus_x = margin;
  const int font_val_x = font_minus_x + kFontBtnW + kGap;
  const int font_plus_x = font_val_x + kFontValW + kGap;
  button_rects_[kBtnFontMinus] =
      RECT{font_minus_x, row2, font_minus_x + kFontBtnW, row2 + btn_h};
  button_rects_[kBtnFontPlus] =
      RECT{font_plus_x, row2, font_plus_x + kFontBtnW, row2 + btn_h};
  button_count_ = kBtnFontPlus + 1;

  // 字号数值区（不是按钮，仅绘制；登记进来供 Paint 取宽度）
  font_value_rect_ = RECT{font_val_x, row2, font_val_x + kFontValW, row2 + btn_h};

  // 单双行 / 锁定：右对齐，避开左侧字号区
  const int kSideBtnW = 78;
  const int kSideGap = 10;
  const int lock_x = client.right - margin - kSideBtnW;
  const int line_x = lock_x - kSideGap - kSideBtnW;
  button_rects_[kBtnDoubleLine] = RECT{line_x, row2, line_x + kSideBtnW,
                                       row2 + btn_h};
  button_rects_[kBtnLock] = RECT{lock_x, row2, lock_x + kSideBtnW, row2 + btn_h};
  button_count_ = kBtnLock + 1;

  // 第三行：不透明度滑杆（整行可点/可拖）
  const int row3 = row2 + btn_h + 14;
  button_rects_[kBtnOpacity] =
      RECT{margin, row3, client.right - margin, row3 + 18};
  button_count_ = kBtnOpacity + 1;
}

bool FloatingLyricWindow::HitTestButton(int x, int y, int index) const {
  if (index < 0 || index >= button_count_) return false;
  const RECT& r = button_rects_[index];
  POINT p{x, y};
  return PtInRect(&r, p) != FALSE;
}

bool FloatingLyricWindow::HitTestPanel(int x, int y) const {
  if (!window_) return false;
  // **必须**先判 panel_expanded_：折叠态下窗口总高可能不足 kPanelHeight
  // （如单行 + 小字号约 48px），此时"底部 150px"会覆盖整个窗口，
  // 歌词区点击会被误判成面板点击 → 面板永远展不开。
  if (!panel_expanded_) return false;
  RECT client{};
  GetClientRect(window_, &client);
  POINT p{x, y};
  RECT panel{client.left, client.bottom - kPanelHeight, client.right,
             client.bottom};
  return PtInRect(&panel, p) != FALSE;
}

void FloatingLyricWindow::PaintButton(HDC dc, const RECT& rect,
                                      const std::wstring& label, bool active,
                                      bool hovered) {
  COLORREF fill = RGB(56, 59, 66);
  if (active) {
    fill = RGB(0, 122, 204);
  } else if (hovered) {
    fill = RGB(74, 78, 86);
  }
  HBRUSH brush = CreateSolidBrush(fill);
  FillRect(dc, &rect, brush);
  DeleteObject(brush);

  HPEN pen = CreatePen(PS_SOLID, 1, RGB(90, 94, 102));
  HGDIOBJ old_pen = SelectObject(dc, pen);
  HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom);
  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(pen);

  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(240, 240, 240));
  HFONT font = CreateFontW(-14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
                           L"Microsoft YaHei UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  RECT text_rect = rect;
  DrawTextW(dc, label.c_str(), -1, &text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS |
                DT_NOPREFIX);
  SelectObject(dc, old_font);
  DeleteObject(font);
}

void FloatingLyricWindow::PaintPanel(HDC dc, const RECT& rect) {
  RECT panel{rect.left, rect.bottom - kPanelHeight, rect.right, rect.bottom};

  // 面板底色比歌词区略亮，保证滑杆与文字在浅色壁纸上仍可读。
  // **不透明**是刻意的：面板要"贴"在屏幕上（用户正在操作它），
  // 若跟随歌词背板透明度，opacity=0 时整个面板会消失、无法点击。
  // 歌词区的背板才是那个可调透明度的部分。
  HBRUSH brush = CreateSolidBrush(RGB(32, 34, 40));
  FillRect(dc, &panel, brush);
  DeleteObject(brush);

  HPEN pen = CreatePen(PS_SOLID, 1, RGB(70, 73, 80));
  HGDIOBJ old_pen = SelectObject(dc, pen);
  MoveToEx(dc, panel.left, panel.top, nullptr);
  LineTo(dc, panel.right, panel.top);
  SelectObject(dc, old_pen);
  DeleteObject(pen);

  // 配色预设色块：用该预设真实的渐变起止色填充，与歌词区观感一致
  for (int i = 0; i < kPresetCount && i < button_count_; i++) {
    const RECT& r = button_rects_[i];
    const int steps = 16;
    const int seg = (r.right - r.left) / steps;
    for (int s = 0; s < steps; s++) {
      RECT seg_rect{r.left + s * seg, r.top + 2, r.left + (s + 1) * seg + 1,
                    r.bottom - 2};
      HBRUSH sb =
          CreateSolidBrush(LerpArgb(kPresets[i].start, kPresets[i].end,
                                    static_cast<double>(s) / steps));
      FillRect(dc, &seg_rect, sb);
      DeleteObject(sb);
    }
    const bool active =
        (color_mode_ == 0) && (gradient_start_ == kPresets[i].start) &&
        (gradient_end_ == kPresets[i].end);
    HPEN p = CreatePen(PS_SOLID, active ? 2 : 1,
                       active ? RGB(120, 190, 255) : RGB(90, 94, 102));
    HGDIOBJ op = SelectObject(dc, p);
    HGDIOBJ ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, r.left, r.top, r.right, r.bottom);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(p);
  }

  const bool hover_first =
      hover_button_ && button_count_ > kBtnFontMinus;

  if (button_count_ > kBtnFontMinus) {
    PaintButton(dc, button_rects_[kBtnFontMinus], L"A−", false, hover_first);
  }
  if (button_count_ > kBtnFontPlus) {
    PaintButton(dc, button_rects_[kBtnFontPlus], L"A+", false, hover_first);
  }

  // 字号数值：画在 A− 与 A+ 之间**独立预留**的矩形里（font_value_rect_）。
  // 早期实现把它塞进滑杆的绘制分支里，导致滑杆不渲染时字号也跟着不显示。
  {
    wchar_t font_label[32];
    _snwprintf_s(font_label, _TRUNCATE, L"%d", static_cast<int>(font_size_));
    HFONT font = CreateFontW(-14, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                             CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                             DEFAULT_PITCH, L"Microsoft YaHei UI");
    HGDIOBJ of = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(226, 226, 226));
    RECT value_rect = font_value_rect_;
    DrawTextW(dc, font_label, -1, &value_rect,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc, of);
    DeleteObject(font);
  }

  if (button_count_ > kBtnDoubleLine) {
    PaintButton(dc, button_rects_[kBtnDoubleLine],
                double_line_ ? L"双行" : L"单行", double_line_, false);
  }
  if (button_count_ > kBtnLock) {
    PaintButton(dc, button_rects_[kBtnLock], locked_ ? L"已锁定" : L"未锁定",
                locked_, false);
  }

  if (button_count_ > kBtnOpacity) {
    const RECT& r = button_rects_[kBtnOpacity];
    const int track_h = 6;
    const int track_y = r.top + (r.bottom - r.top - track_h) / 2;
    RECT track{r.left, track_y, r.right, track_y + track_h};
    HBRUSH tb = CreateSolidBrush(RGB(70, 73, 80));
    FillRect(dc, &track, tb);
    DeleteObject(tb);

    // 已选部分用当前配色的起始色（与 Android 进度条一致）
    const int filled =
        track.left +
        static_cast<int>((track.right - track.left) * opacity_ / 100);
    RECT filled_rect{track.left, track_y, filled, track_y + track_h};
    HBRUSH fb =
        CreateSolidBrush(RGB((gradient_start_ >> 16) & 0xff,
                             (gradient_start_ >> 8) & 0xff,
                             gradient_start_ & 0xff));
    FillRect(dc, &filled_rect, fb);
    DeleteObject(fb);

    const int knob = 14;
    const int knob_x =
        ClampInt(filled - knob / 2, track.left, track.right - knob);
    RECT knob_rect{knob_x, track_y - (knob - track_h) / 2, knob_x + knob,
                   track_y + track_h + (knob - track_h) / 2};
    HBRUSH kb = CreateSolidBrush(RGB(235, 235, 235));
    FillRect(dc, &knob_rect, kb);
    DeleteObject(kb);

    SetTextColor(dc, RGB(190, 190, 190));
    HFONT font = CreateFontW(-13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                             CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                             DEFAULT_PITCH, L"Microsoft YaHei UI");
    HGDIOBJ of = SelectObject(dc, font);
    RECT label{r.left, r.bottom + 2, r.right, r.bottom + 20};
    wchar_t text[64];
    _snwprintf_s(text, _TRUNCATE, L"不透明度  %d%%", opacity_);
    DrawTextW(dc, text, -1, &label,
              DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc, of);
    DeleteObject(font);
  }
}

bool FloatingLyricWindow::EnsureBitmap(int width, int height) {
  if (width <= 0 || height <= 0) return false;
  if (mem_dc_ != nullptr && pixels_ != nullptr && width == bitmap_w_ &&
      height == bitmap_h_) {
    return true;
  }
  ReleaseBitmap();

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  // 负高度 = 自上而下（DIB 的 top-down），省去一行行的 y 翻转
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;   // ARGB
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  mem_dc_ = CreateCompatibleDC(screen);
  if (screen != nullptr) ReleaseDC(nullptr, screen);
  if (mem_dc_ == nullptr) return false;

  mem_bmp_ = CreateDIBSection(mem_dc_, &info, DIB_RGB_COLORS, &bits, nullptr,
                              0);
  if (mem_bmp_ == nullptr || bits == nullptr) {
    ReleaseBitmap();
    return false;
  }
  mem_bmp_old_ = SelectObject(mem_dc_, mem_bmp_);
  pixels_ = static_cast<std::uint32_t*>(bits);
  bitmap_w_ = width;
  bitmap_h_ = height;
  return true;
}

void FloatingLyricWindow::ReleaseBitmap() {
  if (mem_dc_ != nullptr) {
    if (mem_bmp_old_ != nullptr) SelectObject(mem_dc_, mem_bmp_old_);
    if (mem_bmp_ != nullptr) DeleteObject(mem_bmp_);
    DeleteDC(mem_dc_);
  }
  mem_dc_ = nullptr;
  mem_bmp_ = nullptr;
  mem_bmp_old_ = nullptr;
  pixels_ = nullptr;
  bitmap_w_ = 0;
  bitmap_h_ = 0;
}

void FloatingLyricWindow::Paint() {
  PAINTSTRUCT paint{};
  // 分层窗口仍需 BeginPaint/EndPaint 配对以清掉 WM_PAINT 的更新区域，
  // 但拿到的 DC **不可用于绘制**（内容不可依赖），只用来取窗口尺寸。
  BeginPaint(window_, &paint);
  RECT rect{};
  GetClientRect(window_, &rect);
  const int w = rect.right - rect.left;
  const int h = rect.bottom - rect.top;

  // 分层窗口必须走 UpdateLayeredWindow：WM_PAINT 拿到的 DC 内容不可依赖。
  if (!EnsureBitmap(w, h)) {
    EndPaint(window_, &paint);
    return;
  }
  // 每帧从标记色（alpha=0，全透明）开始 —— 绝不留上一帧的像素。
  // 那正是「文字重影 + 越拖越黑」的根源：普通窗口 + AlphaBlend 的写法
  // 每帧都在残留上再叠一层。
  ClearToMarker(pixels_, w, h);

  // 背板：直接写 ARGB，alpha = opacity%。
  // 0% → alpha 0（完全透出壁纸）；100% → alpha 255（纯黑）；中间线性。
  // 歌词文字始终 alpha=255（与 Android 的 bgAlpha 语义一致）。
  const int alpha_percent = ClampInt(opacity_, 0, 100);
  RECT lyric_area = rect;
  if (panel_expanded_) lyric_area.bottom = rect.bottom - kPanelHeight;
  if (alpha_percent > 0) {
    const std::uint32_t bg = (static_cast<std::uint32_t>(alpha_percent * 255 / 100) << 24);
    FillArgbRect(pixels_, w, h, lyric_area, bg);
  }

  HDC mem = mem_dc_;
  SetBkMode(mem, TRANSPARENT);

  // 与 Position() 用同一套字号换算，避免两处算出不同高度导致文字被裁。
  // 传给 GDI 的 CreateFontW / DrawGradientText 时取负值（字符高度语义）。
  const int font_px = ClampInt(
      static_cast<int>(font_size_ * display_scale_ + 0.5), 10, 160);
  const int font_height = -font_px;

  // 当前行：歌词优先，无歌词时退回歌名；超宽时按字换行而非裁切。
  const std::wstring& shown = lyric_.empty() ? title_ : lyric_;
  HFONT layout_font = CreateFontW(font_height, 0, 0, 0, FW_SEMIBOLD, FALSE,
                                  FALSE, FALSE, DEFAULT_CHARSET,
                                  OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                  ANTIALIASED_QUALITY, DEFAULT_PITCH,
                                  L"Microsoft YaHei UI");
  HGDIOBJ old_layout_font = SelectObject(mem, layout_font);
  TEXTMETRICW metrics{};
  GetTextMetricsW(mem, &metrics);
  const int line_height = metrics.tmHeight + metrics.tmExternalLeading;
  const int text_width = lyric_area.right - lyric_area.left - 40;
  std::wstring joined_words;
  for (const auto& word : words_) joined_words += word.text;
  const int current_lines = !words_.empty() && joined_words == shown
                                ? TimedTextLineCount(mem, words_, text_width)
                                : WrappedTextLineCount(mem, shown, text_width);
  const int next_lines = double_line_ && !next_.empty()
                             ? WrappedTextLineCount(mem, next_, text_width)
                             : (double_line_ ? 1 : 0);
  SelectObject(mem, old_layout_font);
  DeleteObject(layout_font);

  RECT current{lyric_area.left + 20, lyric_area.top + 12,
               lyric_area.right - 20,
               lyric_area.top + 12 + current_lines * line_height};
  const int position = position_ms_ +
                       (playing_ ? static_cast<int>(GetTickCount64() -
                                                    position_tick_)
                                 : 0);
  DrawTimedWords(mem, shown, words_, position, current, unplayed_color_,
                 gradient_start_, gradient_end_, font_height);

  // 下一行：使用真实换行，不再以省略号吞掉歌词尾部。
  if (double_line_ && !next_.empty()) {
    RECT next{lyric_area.left + 20, current.bottom + 8,
              lyric_area.right - 20,
              current.bottom + 8 + next_lines * line_height};
    DrawWrappedText(mem, next_, next, unplayed_color_, font_height);
  }

  if (panel_expanded_) PaintPanel(mem, rect);

  // GDI 是异步批处理的：不 Flush 就直接读 DIB 像素会拿到未落笔的内容，
  // 导致 PromoteDrawnPixels 判定错误（文字变透明或出现残影）。
  GdiFlush();

  // GDI 只写 RGB 不动 alpha：把「被画过」的像素 alpha 补成不透明，
  // 否则文字在分层窗口里会被判为全透明而看不见。
  PromoteDrawnPixels(pixels_, w, h);

  // 一次提交整帧。ULW_ALPHA 让 DIB 的 alpha 通道真正参与合成。
  //
  // **第一个参数 hdcDst 必须是屏幕 DC**：传窗口 DC（BeginPaint 拿到的那个）
  // 会让整帧不显示。UpdateLayeredWindow 只用 hdcDst 取 DC 特性
  //（调色板/显示模式），内容全部来自 hdcSrc。
  //
  // **ptDst 必须是窗口的屏幕坐标**（GetWindowRect），**绝不能**用
  // GetClientRect 的 rect —— 客户区坐标原点恒为 (0,0)，会让每一帧的
  // UpdateLayeredWindow 都把窗口强行搬回屏幕左上角。
  // 这正是「拖不动、被固定在左上角」的**直接元凶**：拖动时窗口会短暂移动，
  // 紧接着下一次 Paint（歌词每秒都在触发）又把它拽回 (0,0)。
  // 现场实测数据：MOVE step 1 时 rect=(40,30)（移动生效了），
  // step 2 起又变回 (0,0)。
  RECT window_rect{};
  GetWindowRect(window_, &window_rect);
  HDC screen = GetDC(nullptr);
  POINT dst{window_rect.left, window_rect.top};
  SIZE size{w, h};
  POINT src{0, 0};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window_, screen, &dst, &size, mem_dc_, &src, 0, &blend,
                      ULW_ALPHA);
  if (screen != nullptr) ReleaseDC(nullptr, screen);

  EndPaint(window_, &paint);
}

void FloatingLyricWindow::BeginDrag(HWND window) {
  if (locked_) return;
  POINT cursor{};
  GetCursorPos(&cursor);
  RECT window_rect{};
  GetWindowRect(window, &window_rect);
  drag_offset_.x = cursor.x - window_rect.left;
  drag_offset_.y = cursor.y - window_rect.top;
  drag_origin_x_ = window_rect.left;
  dragging_ = true;
  // 捕获鼠标直到左键抬起，避免指针移出窗口后收不到 WM_LBUTTONUP，
  // 导致拖动状态残留、下次移动又把歌词窗带走。
  SetCapture(window);
}

void FloatingLyricWindow::OnPanelClick(int x, int y) {
  // 配色预设 0..3
  for (int i = 0; i < kPresetCount; i++) {
    if (!HitTestButton(x, y, i)) continue;
    gradient_start_ = kPresets[i].start;
    gradient_end_ = kPresets[i].end;
    // 与 Dart 侧 kPresetUnplayedColor 约定一致：预设的未唱色恒为白
    unplayed_color_ = 0xFFFFFFFF;
    color_mode_ = 0;
    Emit("preset", i);
    Invalidate();
    return;
  }
  // 字号 −
  if (HitTestButton(x, y, kBtnFontMinus)) {
    const int current = static_cast<int>(font_size_);
    const int next_font = ClampInt(((current + 9) / 10 - 1) * 10, 10, 100);
    if (next_font != static_cast<int>(font_size_)) {
      font_size_ = next_font;
      Emit("fontSize", next_font);
      Position(window_);
      Invalidate();
    }
    return;
  }
  // 字号 +
  if (HitTestButton(x, y, kBtnFontPlus)) {
    const int current = static_cast<int>(font_size_);
    const int next_font = ClampInt((current / 10 + 1) * 10, 10, 100);
    if (next_font != static_cast<int>(font_size_)) {
      font_size_ = next_font;
      Emit("fontSize", next_font);
      Position(window_);
      Invalidate();
    }
    return;
  }
  // 单双行切换
  if (HitTestButton(x, y, kBtnDoubleLine)) {
    double_line_ = !double_line_;
    Emit("doubleLine", double_line_ ? 1 : 0);
    Position(window_);
    Invalidate();
    return;
  }
  // 锁定
  if (HitTestButton(x, y, kBtnLock)) {
    locked_ = !locked_;
    Emit("locked", locked_ ? 1 : 0);
    ApplyInteractionStyle();
    Invalidate();
    return;
  }
}

void FloatingLyricWindow::OnPanelDrag(int x, int y, bool pressed) {
  if (button_count_ <= kBtnOpacity) return;
  if (!pressed) {
    dragging_opacity_ = -1;
    return;
  }
  const RECT& r = button_rects_[kBtnOpacity];
  if (x <= r.left || x >= r.right) return;
  const int value = ClampInt((x - r.left) * 100 / (r.right - r.left), 0, 100);
  if (value != opacity_) {
    opacity_ = value;
    dragging_opacity_ = value;
    Emit("opacity", value);
    Invalidate();
  }
}

namespace {
/// 悬浮窗位置持久化用的**生产**注册表键。
/// 探针必须用 SetPositionKey() 换成自己的键，否则测试会把窗口位置
/// 写进用户的真实注册表（症状：每次开App 都吸到左上角 (0,0)）。
constexpr wchar_t kDefaultPositionKey[] = L"Software\\MD3Music\\FloatingLyric";

/// 取当前应使用的注册表键（未覆盖时回落到生产键）。
const wchar_t* ActivePositionKey(const wchar_t* overridden) {
  return (overridden != nullptr && overridden[0] != L'\0') ? overridden
                                                          : kDefaultPositionKey;
}
}  // namespace

/// 从注册表读取上次拖动后的窗口位置。
///
/// 找不到 / 值非法时返回 false，调用方回退到默认「底部居中」。
/// 读到后只校验是否仍与任一显示器相交，允许自由跨屏摆放；若上次所在
/// 显示器已拔掉且位置完全不可见，则回退到默认底部居中。
bool FloatingLyricWindow::RestorePosition(int width, int height) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, ActivePositionKey(position_key_), 0,
                    KEY_QUERY_VALUE,
                    &key) != ERROR_SUCCESS ||
      key == nullptr) {
    return false;
  }
  auto read_value = [&](const wchar_t* name, LONG* out) {
    wchar_t buffer[32]{};
    DWORD type = 0;
    DWORD size = sizeof(buffer);
    if (RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(buffer), &size) !=
            ERROR_SUCCESS ||
        type != REG_SZ) {
      return false;
    }
    *out = wcstol(buffer, nullptr, 10);
    return true;
  };
  LONG x = 0;
  LONG y = 0;
  const bool ok = read_value(L"X", &x) && read_value(L"Y", &y);
  RegCloseKey(key);
  if (!ok) return false;

  // 允许窗口跨屏并部分移出工作区；只有完全不与任何显示器相交时，
  // 才视为失效位置，避免显示器配置变化后悬浮窗彻底不可找回。
  RECT saved_rect{static_cast<LONG>(x), static_cast<LONG>(y),
                  static_cast<LONG>(x + width),
                  static_cast<LONG>(y + height)};
  if (MonitorFromRect(&saved_rect, MONITOR_DEFAULTTONULL) == nullptr) {
    return false;
  }

  SetWindowPos(window_, HWND_TOPMOST, static_cast<int>(x), static_cast<int>(y),
               width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  return true;
}

void FloatingLyricWindow::PersistPosition() {
  RECT window_rect{};
  if (!window_ || !GetWindowRect(window_, &window_rect)) return;
  // RegSetValueExW(hKey, lpValueName, Reserved, dwType, lpData, cbData)：
  // 第二个参数就是值名（没有独立子键参数），第三个 Reserved 必须传 0。
  // 需要写子键时先用 RegCreateKeyExW 建好，hKey 传新建的句柄。
  HKEY key = nullptr;
  DWORD disposition = 0;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, ActivePositionKey(position_key_), 0,
                      nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                      &disposition) != ERROR_SUCCESS ||
      key == nullptr) {
    return;
  }
  auto write_value = [&](const wchar_t* name, LONG value) {
    wchar_t buffer[32];
    _snwprintf_s(buffer, _TRUNCATE, L"%ld", value);
    RegSetValueExW(key, name, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(buffer),
                   static_cast<DWORD>((wcslen(buffer) + 1) * sizeof(wchar_t)));
  };
  write_value(L"X", window_rect.left);
  write_value(L"Y", window_rect.top);
  RegCloseKey(key);
}

LRESULT CALLBACK FloatingLyricWindow::WndProc(HWND window, UINT message,
                                                WPARAM wparam,
                                                LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<FloatingLyricWindow*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_PAINT && self) {
    self->Paint();
    return 0;
  }
  if (message == WM_TIMER && self) {
    if (self->playing_ && !self->words_.empty()) self->Invalidate();
    return 0;
  }
  if (!self) return DefWindowProcW(window, message, wparam, lparam);

  // 不再按 locked_ 拦截鼠标消息：locked 只锁位置（BeginDrag 里判断），
  // 不锁交互，否则解锁按钮永远点不到（详见 ApplyInteractionStyle 的说明）。

  const int mouse_x = GET_X_LPARAM(lparam);
  const int mouse_y = GET_Y_LPARAM(lparam);

  switch (message) {
    case WM_LBUTTONDOWN: {
      // 只有点在**具体控件**上才走面板逻辑；其余位置（歌词区、面板空白、
      // 背板任意处）一律允许拖动，否则"面板一展开就没法拖窗口了"。
      if (self->HitTestPanel(mouse_x, mouse_y)) {
        bool on_control = false;
        for (int i = 0; i < self->button_count_; i++) {
          if (self->HitTestButton(mouse_x, mouse_y, i)) {
            on_control = true;
            break;
          }
        }
        if (on_control) {
          self->OnPanelClick(mouse_x, mouse_y);
          self->OnPanelDrag(mouse_x, mouse_y, true);
          return 0;
        }
      }
      // 记录按下点用于区分「点击展开」与「拖动窗口」
      self->pressed_button_ = -2;
      self->press_point_.x = mouse_x;
      self->press_point_.y = mouse_y;
      self->BeginDrag(window);
      return 0;
    }
    case WM_LBUTTONDBLCLK: {
      // **锁定态的逃生出口**：锁定会阻止拖动，若没有这条路径用户就
      // 永远拖不动了（要先展开面板才能解锁，但用户未必意识到这一点）。
      // 锁定时双击歌词区直接解锁，并回传 Dart 落盘。
      if (self->locked_ && !self->HitTestPanel(mouse_x, mouse_y)) {
        self->locked_ = false;
        self->Emit("locked", 0);
        self->Invalidate();
        return 0;
      }
      break;
    }
    case WM_MOUSEMOVE: {
      if (self->dragging_) {
        // 只有"正拖在某个滑杆上"才交给面板，其余一律移动窗口——
        // 与 WM_LBUTTONDOWN 的 on_control 判定对称。
        bool on_slider = false;
        if (self->panel_expanded_ && self->button_count_ > kBtnOpacity) {
          on_slider = self->HitTestButton(mouse_x, mouse_y, kBtnOpacity);
        }
        if (on_slider) {
          self->OnPanelDrag(mouse_x, mouse_y, true);
          return 0;
        }
        if ((wparam & MK_LBUTTON) == 0) {
          // 防御系统在异常输入路径下漏发 WM_LBUTTONUP；不可继续跟随光标。
          self->dragging_ = false;
          self->pressed_button_ = -1;
          self->OnPanelDrag(mouse_x, mouse_y, false);
          self->PersistPosition();
          if (GetCapture() == window) ReleaseCapture();
          self->Invalidate();
          return 0;
        }
        POINT cursor{};
        GetCursorPos(&cursor);
        const int next_x = self->allow_horizontal_move_
                               ? cursor.x - self->drag_offset_.x
                               : self->drag_origin_x_;
        // 保持现有置顶层级，移动分层窗口时复用当前位图；松手后再重绘，
        // 避免每个鼠标采样点都排入一次额外 Paint。
        SetWindowPos(window, nullptr, next_x,
                     cursor.y - self->drag_offset_.y, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER);
        return 0;
      }
      // 悬停高亮
      {
        bool now_hover = false;
        for (int i = 0; i < self->button_count_; i++) {
          if (self->HitTestButton(mouse_x, mouse_y, i)) {
            now_hover = true;
            break;
          }
        }
        if (now_hover != self->hover_button_) {
          self->hover_button_ = now_hover;
          self->Invalidate();
        }
      }
      break;
    }
    case WM_LBUTTONUP: {
      if (self->dragging_) {
        // 位移超过阈值才算"拖动窗口"，否则算"点击"——
        // 这是 Windows 对 click 的惯常定义，也避免手抖导致点不动。
        const int dx = mouse_x - self->press_point_.x;
        const int dy = mouse_y - self->press_point_.y;
        const bool moved =
            (dx * dx + dy * dy) > kDragThreshold * kDragThreshold;
        const bool was_lyric_area = (self->pressed_button_ == -2) && !moved;
        self->diag_dragging_ = self->dragging_;
        self->diag_pressed_ = self->pressed_button_;
        self->diag_moved_ = moved;
        self->OnPanelDrag(mouse_x, mouse_y, false);
        self->dragging_ = false;
        self->pressed_button_ = -1;
        if (GetCapture() == window) ReleaseCapture();
        if (was_lyric_area) {
          // 点击（未产生位移）→ 展开/收起设置面板
          self->panel_expanded_ = !self->panel_expanded_;
          self->Position(window);
          self->Invalidate();
          return 0;
        }
        self->PersistPosition();
        self->Invalidate();
        return 0;
      }
      break;
    }
    case WM_CAPTURECHANGED:
      if (self->dragging_) {
        // 外部窗口抢走捕获时也结束拖动，并保存最后一个有效位置。
        self->dragging_ = false;
        self->pressed_button_ = -1;
        self->OnPanelDrag(mouse_x, mouse_y, false);
        self->PersistPosition();
        self->Invalidate();
      }
      break;
    case WM_CANCELMODE:
      if (self->dragging_) {
        self->dragging_ = false;
        self->pressed_button_ = -1;
        self->OnPanelDrag(mouse_x, mouse_y, false);
        self->PersistPosition();
        if (GetCapture() == window) ReleaseCapture();
        self->Invalidate();
        return 0;
      }
      break;
    case WM_MOUSELEAVE:
      if (self->hover_button_) {
        self->hover_button_ = false;
        self->Invalidate();
      }
      return 0;
    case WM_NCHITTEST:
      // 恒返回客户区命中，让 WM_LBUTTONDOWN 生效。
      // 曾按 locked 返回 HTTRANSPARENT，但那样锁定后连解锁按钮都点不到
      //（WS_EX_TRANSPARENT + HTTRANSPARENT 双穿透 = 死锁）。
      return HTCLIENT;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
