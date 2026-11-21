import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/models/forest_plot.dart';
import 'package:forest_gis/models/forest_poi.dart';
import 'package:forest_gis/data/sample_forest_data.dart';
import 'package:forest_gis/utils/kml_parser.dart';
import 'package:forest_gis/utils/vn2000_table_parser.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('Kiểm thử Quản lý Nhóm Dữ Liệu & Bật/Tắt Tránh Nằm Chồng Lên Nhau', () {
    test('Dữ liệu mẫu ban đầu có groupName chuẩn xác', () {
      final plots = SampleForestData.getPlots();
      expect(plots.isNotEmpty, isTrue);
      for (var p in plots) {
        expect(p.groupName, equals('Dữ liệu mẫu ban đầu'));
      }
    });

    test('Bật / Tắt (Ẩn / Hiện) từng nhóm riêng biệt hoạt động chính xác', () {
      final plot1 = ForestPlot(
        id: '1',
        tieuKhu: 'TK 1',
        khoanh: 'K1',
        lo: 'Lô 1',
        dienTich: 10.0,
        chuRung: 'Đồng Nai',
        trangThaiRung: 'Cao su',
        loaiCay: 'Cao su',
        boundary: const [LatLng(11.3, 107.0), LatLng(11.4, 107.0), LatLng(11.4, 107.1)],
        color: Colors.green,
        groupName: '01.Kratie 2025.kmz',
      );

      final plot2 = ForestPlot(
        id: '2',
        tieuKhu: 'TK 2',
        khoanh: 'K2',
        lo: 'Lô 2',
        dienTich: 20.0,
        chuRung: 'Đắk Nông',
        trangThaiRung: 'Rừng phòng hộ',
        loaiCay: 'Keo',
        boundary: const [LatLng(12.3, 108.0), LatLng(12.4, 108.0), LatLng(12.4, 108.1)],
        color: Colors.purple,
        groupName: 'Ban Do Tong DNK.pdf',
      );

      final List<ForestPlot> allPlots = [plot1, plot2];
      final Set<String> hiddenGroups = {};

      List<ForestPlot> getVisiblePlots() =>
          allPlots.where((p) => !hiddenGroups.contains(p.groupName)).toList();

      // Ban đầu cả 2 nhóm đều hiển thị
      expect(getVisiblePlots().length, equals(2));

      // Ẩn nhóm '01.Kratie 2025.kmz' để không bị chồng lên nhóm PDF
      hiddenGroups.add('01.Kratie 2025.kmz');
      expect(getVisiblePlots().length, equals(1));
      expect(getVisiblePlots().first.groupName, equals('Ban Do Tong DNK.pdf'));

      // Hiện lại nhóm '01.Kratie 2025.kmz' và ẩn nhóm PDF
      hiddenGroups.remove('01.Kratie 2025.kmz');
      hiddenGroups.add('Ban Do Tong DNK.pdf');
      expect(getVisiblePlots().length, equals(1));
      expect(getVisiblePlots().first.groupName, equals('01.Kratie 2025.kmz'));

      // Hiện tất cả
      hiddenGroups.clear();
      expect(getVisiblePlots().length, equals(2));
    });

    test('Đổi màu hàng loạt cho toàn bộ nhóm dữ liệu', () {
      final plots = [
        ForestPlot(
          id: '1',
          tieuKhu: 'TK 1',
          khoanh: 'K1',
          lo: 'Lô 1',
          dienTich: 5.0,
          chuRung: 'Công ty A',
          trangThaiRung: 'Rừng trồng',
          loaiCay: 'Keo',
          boundary: const [LatLng(11.0, 107.0), LatLng(11.1, 107.0), LatLng(11.1, 107.1)],
          color: Colors.green,
          groupName: '01.Kratie 2025.kmz',
        ),
        ForestPlot(
          id: '2',
          tieuKhu: 'TK 1',
          khoanh: 'K1',
          lo: 'Lô 2',
          dienTich: 8.0,
          chuRung: 'Công ty A',
          trangThaiRung: 'Rừng trồng',
          loaiCay: 'Cao su',
          boundary: const [LatLng(11.2, 107.0), LatLng(11.3, 107.0), LatLng(11.3, 107.1)],
          color: Colors.yellow,
          groupName: '01.Kratie 2025.kmz',
        ),
        ForestPlot(
          id: '3',
          tieuKhu: 'TK 2',
          khoanh: 'K1',
          lo: 'Lô 3',
          dienTich: 12.0,
          chuRung: 'BQL',
          trangThaiRung: 'Tự nhiên',
          loaiCay: 'Gỗ quý',
          boundary: const [LatLng(12.0, 108.0), LatLng(12.1, 108.0), LatLng(12.1, 108.1)],
          color: Colors.blue,
          groupName: 'Ban Do Tong DNK.pdf',
        ),
      ];

      // Đổi màu nhóm '01.Kratie 2025.kmz' thành màu cam
      const newColor = Colors.orange;
      for (var p in plots) {
        if (p.groupName == '01.Kratie 2025.kmz') {
          p.color = newColor;
        }
      }

      expect(plots[0].color, equals(Colors.orange));
      expect(plots[1].color, equals(Colors.orange));
      // Nhóm khác giữ nguyên màu
      expect(plots[2].color, equals(Colors.blue));
    });

    test('KmlParser gán đúng groupName khi parse file', () {
      const kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Lô 99</name>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>
              106.0,13.0,0
              106.1,13.0,0
              106.1,13.1,0
              106.0,13.0,0
            </coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>''';

      final result = KmlParser.parse(kml, defaultGroupName: 'Kratie_Layer.kmz');
      expect(result.plots.length, equals(1));
      expect(result.plots.first.groupName, equals('Kratie_Layer.kmz'));
    });

    test('Vn2000TableParser gán đúng groupName khi tạo Lô từ PDF', () {
      final plot = Vn2000TableParser.createPlotFromVn2000Points(
        name: 'Khu A',
        points: const [LatLng(12.0, 107.0), LatLng(12.1, 107.0), LatLng(12.1, 107.1)],
        groupName: 'Ban Do Tong DNK.pdf',
      );
      expect(plot.groupName, equals('Ban Do Tong DNK.pdf'));
    });

    test('Khi ẩn nhóm, cả Lô rừng và Điểm mốc (POI) của nhóm đó đều được ẩn triệt để', () {
      final poi1 = ForestPoi(
        id: 'POI_KMZ_1',
        title: 'Mốc 1',
        description: 'Mốc Kratie',
        position: const LatLng(13.0, 106.0),
        type: PoiType.boundaryMark,
        timestamp: DateTime.now(),
        groupName: '01.Kratie 2025.kmz',
      );

      final poi2 = ForestPoi(
        id: 'POI_SAMPLE_1',
        title: 'Mốc 2',
        description: 'Mốc Lâm Đồng',
        position: const LatLng(11.0, 107.0),
        type: PoiType.boundaryMark,
        timestamp: DateTime.now(),
        groupName: 'Dữ liệu mẫu ban đầu',
      );

      final List<ForestPoi> allPois = [poi1, poi2];
      final Set<String> hiddenGroups = {};

      List<ForestPoi> getVisiblePois() =>
          allPois.where((p) => !hiddenGroups.contains(p.groupName)).toList();

      expect(getVisiblePois().length, equals(2));

      // Ẩn nhóm '01.Kratie 2025.kmz'
      hiddenGroups.add('01.Kratie 2025.kmz');
      final visible = getVisiblePois();
      expect(visible.length, equals(1));
      expect(visible.first.groupName, equals('Dữ liệu mẫu ban đầu'));
    });

    test('KmlParser không tạo trùng POI cờ cho Placemark đã có Polygon', () {
      const kmlWithBoth = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Lô 313</name>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>
              106.226,13.297,0
              106.230,13.297,0
              106.230,13.293,0
              106.226,13.293,0
              106.226,13.297,0
            </coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
      <Point>
        <coordinates>106.228,13.295,0</coordinates>
      </Point>
    </Placemark>
  </Document>
</kml>''';

      final res = KmlParser.parse(kmlWithBoth, defaultGroupName: '01.Kratie 2025.kmz');
      expect(res.plots.length, equals(1));
      // Không tạo POI cờ đè lên Lô đã có Polygon
      expect(res.pois.length, equals(0));
    });
  });
}
