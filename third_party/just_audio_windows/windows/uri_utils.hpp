#pragma once

#include <string>

// Encodes literal space characters in a URI string as "%20" so that
// Windows::Foundation::Uri accepts URIs that contain unencoded spaces
// (e.g. local file paths like "file:///C:/My Files/song.mp3").
//
// Already percent-encoded sequences such as "%20" or "%E2%80%99" are never
// modified, because they contain no literal space character.
inline std::string EncodeSpacesInUri(const std::string& uri) {
  std::string encoded;
  // Reserve worst-case capacity (every char is a space → 3 chars each).
  encoded.reserve(uri.length() * 3);
  for (char c : uri) {
    if (c == ' ') {
      encoded += "%20";
    } else {
      encoded += c;
    }
  }
  return encoded;
}

// Media Foundation 本地文件源会把百分号编码的非 ASCII 文件名当成字面路径，
// 导致中文歌曲一直停在 loading。仅还原合法 UTF-8 多字节序列；ASCII 转义
// （空格、#、?、%、+ 等）保持原样，避免改变文件名边界或发生二次解码。
inline std::string PrepareMediaSourceUri(const std::string& uri) {
  const auto encoded = EncodeSpacesInUri(uri);
  if (encoded.size() < 5 ||
      (encoded[0] != 'f' && encoded[0] != 'F') ||
      (encoded[1] != 'i' && encoded[1] != 'I') ||
      (encoded[2] != 'l' && encoded[2] != 'L') ||
      (encoded[3] != 'e' && encoded[3] != 'E') || encoded[4] != ':') {
    return encoded;
  }
  const auto hex = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
  };
  const auto byteAt = [&](size_t i) -> int {
    if (i + 2 >= encoded.size() || encoded[i] != '%') return -1;
    const int high = hex(encoded[i + 1]), low = hex(encoded[i + 2]);
    return high < 0 || low < 0 ? -1 : (high << 4) | low;
  };
  std::string result;
  result.reserve(encoded.size());
  for (size_t i = 0; i < encoded.size();) {
    const int first = byteAt(i);
    const int count = first >= 0xC2 && first <= 0xDF ? 2 :
        first >= 0xE0 && first <= 0xEF ? 3 :
        first >= 0xF0 && first <= 0xF4 ? 4 : 0;
    bool valid = count != 0;
    for (int j = 1; j < count && valid; ++j) {
      const int next = byteAt(i + 3 * j);
      valid = next >= 0x80 && next <= 0xBF;
      if (j == 1) {
        if (first == 0xE0 && next < 0xA0) valid = false;
        if (first == 0xED && next >= 0xA0) valid = false;
        if (first == 0xF0 && next < 0x90) valid = false;
        if (first == 0xF4 && next >= 0x90) valid = false;
      }
    }
    if (valid) {
      for (int j = 0; j < count; ++j) result += static_cast<char>(byteAt(i + 3 * j));
      i += 3 * count;
    } else {
      result += encoded[i++];
    }
  }
  return result;
}
