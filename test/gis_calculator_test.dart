import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/utils/gis_calculator.dart';

void main() {
  group('GisCalculator Tests', () {
    test('isPointInPolygon - điểm nằm trong đa giác', () {
      final square = [
        const LatLng(10.0, 10.0),
        const LatLng(10.0, 20.0),
        const LatLng(20.0, 20.0),
        const LatLng(20.0, 10.0),
      ];

      final insidePoint = const LatLng(15.0, 15.0);
      final outsidePoint = const LatLng(25.0, 25.0);

      expect(GisCalculator.isPointInPolygon(insidePoint, square), isTrue);
      expect(GisCalculator.isPointInPolygon(outsidePoint, square), isFalse);
    });

    test('calculateAreaInHectares - tính diện tích lớn hơn 0', () {
      final square = [
        const LatLng(11.3400, 107.0300),
        const LatLng(11.3440, 107.0320),
        const LatLng(11.3450, 107.0380),
        const LatLng(11.3410, 107.0370),
      ];

      final area = GisCalculator.calculateAreaInHectares(square);
      expect(area, greaterThan(0));
    });
  });
}
