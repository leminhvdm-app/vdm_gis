import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Bộ chuyển đổi tọa độ thực địa: WGS-84 sang VN-2000 & VN-2000 ngược về WGS-84
class Vn2000Converter {
  // Tham số Ellipsoid WGS-84 / VN-2000
  static const double a = 6378137.0; // Bán trục lớn (m)
  static const double f = 1.0 / 298.257223563; // Độ dẹt
  static const double b = a * (1.0 - f);
  static const double e2 = (a * a - b * b) / (a * a);
  static const double ePrime2 = (a * a - b * b) / (b * b);

  /// Chuyển đổi WGS84 sang tọa độ phẳng VN-2000 (X: Bắc/Northing, Y: Đông/Easting)
  static Map<String, double> toVN2000(LatLng point, {double centralMeridian = 107.0, bool is3DegreeZone = true}) {
    double latRad = point.latitude * math.pi / 180.0;
    double lngRad = point.longitude * math.pi / 180.0;
    double l0Rad = centralMeridian * math.pi / 180.0;

    double k0 = is3DegreeZone ? 0.9999 : 0.9996;
    double falseEasting = 500000.0;
    double falseNorthing = 0.0;

    double deltaL = lngRad - l0Rad;

    double sinLat = math.sin(latRad);
    double cosLat = math.cos(latRad);
    double tanLat = math.tan(latRad);

    double n = a / math.sqrt(1.0 - e2 * sinLat * sinLat);
    double t = tanLat * tanLat;
    double c = ePrime2 * cosLat * cosLat;

    // Chiều dài cung kinh tuyến M
    double m = a * ((1.0 - e2 / 4.0 - 3.0 * e2 * e2 / 64.0 - 5.0 * e2 * e2 * e2 / 256.0) * latRad -
        (3.0 * e2 / 8.0 + 3.0 * e2 * e2 / 32.0 + 45.0 * e2 * e2 * e2 / 1024.0) * math.sin(2.0 * latRad) +
        (15.0 * e2 * e2 / 256.0 + 45.0 * e2 * e2 * e2 / 1024.0) * math.sin(4.0 * latRad) -
        (35.0 * e2 * e2 * e2 / 3072.0) * math.sin(6.0 * latRad));

    // Tính tọa độ Y (Đông / Easting)
    double easting = k0 * n * (deltaL * cosLat +
        (1.0 - t + c) * math.pow(deltaL * cosLat, 3) / 6.0 +
        (5.0 - 18.0 * t + t * t + 72.0 * c - 58.0 * ePrime2) * math.pow(deltaL * cosLat, 5) / 120.0) + falseEasting;

    // Tính tọa độ X (Bắc / Northing)
    double northing = k0 * (m + n * tanLat * (math.pow(deltaL * cosLat, 2) / 2.0 +
        (5.0 - t + 9.0 * c + 4.0 * c * c) * math.pow(deltaL * cosLat, 4) / 24.0 +
        (61.0 - 58.0 * t + t * t + 600.0 * c - 330.0 * ePrime2) * math.pow(deltaL * cosLat, 6) / 720.0)) + falseNorthing;

    return {
      'x': northing, // Trục Bắc (Northing ~ 1,000,000 - 2,500,000)
      'y': easting,  // Trục Đông (Easting ~ 300,000 - 700,000)
    };
  }

  /// Chuyển đổi ngược: Từ tọa độ phẳng VN-2000 (Northing/Bắc, Easting/Đông) về WGS-84 (Lat, Lng)
  /// [northing]: Tọa độ trục Bắc (thường là số 7 chữ số: ví dụ 1477076 m)
  /// [easting]: Tọa độ trục Đông (thường là số 6 chữ số: ví dụ 627761 m)
  /// [centralMeridian]: Kinh tuyến trục của tỉnh (mặc định 108.5 cho Đắk Nông / Đắk Lắk, 107.0/107.75 cho Đồng Nai/Lâm Đồng)
  static LatLng toWGS84({
    required double northing,
    required double easting,
    double centralMeridian = 108.5,
    bool is3DegreeZone = true,
  }) {
    // Tự động hoán vị nếu người dùng nhập ngược (Easting vào northing hoặc ngược lại)
    double nVal = northing;
    double eVal = easting;
    if (nVal < 900000.0 && eVal > 900000.0) {
      double tmp = nVal;
      nVal = eVal;
      eVal = tmp;
    }

    double k0 = is3DegreeZone ? 0.9999 : 0.9996;
    double falseEasting = 500000.0;
    double falseNorthing = 0.0;

    double x = (nVal - falseNorthing) / k0;
    double y = (eVal - falseEasting) / k0;

    // Chiều dài cung kinh tuyến
    double e4 = e2 * e2;
    double e6 = e4 * e2;
    double e1 = (1.0 - math.sqrt(1.0 - e2)) / (1.0 + math.sqrt(1.0 - e2));

    double m = x;
    double mu = m / (a * (1.0 - e2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0));

    // Vĩ độ chuẩn phi1 (Footprint latitude)
    double phi1 = mu +
        (3.0 * e1 / 2.0 - 27.0 * math.pow(e1, 3) / 32.0) * math.sin(2.0 * mu) +
        (21.0 * e1 * e1 / 16.0 - 55.0 * math.pow(e1, 4) / 32.0) * math.sin(4.0 * mu) +
        (151.0 * math.pow(e1, 3) / 96.0) * math.sin(6.0 * mu) +
        (1097.0 * math.pow(e1, 4) / 512.0) * math.sin(8.0 * mu);

    double sinPhi1 = math.sin(phi1);
    double cosPhi1 = math.cos(phi1);
    double tanPhi1 = math.tan(phi1);

    double n1 = a / math.sqrt(1.0 - e2 * sinPhi1 * sinPhi1);
    double r1 = a * (1.0 - e2) / math.pow(1.0 - e2 * sinPhi1 * sinPhi1, 1.5);
    double d = y / n1;

    double t1 = tanPhi1 * tanPhi1;
    double c1 = ePrime2 * cosPhi1 * cosPhi1;

    // Vĩ độ Latitude (rad)
    double lat = phi1 - (n1 * tanPhi1 / r1) * (
        d * d / 2.0 -
        (5.0 + 3.0 * t1 + 10.0 * c1 - 4.0 * c1 * c1 - 9.0 * ePrime2) * math.pow(d, 4) / 24.0 +
        (61.0 + 90.0 * t1 + 298.0 * c1 + 45.0 * t1 * t1 - 252.0 * ePrime2 - 3.0 * c1 * c1) * math.pow(d, 6) / 720.0
    );

    // Kinh độ Longitude (rad)
    double lng = (centralMeridian * math.pi / 180.0) + (1.0 / cosPhi1) * (
        d -
        (1.0 + 2.0 * t1 + c1) * math.pow(d, 3) / 6.0 +
        (5.0 - 2.0 * c1 + 28.0 * t1 - 3.0 * c1 * c1 + 8.0 * ePrime2 + 24.0 * t1 * t1) * math.pow(d, 5) / 120.0
    );

    return LatLng(lat * 180.0 / math.pi, lng * 180.0 / math.pi);
  }

  /// Định dạng tọa độ dạng Độ - Phút - Giây (DMS)
  static String toDMS(double coordinate, bool isLatitude) {
    String direction = isLatitude ? (coordinate >= 0 ? 'N' : 'S') : (coordinate >= 0 ? 'E' : 'W');
    double absCoord = coordinate.abs();

    int degrees = absCoord.floor();
    double remainingMinutes = (absCoord - degrees) * 60.0;
    int minutes = remainingMinutes.floor();
    double seconds = (remainingMinutes - minutes) * 60.0;

    return '$degrees°${minutes.toString().padLeft(2, '0')}\'${seconds.toStringAsFixed(1).padLeft(4, '0')}"$direction';
  }
}
