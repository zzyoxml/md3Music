import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/widgets/pinchable_grid_view.dart';

void main() {
  testWidgets('平板窄面板限制列数，恢复宽度后保留捏合偏好', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 853);
    addTearDown(tester.view.reset);
    final columns = GridColumnsProvider();
    final device = DeviceProvider();
    addTearDown(columns.dispose);
    addTearDown(device.dispose);
    Future<void> show(double width) => tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceProvider>.value(value: device),
          ChangeNotifierProvider<GridColumnsProvider>.value(value: columns),
        ],
        child: MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: PinchableGridView(
                itemCount: 12,
                itemBuilder: (_, i) => Text('封面$i'),
              ),
            ),
          ),
        ),
      ),
    );
    int actualColumns() =>
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    await show(1000);
    await tester.pumpAndSettle();
    columns.setColumns(6);
    await tester.pumpAndSettle();
    expect(actualColumns(), 5);
    await show(300);
    await tester.pumpAndSettle();
    expect(actualColumns(), 2);
    expect(columns.gridColumns, 6);
    await show(1200);
    await tester.pumpAndSettle();
    expect(actualColumns(), 6);
    expect(tester.takeException(), isNull);
  });
}
