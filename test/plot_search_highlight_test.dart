import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/models/forest_plot.dart';

void main() {
  group('Kiểm thử Tìm kiếm Lô Lớp 1 & Đa Vùng (Multi-polygon Plot)', () {
    final plotL1_313_part1 = ForestPlot(
      id: 'p1_313_1',
      tieuKhu: 'TK 10',
      khoanh: 'Khoảnh 2',
      lo: '313',
      dienTich: 2.5,
      chuRung: 'Ban QLR',
      trangThaiRung: 'Rừng tự nhiên',
      loaiCay: 'Gỗ tạp',
      boundary: [
        const LatLng(11.340, 107.030),
        const LatLng(11.342, 107.030),
        const LatLng(11.342, 107.032),
      ],
      color: Colors.green,
      groupName: 'Lớp 1 - Quy hoạch Lâm nghiệp',
    );

    final plotL1_313_part2 = ForestPlot(
      id: 'p1_313_2',
      tieuKhu: 'TK 10',
      khoanh: 'Khoảnh 2',
      lo: '313',
      dienTich: 1.8,
      chuRung: 'Ban QLR',
      trangThaiRung: 'Rừng tự nhiên',
      loaiCay: 'Gỗ tạp',
      boundary: [
        const LatLng(11.345, 107.035),
        const LatLng(11.347, 107.035),
        const LatLng(11.347, 107.038),
      ],
      color: Colors.green,
      groupName: 'Lớp 1 - Quy hoạch Lâm nghiệp',
    );

    final plotL1_313_part3 = ForestPlot(
      id: 'p1_313_3',
      tieuKhu: 'TK 10',
      khoanh: 'Khoảnh 2',
      lo: '313',
      dienTich: 0.9,
      chuRung: 'Ban QLR',
      trangThaiRung: 'Rừng tự nhiên',
      loaiCay: 'Gỗ tạp',
      boundary: [
        const LatLng(11.348, 107.040),
        const LatLng(11.350, 107.040),
        const LatLng(11.350, 107.042),
      ],
      color: Colors.green,
      groupName: 'Lớp 1 - Quy hoạch Lâm nghiệp',
    );

    final plotL2_313 = ForestPlot(
      id: 'p2_313',
      tieuKhu: 'TK 10',
      khoanh: 'Khoảnh 2',
      lo: '313',
      dienTich: 10.0,
      chuRung: 'Công ty khác',
      trangThaiRung: 'Trồng cao su',
      loaiCay: 'Cao su',
      boundary: [
        const LatLng(11.360, 107.060),
        const LatLng(11.362, 107.060),
        const LatLng(11.362, 107.062),
      ],
      color: Colors.red,
      groupName: 'Lớp 2 - Bản đồ vệ tinh phụ',
    );

    test('Chỉ lọc lô thuộc Lớp 1, loại bỏ lớp thứ 2 trở đi để tránh nhiễu', () {
      final allPlots = [plotL1_313_part1, plotL1_313_part2, plotL1_313_part3, plotL2_313];
      const firstLayerName = 'Lớp 1 - Quy hoạch Lâm nghiệp';

      final firstLayerPlots = allPlots.where((p) => p.groupName == firstLayerName).toList();
      expect(firstLayerPlots.length, 3);
      expect(firstLayerPlots.any((p) => p.groupName == 'Lớp 2 - Bản đồ vệ tinh phụ'), isFalse);
    });

    test('Nhóm đúng 3 vùng thuộc Lô 313 và tính gộp diện tích & bounds', () {
      final firstLayerPlots = [plotL1_313_part1, plotL1_313_part2, plotL1_313_part3];
      final Map<String, List<ForestPlot>> groupedByPlot = {};
      for (final p in firstLayerPlots) {
        final loKey = p.lo.trim().isNotEmpty
            ? '${p.tieuKhu.trim().toLowerCase()}_${p.khoanh.trim().toLowerCase()}_${p.lo.trim().toLowerCase()}'
            : p.fullName.trim().toLowerCase();
        groupedByPlot.putIfAbsent(loKey, () => []).add(p);
      }

      expect(groupedByPlot.length, 1);
      final regions = groupedByPlot.values.first;
      expect(regions.length, 3);

      final totalArea = regions.fold<double>(0.0, (s, p) => s + p.dienTich);
      expect(totalArea, closeTo(5.2, 0.001));

      // Tính bounds gộp
      double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
      for (final p in regions) {
        for (final pt in p.boundary) {
          if (pt.latitude < minLat) minLat = pt.latitude;
          if (pt.latitude > maxLat) maxLat = pt.latitude;
          if (pt.longitude < minLng) minLng = pt.longitude;
          if (pt.longitude > maxLng) maxLng = pt.longitude;
        }
      }

      expect(minLat, 11.340);
      expect(maxLat, 11.350);
      expect(minLng, 107.030);
      expect(maxLng, 107.042);
    });
  });
}
