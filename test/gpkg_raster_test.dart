import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/utils/gpkg_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('Phân tích GeoPackage Raster Tiles All_DatDuKien.gpkg tạo ra RasterOverlay chuẩn và nắn khớp tọa độ', () async {
    final gpkgPath = r'C:\Users\Vo Duc Minh\.gemini\antigravity\brain\7bb7b0ee-0275-4751-b9d2-e1cc7381b8ac\.user_uploaded\media_1795306617242_30ed9185.gpkg';
    final file = File(gpkgPath);

    if (!file.existsSync()) {
      return;
    }

    final result = await GpkgParser.parseFile(file, defaultGroupName: 'All_DatDuKien');

    expect(result.overlays.isNotEmpty, true, reason: 'Phải trích xuất được RasterOverlay');
    final overlay = result.overlays.first;

    expect(overlay.name, 'All_DatDuKien');
    expect(overlay.groupName, 'All_DatDuKien');

    // Kiểm tra tọa độ nắn chuẩn xác (Khu vực Kratie)
    expect(overlay.west, closeTo(106.162, 0.01));
    expect(overlay.east, closeTo(106.298, 0.01));
    expect(overlay.south, closeTo(13.216, 0.01));
    expect(overlay.north, closeTo(13.403, 0.01));

    // Kiểm tra auto calibration offset (+0.004481 độ ~ 497m)
    expect(overlay.offsetLat, closeTo(0.004481, 0.0001));
    expect(overlay.bounds.north, closeTo(13.40267 + 0.004481, 0.001));

    // Kiểm tra file ảnh bản đồ ghép đã được tạo
    final imgFile = File(overlay.imagePath);
    expect(imgFile.existsSync(), true, reason: 'File ảnh ghép phải tồn tại trên đĩa');
    expect(imgFile.lengthSync() > 100000, true, reason: 'File ảnh phải có dung lượng lớn hơn 100KB');
  });
}
