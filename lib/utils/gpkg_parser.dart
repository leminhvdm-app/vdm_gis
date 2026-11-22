import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';
import '../models/raster_overlay.dart';
import 'gis_calculator.dart';
import 'vn2000_converter.dart';

class GpkgParseResult {
  final List<ForestPlot> plots;
  final List<ForestPoi> pois;
  final List<RasterOverlay> overlays;
  final String info;

  GpkgParseResult({
    required this.plots,
    required this.pois,
    this.overlays = const [],
    this.info = '',
  });
}

class GpkgParser {
  /// Mở và phân tích file GeoPackage (.gpkg)
  static Future<GpkgParseResult> parseFile(
    File file, {
    String? defaultGroupName,
    Directory? customOutputDir,
  }) async {
    final List<ForestPlot> plots = [];
    final List<ForestPoi> pois = [];
    final List<RasterOverlay> overlays = [];
    final group = defaultGroupName ?? file.uri.pathSegments.last;

    Database? db;
    try {
      db = await openDatabase(file.path, readOnly: true);

      // 1. Kiểm tra bảng gpkg_contents để tìm các lớp vector (features)
      final contents = await db.rawQuery(
        "SELECT table_name, data_type, identifier FROM gpkg_contents WHERE data_type = 'features'",
      );

      int plotIndex = 1;
      int poiIndex = 1;

      if (contents.isEmpty) {
        // Kiểm tra xem có bảng tiles raster (bản đồ ảnh nắn tọa độ) không
        final tiles = await db.rawQuery(
          "SELECT table_name, data_type, identifier, min_x, min_y, max_x, max_y, srs_id FROM gpkg_contents WHERE data_type = 'tiles'",
        );
        if (tiles.isNotEmpty) {
          for (var t in tiles) {
            final tableName = t['table_name'] as String;
            final identifier = t['identifier']?.toString() ?? tableName;

            // Tiến hành ghép mảnh ảnh ngói (raster tiles) thành lớp phủ bản đồ hoàn chỉnh
            final rasterOverlay = await _stitchRasterTiles(
              db,
              tableName,
              identifier,
              group,
              customOutputDir: customOutputDir,
            );

            if (rasterOverlay != null) {
              overlays.add(rasterOverlay);

              // Thêm điểm mốc trung tâm để người dùng có thể bấm zoom tới bản đồ
              final center = rasterOverlay.center;
              pois.add(ForestPoi(
                id: 'POI_RASTER_${poiIndex++}',
                title: 'Bản đồ: ${rasterOverlay.name}',
                description: 'Tâm bản đồ ảnh sơ đồ nắn tọa độ (${rasterOverlay.name})',
                position: center,
                type: PoiType.boundaryMark,
                timestamp: DateTime.now(),
                severity: 'Bình thường',
                groupName: group,
              ));
            }
          }
        }
      } else {
        // 2. Phân tích các lớp vector features (Polygon / Point)
        for (var c in contents) {
          final tableName = c['table_name'] as String;

          final geomCols = await db.rawQuery(
            "SELECT column_name, geometry_type_name, srs_id FROM gpkg_geometry_columns WHERE table_name = ?",
            [tableName],
          );

          if (geomCols.isEmpty) continue;
          final geomColName = geomCols.first['column_name'] as String;

          final rows = await db.query(tableName);

          for (var row in rows) {
            final geomBytes = row[geomColName] as Uint8List?;
            if (geomBytes == null || geomBytes.isEmpty) continue;

            final geometries = parseGpbGeometry(geomBytes);
            if (geometries.isEmpty) continue;

            final rowMap = Map<String, dynamic>.from(row)..remove(geomColName);

            final lo = rowMap['lo']?.toString() ??
                rowMap['ten_lo']?.toString() ??
                rowMap['name']?.toString() ??
                rowMap['id']?.toString() ??
                'Lô $plotIndex';

            final khoanh = rowMap['khoanh']?.toString() ??
                rowMap['ten_khoanh']?.toString() ??
                rowMap['subdistrict']?.toString() ??
                '--';

            final tieuKhu = rowMap['tieu_khu']?.toString() ??
                rowMap['tk']?.toString() ??
                rowMap['district']?.toString() ??
                '--';

            final chuRung = rowMap['chu_rung']?.toString() ??
                rowMap['owner']?.toString() ??
                'Chưa xác định';

            final trangThai = rowMap['trang_thai']?.toString() ??
                rowMap['status']?.toString() ??
                'Rừng tự nhiên';

            final loaiCay = rowMap['loai_cay']?.toString() ??
                rowMap['giong']?.toString() ??
                'Theo hồ sơ GPKG';

            final dienTichRaw = rowMap['dien_tich'] ?? rowMap['area'] ?? rowMap['dien_tich1'];
            double? dienTich = dienTichRaw != null ? double.tryParse(dienTichRaw.toString()) : null;

            final note = rowMap.entries.map((e) => '${e.key}: ${e.value}').join(' | ');

            for (var geom in geometries) {
              if (geom.length >= 3) {
                // Polygon Lô
                final calcArea = GisCalculator.calculateAreaInHectares(geom);
                plots.add(ForestPlot(
                  id: 'GPKG_${DateTime.now().millisecondsSinceEpoch}_$plotIndex',
                  tieuKhu: tieuKhu,
                  khoanh: khoanh,
                  lo: lo,
                  dienTich: dienTich ?? double.parse(calcArea.toStringAsFixed(2)),
                  chuRung: chuRung,
                  trangThaiRung: trangThai,
                  loaiCay: loaiCay,
                  boundary: geom,
                  color: const Color(0xFF6A1B9A),
                  note: note,
                  groupName: group,
                  attributes: rowMap.map((k, v) => MapEntry(k, v?.toString() ?? '')),
                ));
                plotIndex++;
              } else if (geom.length == 1) {
                // Điểm POI
                pois.add(ForestPoi(
                  id: 'GPKG_POI_${DateTime.now().millisecondsSinceEpoch}_$poiIndex',
                  title: lo,
                  description: note,
                  position: geom.first,
                  type: PoiType.boundaryMark,
                  timestamp: DateTime.now(),
                  severity: 'Bình thường',
                  groupName: group,
                ));
                poiIndex++;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc GeoPackage: $e');
    } finally {
      await db?.close();
    }

    return GpkgParseResult(plots: plots, pois: pois, overlays: overlays);
  }

  /// Trích xuất và ghép các mảnh ngói (Raster Tiles) thành 1 tấm ảnh bản đồ nắn tọa độ duy nhất
  static Future<RasterOverlay?> _stitchRasterTiles(
    Database db,
    String tableName,
    String identifier,
    String groupName, {
    Directory? customOutputDir,
  }) async {
    try {
      // 1. Đọc thông số bounds của Tile Matrix Set
      final tmsRows = await db.rawQuery(
        "SELECT min_x, min_y, max_x, max_y, srs_id FROM gpkg_tile_matrix_set WHERE table_name = ?",
        [tableName],
      );
      if (tmsRows.isEmpty) return null;

      final tms = tmsRows.first;
      final double tmsMinX = (tms['min_x'] as num).toDouble();
      final double tmsMaxY = (tms['max_y'] as num).toDouble();
      final int srsId = (tms['srs_id'] as num?)?.toInt() ?? 4326;

      // 2. Tìm mức zoom có nhiều tile nhất
      final zoomStats = await db.rawQuery(
        "SELECT zoom_level, count(*) as cnt FROM $tableName GROUP BY zoom_level ORDER BY count(*) DESC, zoom_level DESC LIMIT 1",
      );
      if (zoomStats.isEmpty) return null;
      final int targetZoom = (zoomStats.first['zoom_level'] as num).toInt();

      // 3. Đọc kích thước ma trận của mức zoom này
      final tmRows = await db.rawQuery(
        "SELECT pixel_x_size, pixel_y_size, tile_width, tile_height FROM gpkg_tile_matrix WHERE table_name = ? AND zoom_level = ?",
        [tableName, targetZoom],
      );
      if (tmRows.isEmpty) return null;

      final tm = tmRows.first;
      final double pixelXSize = (tm['pixel_x_size'] as num).toDouble();
      final double pixelYSize = (tm['pixel_y_size'] as num).toDouble();
      final int tileW = (tm['tile_width'] as num).toInt();
      final int tileH = (tm['tile_height'] as num).toInt();

      final double tileWDeg = tileW * pixelXSize;
      final double tileHDeg = tileH * pixelYSize;

      // 4. Đọc toàn bộ các mảnh tile của zoom này
      final tileRows = await db.rawQuery(
        "SELECT tile_column, tile_row, tile_data FROM $tableName WHERE zoom_level = ?",
        [targetZoom],
      );
      if (tileRows.isEmpty) return null;

      int minCol = 999999999;
      int maxCol = -1;
      int minRow = 999999999;
      int maxRow = -1;

      for (var r in tileRows) {
        final col = (r['tile_column'] as num).toInt();
        final row = (r['tile_row'] as num).toInt();
        if (col < minCol) minCol = col;
        if (col > maxCol) maxCol = col;
        if (row < minRow) minRow = row;
        if (row > maxRow) maxRow = row;
      }

      final numCols = maxCol - minCol + 1;
      final numRows = maxRow - minRow + 1;
      if (numCols <= 0 || numRows <= 0) return null;

      // 5. Tính toán 4 góc tọa độ chuẩn OGC
      double rawWest = tmsMinX + minCol * tileWDeg;
      double rawEast = tmsMinX + (maxCol + 1) * tileWDeg;
      double rawNorth = tmsMaxY - minRow * tileHDeg;
      double rawSouth = tmsMaxY - (maxRow + 1) * tileHDeg;

      double west, east, north, south;
      if (srsId == 3857 || rawWest.abs() > 180 || rawSouth.abs() > 90) {
        final sw = _webMercatorToWgs84(rawWest, rawSouth);
        final ne = _webMercatorToWgs84(rawEast, rawNorth);
        west = sw.longitude;
        south = sw.latitude;
        east = ne.longitude;
        north = ne.latitude;
      } else {
        west = rawWest;
        east = rawEast;
        north = rawNorth;
        south = rawSouth;
      }

      // 6. Ghép toàn bộ các mảnh tile thành 1 ảnh Canvas duy nhất
      final fullImage = img.Image(width: numCols * tileW, height: numRows * tileH);
      img.fill(fullImage, color: img.ColorRgb8(255, 255, 255));

      for (var r in tileRows) {
        final col = (r['tile_column'] as num).toInt() - minCol;
        final row = (r['tile_row'] as num).toInt() - minRow;
        final data = r['tile_data'] as Uint8List?;
        if (data == null || data.isEmpty) continue;

        try {
          final tileImg = img.decodeImage(data);
          if (tileImg != null) {
            img.compositeImage(
              fullImage,
              tileImg,
              dstX: col * tileW,
              dstY: row * tileH,
            );
          }
        } catch (_) {}
      }

      // 7. Lưu file ảnh ghép ra bộ nhớ cục bộ
      Directory docsDir;
      try {
        docsDir = customOutputDir ?? await getApplicationDocumentsDirectory();
      } catch (_) {
        docsDir = Directory.systemTemp;
      }
      final outDir = Directory('${docsDir.path}/raster_overlays');
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final safeName = tableName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final outFilePath = '${outDir.path}/overlay_${DateTime.now().millisecondsSinceEpoch}_$safeName.jpg';
      final jpgBytes = img.encodeJpg(fullImage, quality: 85);
      await File(outFilePath).writeAsBytes(jpgBytes);

      return RasterOverlay(
        id: 'OVERLAY_${DateTime.now().millisecondsSinceEpoch}_$safeName',
        name: identifier.isNotEmpty ? identifier : tableName,
        imagePath: outFilePath,
        south: south,
        north: north,
        west: west,
        east: east,
        groupName: groupName,
        opacity: 0.88,
        isVisible: true,
      );
    } catch (e) {
      debugPrint('Lỗi ghép raster tiles GeoPackage: $e');
      return null;
    }
  }

  /// Phân tích dữ liệu GeoPackage Binary Header + WKB
  static List<List<LatLng>> parseGpbGeometry(Uint8List bytes) {
    final List<List<LatLng>> results = [];
    if (bytes.length < 8) return results;

    final view = ByteData.sublistView(bytes);

    // Kiểm tra magic 'GP' (0x47, 0x50)
    if (view.getUint8(0) != 0x47 || view.getUint8(1) != 0x50) {
      return results;
    }

    final flags = view.getUint8(3);
    final envelopeType = (flags >> 1) & 0x07;

    int headerOffset = 8;
    if (envelopeType == 1) {
      headerOffset += 32;
    } else if (envelopeType == 2 || envelopeType == 3) {
      headerOffset += 48;
    } else if (envelopeType == 4) {
      headerOffset += 64;
    }

    if (bytes.length <= headerOffset) return results;

    // Phân tích WKB bắt đầu từ headerOffset
    return parseWkb(bytes, headerOffset);
  }

  /// Phân tích WKB (Well-Known Binary) chuẩn OGC
  static List<List<LatLng>> parseWkb(Uint8List bytes, int offset) {
    final List<List<LatLng>> polygons = [];
    if (offset + 5 > bytes.length) return polygons;

    final view = ByteData.sublistView(bytes);
    final byteOrder = view.getUint8(offset) == 1 ? Endian.little : Endian.big;
    final wkbType = view.getUint32(offset + 1, byteOrder);

    int cur = offset + 5;

    // Loại 1: Point (wkbPoint)
    if (wkbType == 1 || wkbType == 1001) {
      if (cur + 16 <= bytes.length) {
        final x = view.getFloat64(cur, byteOrder);
        final y = view.getFloat64(cur + 8, byteOrder);
        polygons.add([_convertToLatLng(x, y)]);
      }
    }
    // Loại 3: Polygon (wkbPolygon)
    else if (wkbType == 3 || wkbType == 1003) {
      if (cur + 4 <= bytes.length) {
        final numRings = view.getUint32(cur, byteOrder);
        cur += 4;
        for (int r = 0; r < numRings; r++) {
          if (cur + 4 > bytes.length) break;
          final numPoints = view.getUint32(cur, byteOrder);
          cur += 4;

          final List<LatLng> ring = [];
          for (int p = 0; p < numPoints; p++) {
            if (cur + 16 > bytes.length) break;
            final x = view.getFloat64(cur, byteOrder);
            final y = view.getFloat64(cur + 8, byteOrder);
            cur += 16;
            ring.add(_convertToLatLng(x, y));
          }

          if (r == 0 && ring.length >= 3) {
            polygons.add(ring);
          }
        }
      }
    }
    // Loại 6: MultiPolygon (wkbMultiPolygon)
    else if (wkbType == 6 || wkbType == 1006) {
      if (cur + 4 <= bytes.length) {
        final numPoly = view.getUint32(cur, byteOrder);
        cur += 4;
        for (int i = 0; i < numPoly; i++) {
          final sub = parseWkb(bytes, cur);
          polygons.addAll(sub);
          if (sub.isNotEmpty) {
            cur += 9 + (sub.first.length * 16);
          }
        }
      }
    }

    return polygons;
  }

  /// Chuyển đổi tọa độ: Nếu là VN-2000 phẳng (x, y lớn > 10000) thì chuyển sang WGS84
  static LatLng _convertToLatLng(double x, double y) {
    if (x > 10000 && y > 10000) {
      // Tọa độ phẳng VN-2000 (X ~ 600,000; Y ~ 1,400,000)
      return Vn2000Converter.toWGS84(northing: y, easting: x, centralMeridian: 107.75);
    }
    // Tọa độ địa lý WGS-84 (x = Longitude, y = Latitude)
    return LatLng(y, x);
  }

  /// Chuyển đổi tọa độ EPSG:3857 (Web Mercator) sang WGS-84
  static LatLng _webMercatorToWgs84(double x, double y) {
    const rMajor = 6378137.0;
    final lon = (x / rMajor) * (180.0 / 3.141592653589793);
    final lat = (3.141592653589793 / 2.0 - 2.0 * math.atan(math.exp(-y / rMajor))) * (180.0 / 3.141592653589793);
    return LatLng(lat, lon);
  }
}
