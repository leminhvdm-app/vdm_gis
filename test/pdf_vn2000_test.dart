import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/utils/vn2000_converter.dart';

List<LatLng> parseVn2000TableText(String text, {double centralMeridian = 108.5}) {
  final List<LatLng> points = [];
  final lines = text.split(RegExp(r'[\r\n]+'));

  for (var line in lines) {
    final matches = RegExp(r'(\d{6}(?:\.\d+)?)\s+(\d{7}(?:\.\d+)?)').allMatches(line);
    for (var m in matches) {
      final easting = double.tryParse(m.group(1)!);
      final northing = double.tryParse(m.group(2)!);
      if (easting != null && northing != null) {
        points.add(Vn2000Converter.toWGS84(
          northing: northing,
          easting: easting,
          centralMeridian: centralMeridian,
        ));
      }
    }

    // Trường hợp ngược lại: 7 số trước 6 số sau
    final revMatches = RegExp(r'(\d{7}(?:\.\d+)?)\s+(\d{6}(?:\.\d+)?)').allMatches(line);
    for (var m in revMatches) {
      final northing = double.tryParse(m.group(1)!);
      final easting = double.tryParse(m.group(2)!);
      if (easting != null && northing != null) {
        points.add(Vn2000Converter.toWGS84(
          northing: northing,
          easting: easting,
          centralMeridian: centralMeridian,
        ));
      }
    }
  }

  return points;
}

void main() {
  test('Phân tích bảng tọa độ 34 điểm từ ảnh của người dùng', () {
    const rawTable = '''
1 627761 1477076
2 630570 1477076
3 630570 1477434
4 630776 1477411
5 631581 1477305
17 635855 1466872
34 627761 1474068
''';

    final points = parseVn2000TableText(rawTable, centralMeridian: 108.5);
    expect(points.length, equals(7));
    for (var p in points) {
      expect(p.latitude, inInclusiveRange(12.0, 14.0));
      expect(p.longitude, inInclusiveRange(107.0, 110.0));
    }
  });
}
