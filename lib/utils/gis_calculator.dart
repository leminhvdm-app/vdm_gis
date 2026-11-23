import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../models/forest_plot.dart';

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

  /// Thuật toán gom cụm các đa giác rời rạc (Disjoint Polygon Clustering)
  /// Đếm chính xác số vùng đa giác địa lý thực tế người dùng nhìn thấy trên bản đồ.
  /// Các mảnh tiếp giáp (khoảng cách <= 10m) hoặc kề cận song song qua đường ranh (khoảng cách <= 18m, dải tiếp xúc >= 25m)
  /// sẽ được gộp thành 1 vùng liên tục.
  static int countDisjointRegions(List<ForestPlot> plotGroup) {
    if (plotGroup.isEmpty) return 0;
    if (plotGroup.length == 1) return 1;

    final n = plotGroup.length;
    final parent = List<int>.generate(n, (i) => i);

    int find(int i) {
      if (parent[i] == i) return i;
      parent[i] = find(parent[i]);
      return parent[i];
    }

    void union(int i, int j) {
      final rootI = find(i);
      final rootJ = find(j);
      if (rootI != rootJ) {
        parent[rootI] = rootJ;
      }
    }

    // Tính trước Bounding Box của từng đa giác để tối ưu hiệu năng
    final minLats = <double>[];
    final maxLats = <double>[];
    final minLngs = <double>[];
    final maxLngs = <double>[];

    for (final p in plotGroup) {
      double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
      for (final pt in p.boundary) {
        if (pt.latitude < minLat) minLat = pt.latitude;
        if (pt.latitude > maxLat) maxLat = pt.latitude;
        if (pt.longitude < minLng) minLng = pt.longitude;
        if (pt.longitude > maxLng) maxLng = pt.longitude;
      }
      minLats.add(minLat);
      maxLats.add(maxLat);
      minLngs.add(minLng);
      maxLngs.add(maxLng);
    }

    const double mPerDegLat = 111139.0;

    for (int i = 0; i < n; i++) {
      final b1 = plotGroup[i].boundary;
      if (b1.isEmpty) continue;
      final lat1 = minLats[i];
      final cosLat = math.cos(lat1 * math.pi / 180.0).abs();
      final mPerDegLng = mPerDegLat * cosLat;

      for (int j = i + 1; j < n; j++) {
        final b2 = plotGroup[j].boundary;
        if (b2.isEmpty) continue;

        // Sơ loại nhanh bằng Bounding Box mở rộng 25 mét
        final latBuf = 25.0 / mPerDegLat;
        final lngBuf = 25.0 / mPerDegLng;
        if (minLats[i] - latBuf > maxLats[j] ||
            maxLats[i] + latBuf < minLats[j] ||
            minLngs[i] - lngBuf > maxLngs[j] ||
            maxLngs[i] + lngBuf < minLngs[j]) {
          continue;
        }

        double minD = 1e9;
        double sharedFacingLength = 0.0;

        for (int k = 0; k < b1.length; k++) {
          final pt1 = b1[k];
          double dMinForPt1 = 1e9;

          for (final pt2 in b2) {
            final dLat = (pt1.latitude - pt2.latitude) * mPerDegLat;
            final dLng = (pt1.longitude - pt2.longitude) * mPerDegLng;
            final dist = math.sqrt(dLat * dLat + dLng * dLng);
            if (dist < minD) minD = dist;
            if (dist < dMinForPt1) dMinForPt1 = dist;
          }

          if (dMinForPt1 <= 18.0) {
            final nextPt = b1[(k + 1) % b1.length];
            final segLat = (pt1.latitude - nextPt.latitude) * mPerDegLat;
            final segLng = (pt1.longitude - nextPt.longitude) * mPerDegLng;
            sharedFacingLength += math.sqrt(segLat * segLat + segLng * segLng);
          }
        }

        // Điều kiện gộp:
        // 1. Khoảng cách trực tiếp <= 10.0m: các mảnh bị xẻ bởi đường ranh, mương nội bộ
        // 2. Hoặc khoảng cách <= 18.0m và có chiều dài kề cận song song >= 25.0m
        // (loại trừ các góc giao nhau ngã tư chỉ chạm 1 đoạn ngắn < 20m)
        if (minD <= 10.0 || (minD <= 18.0 && sharedFacingLength >= 25.0)) {
          union(i, j);
        }
      }
    }

    final uniqueRoots = <int>{};
    for (int i = 0; i < n; i++) {
      uniqueRoots.add(find(i));
    }
    return uniqueRoots.length;
  }

  /// Trích xuất diện tích theo hồ sơ gốc (nếu có) từ thuộc tính của Plot
  static double? getOfficialPlotArea(ForestPlot plot) {
    for (final key in [
      'dien_tich_ho_so',
      'dien_tich1',
      'dientich1',
      'dien_tich',
      'dientich',
      'dien_tic',
      'dien_tic_1',
      'dt',
      'area',
    ]) {
      final val = plot.attributes[key];
      if (val != null && val.trim().isNotEmpty) {
        final parsed = double.tryParse(val.trim());
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    if (plot.dienTich > 0) return plot.dienTich;
    return null;
  }

  /// Lấy diện tích hiển thị của một mảnh (polygon) theo đúng quy tắc:
  /// - Nếu Lô đơn (chỉ có 1 mảnh / 1 vùng): Lấy đúng theo diện tích trong hồ sơ gốc (nếu có).
  /// - Nếu Lô gồm nhiều mảnh:
  ///   + Nếu tất cả các mảnh bị gán lặp lại cùng một giá trị diện tích tổng cả Lô:
  ///     Từng mảnh sẽ hiển thị diện tích thực tế của mảnh đó (tính theo hình học GPS).
  ///   + Nếu các mảnh có diện tích hồ sơ riêng biệt: Lấy diện tích hồ sơ của mảnh đó.
  static double getPlotPieceArea(ForestPlot plot, {List<ForestPlot>? allPlotsInLot}) {
    final official = getOfficialPlotArea(plot);

    // Trường hợp Lô đơn (chỉ có 1 mảnh duy nhất)
    if (allPlotsInLot == null || allPlotsInLot.length <= 1) {
      if (official != null && official > 0) {
        return official;
      }
      return calculateAreaInHectares(plot.boundary);
    }

    // Trường hợp Lô có nhiều mảnh:
    if (official != null && official > 0) {
      final bool allSameOfficial = allPlotsInLot.every((p) {
        final o = getOfficialPlotArea(p);
        return o != null && (o - official).abs() < 0.01;
      });

      if (allSameOfficial) {
        // Thuộc tính hồ sơ bị gán trùng lặp cho mọi mảnh con -> hiển thị diện tích hình học từng mảnh
        final geom = calculateAreaInHectares(plot.boundary);
        return geom > 0 ? geom : official;
      }

      // Từng mảnh có số liệu hồ sơ riêng
      return official;
    }

    final geom = calculateAreaInHectares(plot.boundary);
    return geom > 0 ? geom : (plot.dienTich > 0 ? plot.dienTich : 0.0);
  }

  /// Tính diện tích chuẩn xác của toàn bộ Lô
  /// Tránh bị cộng dồn nhân gấp N lần khi tất cả các mảnh con mang cùng 1 thuộc tính diện tích của cả Lô
  static double calculateTotalLotArea(List<ForestPlot> plotGroup) {
    if (plotGroup.isEmpty) return 0.0;
    if (plotGroup.length == 1) {
      final p = plotGroup.first;
      final official = getOfficialPlotArea(p);
      if (official != null && official > 0) return official;
      return calculateAreaInHectares(p.boundary);
    }

    final rep = plotGroup.first;
    final officialRep = getOfficialPlotArea(rep);

    // 1. Kiểm tra thuộc tính diện tích tổng của cả Lô từ hồ sơ GIS (nếu có)
    final rawTotal = rep.attributes['dien_tich_tong_lo'] ??
        rep.attributes['dien_tich1'] ??
        rep.attributes['dientich1'] ??
        rep.attributes['dien_tich'] ??
        rep.attributes['dientich'] ??
        rep.attributes['dt'];
    double? officialLotArea;
    if (rawTotal != null) {
      officialLotArea = double.tryParse(rawTotal);
    }
    officialLotArea ??= officialRep;

    // 2. Tính tổng diện tích hình học thực tế từ toạ độ GPS của các mảnh con
    double geometricSum = 0.0;
    for (final p in plotGroup) {
      geometricSum += calculateAreaInHectares(p.boundary);
    }

    // Nếu có diện tích chính thức từ hồ sơ và chênh lệch không quá xa so với diện tích hình học (dưới 15% hoặc 1.5 ha)
    if (officialLotArea != null && officialLotArea > 0) {
      if ((officialLotArea - geometricSum).abs() < math.max(1.5, geometricSum * 0.15)) {
        return officialLotArea;
      }
    }

    final sumFold = plotGroup.fold<double>(0.0, (sum, p) => sum + p.dienTich);

    // Nếu tất cả các mảnh con mang cùng 1 thuộc tính diện tích (> 0)
    final repArea = rep.dienTich;
    final bool allSameAttr = repArea > 0 && plotGroup.every((p) => (p.dienTich - repArea).abs() < 0.01);
    if (allSameAttr) {
      return repArea;
    }

    // Nếu tổng cộng dồn gấp hơn 1.5 lần diện tích hình học, ưu tiên diện tích hình học
    if (geometricSum > 0 && sumFold > geometricSum * 1.5) {
      return geometricSum;
    }

    return sumFold > 0 ? sumFold : geometricSum;
  }
}
