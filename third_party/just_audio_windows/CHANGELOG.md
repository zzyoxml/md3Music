## 0.2.3

* [fix]: Invalid access to media player ([#49](https://github.com/bdlukaa/just_audio_windows/pull/49))
* [fix]: Fix playback of local file paths containing spaces ([#55](https://github.com/bdlukaa/just_audio_windows/pull/55))
* [fix]: `seek(null)` no longer crashes on live streams ([#56](https://github.com/bdlukaa/just_audio_windows/pull/56))

## 0.2.2

* [fix]: Seeking in long tracks (above 36m) ([#36](https://github.com/bdlukaa/just_audio_windows/pull/36))

## 0.2.1

* [fix]: `currentIndex` is now always getting reported correctly in events ([#15](https://github.com/bdlukaa/just_audio_windows/issues/15), [#16](https://github.com/bdlukaa/just_audio_windows/issues/16))
* [fix]: Support multi-byte language paths ([#34](https://github.com/bdlukaa/just_audio_windows/pull/34))

## [0.2.0]

* [new]: Support playlists ([#8](https://github.com/bdlukaa/just_audio_windows/pull/8), [#9](https://github.com/bdlukaa/just_audio_windows/pull/9))
* [fix]: Fixed build in VS17.3 ([#10](https://github.com/bdlukaa/just_audio_windows/pull/10))

## 0.1.0

* [fix]: `seek` no longer throws error
* [new]: Added support for data event stream
* [new]: Support for looping over a single track

## 0.0.1

* Initial Base Implementation
  * `init`, `disposePlayer`, `disposeAllPlayers`
  * `load`, `play`, `pause`, `setVolume`, `setSpeed`, `setPitch`, `seek`
  * `dispose`
  * Error reporting