import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/scene/scene_content_filter.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  KugouSceneTag tag(String id) =>
      KugouSceneTag(tagId: id, name: id, contentType: 6);

  test('removes a music tag whose audio list is empty', () async {
    final result = await filterSceneTagsWithAudio(
      sceneId: 'scene',
      tags: [
        (moduleId: 'module', tag: tag('has-audio')),
        (moduleId: 'module', tag: tag('empty')),
      ],
      loadAudioList:
          ({required sceneId, required moduleId, required tagId}) async => {
            'data': {
              'list': tagId == 'empty'
                  ? <dynamic>[]
                  : <dynamic>[
                      {'hash': 'abc'},
                    ],
            },
          },
    );

    expect(result.map((e) => e.tag.tagId), ['has-audio']);
  });

  test('keeps a tag when availability cannot be checked', () async {
    final result = await filterSceneTagsWithAudio(
      sceneId: 'scene',
      tags: [(moduleId: 'module', tag: tag('unknown'))],
      loadAudioList:
          ({required sceneId, required moduleId, required tagId}) async => null,
    );

    expect(result.map((e) => e.tag.tagId), ['unknown']);
  });

  test('does not treat a non-audio payload as available music', () async {
    final result = await filterSceneTagsWithAudio(
      sceneId: 'scene',
      tags: [(moduleId: 'module', tag: tag('unplayable'))],
      loadAudioList:
          ({required sceneId, required moduleId, required tagId}) async => {
            'data': {
              'audio_list': [
                {'title': 'missing hash'},
              ],
            },
          },
    );

    expect(result, isEmpty);
  });
}
