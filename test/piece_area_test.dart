import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/gis_calculator.dart';
import 'package:forest_gis/utils/kml_parser.dart';

void main() {
  test('Verify individual piece area for Lô 2 and Lô 99', () async {
    final file = File(r'C:\Users\Vo Duc Minh\.gemini\antigravity\brain\7bb7b0ee-0275-4751-b9d2-e1cc7381b8ac\.user_uploaded\media_1795309314867_197f0fc0.kmz');
    final result = await KmlParser.parseFile(file);

    // Kiểm tra Lô 2
    final plots2 = result.plots.where((p) => p.lo == '2').toList();
    expect(plots2.isNotEmpty, isTrue);

    print('Lô 2 has ${plots2.length} pieces:');
    final pieceAreas = <double>[];
    for (int i = 0; i < plots2.length; i++) {
      final p = plots2[i];
      final area = GisCalculator.calculateAreaInHectares(p.boundary);
      pieceAreas.add(area);
      print('  Piece $i: area = ${area.toStringAsFixed(2)} ha (p.dienTich = ${p.dienTich})');
    }

    // Các mảnh lớn của Lô 2 phải có diện tích khác nhau chứ không phải tất cả đều bằng nhau (22.45 ha)
    final distinctAreas = pieceAreas.map((a) => a.toStringAsFixed(1)).toSet();
    expect(distinctAreas.length, greaterThan(1), reason: 'Mỗi mảnh phải có diện tích riêng biệt!');

    final totalLotArea = GisCalculator.calculateTotalLotArea(plots2);
    print('Total area of Lô 2: ${totalLotArea.toStringAsFixed(2)} ha');
    expect(totalLotArea, greaterThan(20.0));
  });
}
