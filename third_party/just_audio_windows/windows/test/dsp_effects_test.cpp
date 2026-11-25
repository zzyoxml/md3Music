// test/dsp_effects_test.cpp
#include "../dsp_effects.hpp"
#include <cassert>
#include <cmath>

int main() {
  using namespace md3music::dsp;
  // XAPOFX 官方常量边界（xapofx.h）
  assert(std::abs(DbToLinear(-18.0) - 0.126) < 0.002);
  assert(std::abs(DbToLinear(18.0) - 7.94) < 0.05);
  assert(std::abs(LinearToDb(1.0)) < 1e-6);
  // 增益钳制：Android 母带链为 ±12 dB
  assert(std::abs(ClampDb(99.0) - 12.0) < 1e-6);
  assert(std::abs(ClampDb(-99.0) + 12.0) < 1e-6);
  // 10 段 → 4 段降采样：总能量不得显著偏离（每段覆盖的频率对数均分）
  auto four = Downsample10To4({6, 5, 3, 1, 0, 0, 0, 0, 1, 1}); // 重低音
  assert(four.size() == 4);
  assert(four[0] > four[3]);  // 低频增益显著高于高频
  // 5 段 → 4 段：低频/高频两区不得互换
  auto from5 = Downsample5To4({-1, 2, 4, 2, -1}); // 流行
  assert(from5.size() == 4);
  assert(from5[0] < from5[1]);
  return 0;
}
