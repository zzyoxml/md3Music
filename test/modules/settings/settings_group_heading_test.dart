import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/settings_group_heading.dart';

void main() {
  testWidgets('首个分组标题不显示分隔线，后续分组显示分隔线', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SettingsGroupHeading('界面与显示', first: true),
              SettingsGroupHeading('播放与音频'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('界面与显示'), findsOneWidget);
    expect(find.text('播放与音频'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    final first = tester.widget<SettingsGroupHeading>(
      find.widgetWithText(SettingsGroupHeading, '界面与显示'),
    );
    expect(first.first, isTrue);
  });

  testWidgets('分组标题使用主题强调色并支持无障碍标题语义', (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: SettingsGroupHeading('歌词推送')),
      ),
    );

    final heading = tester.widget<Text>(find.text('歌词推送'));
    expect(heading.style?.color, theme.colorScheme.primary);
    expect(heading.style?.fontWeight, FontWeight.w600);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.text('歌词推送'),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .header,
      isTrue,
    );
  });
}
