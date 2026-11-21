import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/utils/vn2000_converter.dart';

void main() {
  test('VN-2000 Chuyển đổi thuận và nghịch (Round-trip test)', () {
    const original = LatLng(11.3435, 107.0395);
    const centralMeridian = 107.0;

    // Chuyển thuận: WGS84 -> VN-2000
    final vn2000 = Vn2000Converter.toVN2000(original, centralMeridian: centralMeridian);
    expect(vn2000['x'], isNotNull);
    expect(vn2000['y'], isNotNull);

    // Chuyển nghịch: VN-2000 -> WGS84
    final restored = Vn2000Converter.toWGS84(
      northing: vn2000['x']!,
      easting: vn2000['y']!,
      centralMeridian: centralMeridian,
    );

    expect(restored.latitude, closeTo(original.latitude, 0.0001));
    expect(restored.longitude, closeTo(original.longitude, 0.0001));
  });

  test('Test tọa độ từ file PDF của người dùng (Đắk Nông)', () {
    // Tọa độ từ bảng trong ảnh PDF:
    // Điểm 1: X = 627761 (Easting), Y = 1477076 (Northing)
    final wgsPoint = Vn2000Converter.toWGS84(
      northing: 1477076.0,
      easting: 627761.0,
      centralMeridian: 108.5, // Đắk Nông / Đắk Lắk
    );

    // Tọa độ phải nằm ở khu vực Tây Nguyên (Vĩ độ ~13.3°, Kinh độ ~108.2°)
    expect(wgsPoint.latitude, inInclusiveRange(12.0, 15.0));
    expect(wgsPoint.longitude, inInclusiveRange(107.0, 110.0));
  });
}
