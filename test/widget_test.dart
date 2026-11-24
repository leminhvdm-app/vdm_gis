import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/main.dart';

void main() {
  testWidgets('DNKC GIS smoke test', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const VdmGisApp());
      expect(find.byType(VdmGisApp), findsOneWidget);
    });
  });
}
