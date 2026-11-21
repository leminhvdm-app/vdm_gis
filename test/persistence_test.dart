import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/models/forest_plot.dart';
import 'package:forest_gis/models/forest_poi.dart';

void main() {
  test('ForestPlot serialization and deserialization (toMap / fromMap)', () {
    final original = ForestPlot(
      id: 'plot-123',
      tieuKhu: 'TK 12',
      khoanh: 'Kh 3',
      lo: 'Lo 4',
      dienTich: 15.67,
      chuRung: 'BQL Rừng',
      trangThaiRung: 'Rừng tự nhiên',
      loaiCay: 'Sao đen',
      namTrong: 2018,
      truLuong: 120.5,
      boundary: [
        const LatLng(13.1, 106.2),
        const LatLng(13.2, 106.2),
        const LatLng(13.2, 106.3),
        const LatLng(13.1, 106.2),
      ],
      color: Colors.amber,
      note: 'Ghi chú test',
      attributes: {'custom_attr': 'gia_tri'},
      groupName: 'Nhom_KML_Test',
    );

    final map = original.toMap();
    final restored = ForestPlot.fromMap(map);

    expect(restored.id, original.id);
    expect(restored.tieuKhu, original.tieuKhu);
    expect(restored.dienTich, original.dienTich);
    expect(restored.boundary.length, original.boundary.length);
    expect(restored.boundary.first.latitude, original.boundary.first.latitude);
    expect(restored.groupName, original.groupName);
    expect(restored.attributes['custom_attr'], 'gia_tri');
  });

  test('ForestPoi serialization and deserialization (toMap / fromMap)', () {
    final original = ForestPoi(
      id: 'poi-456',
      title: 'Mốc giới số 1',
      description: 'Mốc cắm ranh',
      position: const LatLng(13.1848, 106.1625),
      timestamp: DateTime(2026, 11, 21, 10, 30),
      type: PoiType.boundaryMark,
      groupName: 'Nhom_GPKG_Test',
    );

    final map = original.toMap();
    final restored = ForestPoi.fromMap(map);

    expect(restored.id, original.id);
    expect(restored.title, original.title);
    expect(restored.position.latitude, original.position.latitude);
    expect(restored.type, PoiType.boundaryMark);
    expect(restored.groupName, original.groupName);
  });
}
