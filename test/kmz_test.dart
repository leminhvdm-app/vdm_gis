import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/kml_parser.dart';

void main() {
  test('Kiểm thử giải nén và phân tích file KMZ (Zip KML)', () {
    const sampleKml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Kratie Cao Su Lô 1</name>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>
              106.226,13.296,0
              106.230,13.296,0
              106.230,13.290,0
              106.226,13.290,0
              106.226,13.296,0
            </coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>''';

    // Tạo một file KMZ giả lập trong bộ nhớ
    final kmlBytes = utf8.encode(sampleKml);
    final archive = Archive();
    archive.addFile(ArchiveFile('doc.kml', kmlBytes.length, kmlBytes));
    final kmzBytes = ZipEncoder().encode(archive);

    expect(kmzBytes, isNotNull);

    // Giải mã KMZ
    final result = KmlParser.parseKmzBytes(kmzBytes);
    expect(result.plots.length, equals(1));
    expect(result.plots.first.lo, equals('Kratie Cao Su Lô 1'));
    expect(result.plots.first.boundary.length, equals(5));
  });
}
