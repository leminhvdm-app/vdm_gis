import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/vn2000_table_parser.dart';

void main() {
  test('Vn2000TableParser phân tích chuỗi tọa độ thực tế', () {
    const raw = '''
BẢNG KÊ TỌA ĐỘ RANH GIỚI KHU ĐẤT
Đỉnh | X | Y
1    627761   1477076
2    630570   1477076
3    630570   1477434
4    630776   1477411
5    631581   1477305
6    631581   1475323
7    635581   1475323
8    635581   1471282
''';

    final points = Vn2000TableParser.parseCoordinatesFromText(raw, centralMeridian: 108.5);
    expect(points.length, equals(8));

    final plot = Vn2000TableParser.createPlotFromVn2000Points(
      name: 'Khu Đất Bản Đồ Tổng ĐNK',
      points: points,
    );
    expect(plot.dienTich, greaterThan(0));
    expect(plot.boundary.length, equals(8));
  });
}
