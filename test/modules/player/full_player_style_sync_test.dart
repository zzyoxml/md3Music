import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('播放页路由跟随已加载并即时更新的播放器样式', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'use_am_style_player': true});
    final theme = ThemeProvider();
    await theme.amStylePlayerReady;
    expect(theme.useAmStylePlayer, isTrue);

    late BuildContext context;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: theme,
        child: MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final route = fullPlayerRoute(context);
    final consumer = route.builder(context) as Consumer<ThemeProvider>;
    expect(consumer.builder(context, theme, null), isA<AmStyleFullPlayer>());

    await theme.setUseAmStylePlayer(false);
    expect(consumer.builder(context, theme, null), isA<FullPlayer>());

    await theme.setUseAmStylePlayer(true);
    expect(consumer.builder(context, theme, null), isA<AmStyleFullPlayer>());
  });
}
