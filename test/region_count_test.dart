import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/gis_calculator.dart';
import 'package:forest_gis/utils/kml_parser.dart';

void main() {
  test('Verify Region Count and Total Area for Plot 99 in KMZ via GisCalculator', () async {
    final file = File(r'C:\Users\Vo Duc Minh\.gemini\antigravity\brain\7bb7b0ee-0275-4751-b9d2-e1cc7381b8ac\.user_uploaded\media_1795309314867_197f0fc0.kmz');
    final result = await KmlParser.parseFile(file);
    final plots99 = result.plots.where((p) => p.lo == '99').toList();

    expect(plots99.isNotEmpty, isTrue);
    print('Raw plot elements for 99: ${plots99.length}');

    final regionCount = GisCalculator.countDisjointRegions(plots99);
    print('Calculated Region Count for Plot 99: $regionCount');
    expect(regionCount, equals(4), reason: 'Lô 99 phải có chính xác 4 vùng!');

    final totalArea = GisCalculator.calculateTotalLotArea(plots99);
    print('Calculated Total Area for Plot 99: ${totalArea.toStringAsFixed(2)} ha');
    expect(totalArea, closeTo(9.08, 0.01));
  });
}
