import '../../services/kugou_api/kugou_models.dart';

typedef SceneAudioListLoader =
    Future<Map<String, dynamic>?> Function({
      required String sceneId,
      required String moduleId,
      required String tagId,
    });

/// Returns the list payload used by scene list endpoints.
///
/// `null` means that the response shape is unknown, while an empty list is a
/// confirmed empty result. Keeping those states separate lets callers fail
/// open when a temporary/API-shape error occurs.
List<dynamic>? extractSceneList(Map<String, dynamic>? response) {
  if (response == null) return null;

  final data = response['data'];
  if (data is List) return data;
  if (data is Map<String, dynamic>) {
    final list = _firstList(data, const [
      'list',
      'info',
      'items',
      'song_list',
      'audio_list',
    ]);
    if (list != null) return list;
  }

  return _firstList(response, const [
    'list',
    'info',
    'items',
    'song_list',
    'audio_list',
  ]);
}

List<dynamic>? _firstList(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is List) return value;
  }
  return null;
}

/// Removes scene music tags confirmed to have no playable audio.
///
/// A failed/unknown availability check keeps the tag visible so transient
/// network failures do not permanently hide valid content from the user.
Future<List<({String moduleId, KugouSceneTag tag})>> filterSceneTagsWithAudio({
  required String sceneId,
  required List<({String moduleId, KugouSceneTag tag})> tags,
  required SceneAudioListLoader loadAudioList,
}) async {
  final checked = await Future.wait(
    tags.map((item) async {
      try {
        final response = await loadAudioList(
          sceneId: sceneId,
          moduleId: item.moduleId,
          tagId: item.tag.tagId,
        );
        final list = extractSceneList(response);
        if (list == null) return item;

        final hasPlayableAudio = list.whereType<Map<String, dynamic>>().any(
          (json) => KugouSongDetail.fromJson(json).hash.isNotEmpty,
        );
        return hasPlayableAudio ? item : null;
      } catch (_) {
        return item;
      }
    }),
  );

  return checked.whereType<({String moduleId, KugouSceneTag tag})>().toList();
}
