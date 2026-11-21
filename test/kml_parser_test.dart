import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/kml_parser.dart';

void main() {
  test('KmlParser parse Google Earth KML', () {
    const kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Lô 5a Rừng Đắc Nông</name>
      <description>Rừng trồng keo</description>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>
              108.5123,12.3456,0
              108.5234,12.3567,0
              108.5345,12.3412,0
              108.5123,12.3456,0
            </coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
    </Placemark>
    <Placemark>
      <name>Mốc ranh giới số 1</name>
      <Point>
        <coordinates>108.5123,12.3456,0</coordinates>
      </Point>
    </Placemark>
  </Document>
</kml>''';

    final result = KmlParser.parse(kml);
    expect(result.plots.length, equals(1));
    expect(result.plots.first.lo, equals('Lô 5a Rừng Đắc Nông'));
    expect(result.plots.first.boundary.length, equals(4));
    expect(result.pois.length, equals(1));
    expect(result.pois.first.title, equals('Mốc ranh giới số 1'));
  });
}
