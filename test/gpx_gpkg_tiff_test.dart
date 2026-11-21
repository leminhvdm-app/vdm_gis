import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/gpx_parser.dart';
import 'package:forest_gis/utils/gpkg_parser.dart';
import 'package:forest_gis/utils/tiff_parser.dart';

void main() {
  group('GpxParser Tests', () {
    test('Phân tích waypoint (<wpt>) và track (<trk>) chính xác', () {
      const gpxData = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Garmin GPSMap 66s">
  <wpt lat="11.3456" lon="107.0123">
    <name>Mốc ranh 01</name>
    <desc>Cột mốc bê tông ranh giới tiểu khu 142</desc>
  </wpt>
  <wpt lat="11.3460" lon="107.0130">
    <name>Mốc ranh 02</name>
    <desc>Cột mốc giáp ranh cao su</desc>
  </wpt>
  <trk>
    <name>Lô 3B Trắc địa GPX</name>
    <desc>Đo khép góc ranh rừng trồng</desc>
    <trkseg>
      <trkpt lat="11.3400" lon="107.0100"/>
      <trkpt lat="11.3450" lon="107.0100"/>
      <trkpt lat="11.3450" lon="107.0150"/>
      <trkpt lat="11.3400" lon="107.0150"/>
      <trkpt lat="11.3400" lon="107.0100"/>
    </trkseg>
  </trk>
</gpx>''';

      final result = GpxParser.parse(gpxData, defaultGroupName: 'TuanTra_2026.gpx');

      expect(result.pois.length, equals(2));
      expect(result.pois[0].title, equals('Mốc ranh 01'));
      expect(result.pois[0].groupName, equals('TuanTra_2026.gpx'));
      expect(result.pois[0].position.latitude, closeTo(11.3456, 0.0001));

      expect(result.plots.length, equals(1));
      expect(result.plots[0].lo, equals('Lô 3B Trắc địa GPX'));
      expect(result.plots[0].groupName, equals('TuanTra_2026.gpx'));
      expect(result.plots[0].dienTich, greaterThan(0.0));
    });
  });

  group('GpkgParser Tests', () {
    test('Xử lý an toàn khi byte dữ liệu rỗng hoặc sai GPB magic', () {
      final emptyGeom = GpkgParser.parseGpbGeometry(Uint8List(4));
      expect(emptyGeom, isEmpty);

      // Thử magic không phải 'GP'
      final badMagic = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
      final badResult = GpkgParser.parseGpbGeometry(badMagic);
      expect(badResult, isEmpty);
    });

    test('Phân tích WKB Point WGS84 chính xác', () {
      // Little endian byte order (1)
      // wkbPoint = 1 (uint32)
      // X = 107.0123 (Float64)
      // Y = 11.3456 (Float64)
      final bytes = Uint8List(21);
      final view = ByteData.sublistView(bytes);
      view.setUint8(0, 1); // little endian
      view.setUint32(1, 1, Endian.little); // wkbPoint
      view.setFloat64(5, 107.0123, Endian.little); // X (lon)
      view.setFloat64(13, 11.3456, Endian.little); // Y (lat)

      final res = GpkgParser.parseWkb(bytes, 0);
      expect(res.length, equals(1));
      expect(res[0].length, equals(1));
      expect(res[0][0].latitude, closeTo(11.3456, 0.0001));
      expect(res[0][0].longitude, closeTo(107.0123, 0.0001));
    });
  });

  group('TiffParser Tests', () {
    test('Phát hiện dữ liệu không phải TIFF an toàn', () {
      final invalidBytes = Uint8List.fromList([0x12, 0x34, 0x56, 0x78]);
      final result = TiffParser.parse(invalidBytes);
      expect(result.width, equals(0));
      expect(result.plot, isNull);
    });

    test('Xác định Header Little Endian (II) và Big Endian (MM)', () {
      // Header TIFF Little Endian 'II' + 42 (0x2A, 0x00)
      final tiffHeader = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]);
      final result = TiffParser.parse(tiffHeader, fileName: 'Kratie_Drone.tif');
      expect(result.width, greaterThan(0));
      expect(result.info, contains('Kratie_Drone.tif'));
    });
  });
}
