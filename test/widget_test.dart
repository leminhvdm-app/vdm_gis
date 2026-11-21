import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/main.dart';

void main() {
  testWidgets('VDM GIS smoke test', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const VdmGisApp());
      expect(find.byType(VdmGisApp), findsOneWidget);
    });
  });
}
