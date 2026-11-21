import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/kml_parser.dart';

void main() {
  test('Phân tích chuỗi HTML từ file Kratie của người dùng bằng KmlParser', () {
    const rawHtml = '''Unknown Area Type<BR><BR><B>ID_lo</B> = 5.08NK.N2.10.054<BR><B>cTy</B> = 08Đồng Nai Kratie<BR><B>ntruong</B> = NT2<BR><B>tenlo</B> = 313<BR><B>hDat</B> = TM-III<BR><B>PP_trồng</B> = TB2<BR><B>Khoảng_c</B> = 6x3<BR><B>giong</B> = PB 260<BR><B>Năm_cạo</B> = <BR><B>Chế_đ</B> = S/2D d4<BR><B>Ghi_chu</B> = <BR><B>namtrong</B> = 2010.0000<BR><B>Ct_TB</B> = 147.50000<BR><B>Mật_đ</B> = 555.00000<BR><B>Dien_tich_</B> = 0<BR><B>Hiện_tr</B> = CS.KD<BR><B>Phân_lo</B> = Q1<BR><B>Dien_tich1</B> = 12.090000''';

    final attrs = KmlParser.parseKmlDescriptionHtml(rawHtml);
    expect(attrs['ID_lo'], equals('5.08NK.N2.10.054'));
    expect(attrs['cTy'], equals('08Đồng Nai Kratie'));
    expect(attrs['ntruong'], equals('NT2'));
    expect(attrs['tenlo'], equals('313'));
    expect(attrs['giong'], equals('PB 260'));
    expect(attrs['namtrong'], equals('2010.0000'));
    expect(attrs['Mật_đ'], equals('555.00000'));
    expect(attrs['Hiện_tr'], equals('CS.KD'));
    expect(attrs['Dien_tich1'], equals('12.090000'));
  });

  test('Phân tích file KML chứa mô tả HTML Kratie tạo ra ForestPlot có cấu trúc đẹp', () {
    const kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>313</name>
      <description><![CDATA[Unknown Area Type<BR><BR><B>ID_lo</B> = 5.08NK.N2.10.054<BR><B>cTy</B> = 08Đồng Nai Kratie<BR><B>ntruong</B> = NT2<BR><B>tenlo</B> = 313<BR><B>giong</B> = PB 260<BR><B>namtrong</B> = 2010.0000<BR><B>Hiện_tr</B> = CS.KD<BR><B>Dien_tich1</B> = 12.090000]]></description>
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
    </Placemark>
  </Document>
</kml>''';

    final result = KmlParser.parse(kml);
    expect(result.plots.length, equals(1));
    final plot = result.plots.first;
    expect(plot.lo, equals('313'));
    expect(plot.khoanh, equals('NT2'));
    expect(plot.chuRung, equals('08Đồng Nai Kratie'));
    expect(plot.loaiCay, equals('Cao su giống PB 260'));
    expect(plot.namTrong, equals(2010));
    expect(plot.trangThaiRung, equals('Cao su kinh doanh (CS.KD)'));
    expect(plot.dienTich, equals(12.09));
    expect(plot.attributes['ID_lo'], equals('5.08NK.N2.10.054'));
    expect(plot.note.contains('<BR>'), isFalse);
    expect(plot.note.contains('<B>'), isFalse);
  });

  test('Phân tích file KML chứa bảng HTML table như file Mi_2026_All và CaoSu_GuiTD', () {
    const kml = '''<?xml version="1.0" encoding="utf-8"?>
<kml xmlns="http://earth.google.com/kml/2.1">
  <Folder>
    <Placemark>
      <name>61.M1</name>
      <description><![CDATA[<br><br><br>
        <table border="1" padding="0">
          <tr><td>fid</td><td>385</td></tr>
          <tr><td>TEN_LO</td><td>283.M3</td></tr>
          <tr><td>DIEN_TICH</td><td>1.27</td></tr>
        </table>
      ]]></description>
      <Polygon>
        <outerBoundaryIs>
          <LinearRing>
            <coordinates>
              106.280,13.261,0
              106.281,13.261,0
              106.281,13.260,0
              106.280,13.260,0
              106.280,13.261,0
            </coordinates>
          </LinearRing>
        </outerBoundaryIs>
      </Polygon>
    </Placemark>
  </Folder>
</kml>''';

    final result = KmlParser.parse(kml);
    expect(result.plots.length, equals(1));
    final plot = result.plots.first;
    expect(plot.lo, equals('283.M3'));
    expect(plot.dienTich, equals(1.27));
    expect(plot.attributes.length, equals(3));
    expect(plot.attributes['fid'], equals('385'));
    expect(plot.attributes['TEN_LO'], equals('283.M3'));
    expect(plot.attributes['DIEN_TICH'], equals('1.27'));
  });

  test('Phân tích trực tiếp file Mi_2026_All thực tế từ máy người dùng', () async {
    final file = File('C:/Users/Vo Duc Minh/Desktop/KML/Mi_2026_All_1_2026_11_21_10_28.KML');
    if (await file.exists()) {
      final res = await KmlParser.parseFile(file);
      expect(res.plots.isNotEmpty, isTrue);
      final p = res.plots.firstWhere((p) => p.lo == '283.M3', orElse: () => res.plots.first);
      expect(p.attributes.isNotEmpty, isTrue);
      expect(p.attributes.containsKey('TEN_LO'), isTrue);
      expect(p.lo, isNot('Lô KML 1'));
    }
  });
}
