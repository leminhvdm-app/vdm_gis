import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

class GisCalculator {
  static const double earthRadius = 6378137.0; // WGS-84 equatorial radius in meters

  /// Thuật toán Ray-Casting: Kiểm tra xem 1 tọa độ GPS có nằm trong Lô rừng hay không
  static bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;

    int intersectCount = 0;
    for (int i = 0; i < polygon.length; i++) {
      int next = (i + 1) % polygon.length;
      final p1 = polygon[i];
      final p2 = polygon[next];

      if ((p1.longitude > point.longitude) != (p2.longitude > point.longitude)) {
        double intersectLat = (p2.latitude - p1.latitude) *
                (point.longitude - p1.longitude) /
                (p2.longitude - p1.longitude) +
            p1.latitude;
        if (point.latitude < intersectLat) {
          intersectCount++;
        }
      }
    }
    return (intersectCount % 2) == 1;
  }

  /// Tính diện tích đa giác mặt cầu (WGS-84) trả về Hecta (ha)
  static double calculateAreaInHectares(List<LatLng> points) {
    if (points.length < 3) return 0.0;

    double total = 0.0;
    for (int i = 0; i < points.length; i++) {
      int next = (i + 1) % points.length;
      final p1 = points[i];
      final p2 = points[next];

      double radLat1 = p1.latitude * math.pi / 180.0;
      double radLat2 = p2.latitude * math.pi / 180.0;
      double deltaLng = (p2.longitude - p1.longitude) * math.pi / 180.0;

      total += deltaLng * (2.0 + math.sin(radLat1) + math.sin(radLat2));
    }

    double areaM2 = (total * earthRadius * earthRadius / 2.0).abs();
    // 1 hecta = 10,000 m2
    return areaM2 / 10000.0;
  }

  /// Tính khoảng cách giữa 2 điểm (mét)
  static double calculateDistanceInMeters(LatLng p1, LatLng p2) {
    return const Distance().as(LengthUnit.Meter, p1, p2);
  }

  /// Tính tổng chiều dài đường đi / ranh giới (mét)
  static double calculateTotalDistanceInMeters(List<LatLng> points, {bool isClosed = false}) {
    if (points.length < 2) return 0.0;

    final distance = const Distance();
    double total = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      total += distance.as(LengthUnit.Meter, points[i], points[i + 1]);
    }
    if (isClosed && points.length >= 3) {
      total += distance.as(LengthUnit.Meter, points.last, points.first);
    }
    return total;
  }
}
