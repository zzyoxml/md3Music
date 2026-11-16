#include "../uri_utils.hpp"

#include <gtest/gtest.h>

namespace just_audio_windows {
namespace test {

// ── EncodeSpacesInUri ────────────────────────────────────────────────────────

// A plain URL with no spaces should pass through unchanged.
TEST(EncodeSpacesInUri, NoSpaces_ReturnsUnchanged) {
  EXPECT_EQ(EncodeSpacesInUri("https://example.com/audio.mp3"),
            "https://example.com/audio.mp3");
}

// An empty string should stay empty.
TEST(EncodeSpacesInUri, EmptyString_ReturnsEmpty) {
  EXPECT_EQ(EncodeSpacesInUri(""), "");
}

// Literal spaces in a local file path must be encoded as %20.
// This is the core regression for https://github.com/bdlukaa/just_audio_windows/issues/26.
TEST(EncodeSpacesInUri, LiteralSpacesInFilePath_EncodedAsPercent20) {
  EXPECT_EQ(
      EncodeSpacesInUri("file:///C:/Users/My Files/song.mp3"),
      "file:///C:/Users/My%20Files/song.mp3");
}

// Multiple consecutive spaces must each be individually encoded.
TEST(EncodeSpacesInUri, MultipleSpaces_AllEncoded) {
  EXPECT_EQ(
      EncodeSpacesInUri(
          "C:/Users/HP/Downloads/Ve Kamleya Rocky Aur Rani.mp3"),
      "C:/Users/HP/Downloads/Ve%20Kamleya%20Rocky%20Aur%20Rani.mp3");
}

// Already percent-encoded spaces (%20) must NOT be double-encoded.
// This ensures a properly-encoded file:// URI like those produced by
// Dart's Uri.file() is left intact.
TEST(EncodeSpacesInUri, AlreadyEncodedSpaces_NotDoubleEncoded) {
  EXPECT_EQ(
      EncodeSpacesInUri("file:///C:/Users/My%20Files/song.mp3"),
      "file:///C:/Users/My%20Files/song.mp3");
}

// Percent-encoded multi-byte UTF-8 sequences (e.g. U+2019 RIGHT SINGLE
// QUOTATION MARK) must pass through unchanged so that Windows::Foundation::Uri
// can decode them natively.
// This is the core regression for the original apostrophe bug.
TEST(EncodeSpacesInUri, MultiBytePercentEncoded_Unchanged) {
  EXPECT_EQ(
      EncodeSpacesInUri(
          "https://example.com/speech?text=I%E2%80%99d%20like%20a%20coffee"),
      "https://example.com/speech?text=I%E2%80%99d%20like%20a%20coffee");
}

// A URL with both unencoded spaces and percent-encoded multi-byte chars:
// spaces must be encoded while the percent-sequences stay intact.
TEST(EncodeSpacesInUri, MixedLiteralSpacesAndPercentEncoded) {
  EXPECT_EQ(
      EncodeSpacesInUri(
          "https://example.com/speech?text=I%E2%80%99d like a coffee"),
      "https://example.com/speech?text=I%E2%80%99d%20like%20a%20coffee");
}

// A URL with only query-string spaces should have them encoded.
TEST(EncodeSpacesInUri, SpaceInQueryString) {
  EXPECT_EQ(
      EncodeSpacesInUri("https://example.com/tts?text=hello world"),
      "https://example.com/tts?text=hello%20world");
}

TEST(PrepareMediaSourceUri, LocalChinesePathUsesUnicode) {
  EXPECT_EQ(PrepareMediaSourceUri("file:///C:/Music/%E8%91%A1%E8%90%84.flac"),
            u8"file:///C:/Music/葡萄.flac");
}

TEST(PrepareMediaSourceUri, PreservesAsciiEscapesAndLiteralPlus) {
  EXPECT_EQ(PrepareMediaSourceUri("file:///C:/%E9%9F%B3%20%23%3F%25%2B%5B%5D+.flac"),
            u8"file:///C:/音%20%23%3F%25%2B%5B%5D+.flac");
}

TEST(PrepareMediaSourceUri, NetworkUtf8EncodingIsUnchanged) {
  EXPECT_EQ(PrepareMediaSourceUri("https://example.com/%E8%91%A1.flac?q=a b"),
            "https://example.com/%E8%91%A1.flac?q=a%20b");
}

TEST(PrepareMediaSourceUri, ValidTwoAndFourByteSequences) {
  EXPECT_EQ(PrepareMediaSourceUri("FILE:///C:/%c3%a9%F0%9F%8E%B5.flac"),
            u8"FILE:///C:/é🎵.flac");
}

TEST(PrepareMediaSourceUri, NeverDoubleDecodes) {
  EXPECT_EQ(PrepareMediaSourceUri("file:///C:/%25E8%2591%25A1.flac"),
            "file:///C:/%25E8%2591%25A1.flac");
}

TEST(PrepareMediaSourceUri, InvalidUtf8IsUnchanged) {
  for (const auto* value : {"%E8%91", "%E8%ZZ%A1", "%C0%AF", "%ED%A0%80", "%F4%90%80%80"}) {
    const auto uri = std::string("file:///C:/") + value + ".flac";
    EXPECT_EQ(PrepareMediaSourceUri(uri), uri);
  }
}

}  // namespace test
}  // namespace just_audio_windows
