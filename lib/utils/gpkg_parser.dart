import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';
import 'gis_calculator.dart';
import 'vn2000_converter.dart';

class GpkgParseResult {
  final List<ForestPlot> plots;
  final List<ForestPoi> pois;
  final String info;

  GpkgParseResult({required this.plots, required this.pois, this.info = ''});
}

class GpkgParser {
  /// Mở và phân tích file GeoPackage (.gpkg)
  static Future<GpkgParseResult> parseFile(File file, {String? defaultGroupName}) async {
    final List<ForestPlot> plots = [];
    final List<ForestPoi> pois = [];
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
        // Kiểm tra xem có bảng tiles raster không
        final tiles = await db.rawQuery(
          "SELECT table_name, data_type, identifier, min_x, min_y, max_x, max_y, srs_id FROM gpkg_contents WHERE data_type = 'tiles'",
        );
        if (tiles.isNotEmpty) {
          for (var t in tiles) {
            final tableName = t['table_name'] as String;
            final identifier = t['identifier']?.toString() ?? tableName;
            double? minX = (t['min_x'] as num?)?.toDouble();
            double? minY = (t['min_y'] as num?)?.toDouble();
            double? maxX = (t['max_x'] as num?)?.toDouble();
            double? maxY = (t['max_y'] as num?)?.toDouble();
            int srsId = (t['srs_id'] as num?)?.toInt() ?? 4326;

            // Nếu gpkg_contents chưa có bounds, tìm trong gpkg_tile_matrix_set
            if (minX == null || minY == null || maxX == null || maxY == null) {
              try {
                final tms = await db.rawQuery(
                  "SELECT min_x, min_y, max_x, max_y, srs_id FROM gpkg_tile_matrix_set WHERE table_name = ?",
                  [tableName],
                );
                if (tms.isNotEmpty) {
                  minX = (tms.first['min_x'] as num?)?.toDouble();
                  minY = (tms.first['min_y'] as num?)?.toDouble();
                  maxX = (tms.first['max_x'] as num?)?.toDouble();
                  maxY = (tms.first['max_y'] as num?)?.toDouble();
                  srsId = (tms.first['srs_id'] as num?)?.toInt() ?? srsId;
                }
              } catch (_) {}
            }

            // Đếm số lượng ngói ảnh (tiles)
            int tileCount = 0;
            int minZoom = 0;
            int maxZoom = 0;
            try {
              final stats = await db.rawQuery(
                "SELECT count(*) as cnt, min(zoom_level) as zmin, max(zoom_level) as zmax FROM $tableName",
              );
              if (stats.isNotEmpty) {
                tileCount = (stats.first['cnt'] as num?)?.toInt() ?? 0;
                minZoom = (stats.first['zmin'] as num?)?.toInt() ?? 0;
                maxZoom = (stats.first['zmax'] as num?)?.toInt() ?? 0;
              }
            } catch (_) {}

            if (minX != null && minY != null && maxX != null && maxY != null) {
              // Chuyển đổi hệ tọa độ nếu cần
              LatLng pMin;
              LatLng pMax;

              if (srsId == 3857 || minX.abs() > 180 || minY.abs() > 90) {
                // Web Mercator hoặc phẳng sang WGS84
                pMin = _webMercatorToWgs84(minX, minY);
                pMax = _webMercatorToWgs84(maxX, maxY);
              } else {
                pMin = LatLng(minY, minX);
                pMax = LatLng(maxY, maxX);
              }

              // Đa giác ranh giới bao phủ của bản đồ Raster
              final boundary = [
                LatLng(pMin.latitude, pMin.longitude),
                LatLng(pMin.latitude, pMax.longitude),
                LatLng(pMax.latitude, pMax.longitude),
                LatLng(pMax.latitude, pMin.longitude),
              ];

              final areaHa = GisCalculator.calculateAreaInHectares(boundary);
              final centerLat = (pMin.latitude + pMax.latitude) / 2;
              final centerLng = (pMin.longitude + pMax.longitude) / 2;

              final rasterPlot = ForestPlot(
                id: 'GPKG_RASTER_${plotIndex++}',
                lo: identifier.isNotEmpty ? identifier : tableName,
                khoanh: 'Bản đồ Raster',
                tieuKhu: 'GPKG',
                chuRung: 'Bản đồ Raster GeoPackage',
                dienTich: areaHa,
                loaiCay: 'Ảnh bản đồ ($tileCount ô ngói)',
                namTrong: maxZoom,
                trangThaiRung: 'Bản đồ ảnh Raster ($tileCount ô ngói, Zoom $minZoom-$maxZoom)',
                boundary: boundary,
                color: const Color(0xFF00ACC1),
                groupName: group,
                attributes: {
                  'Định dạng': 'GeoPackage Raster Tiles (OGC)',
                  'Lớp bản đồ': tableName,
                  'Số lượng ô ngói': '$tileCount tiles',
                  'Mức Zoom': '$minZoom - $maxZoom',
                  'Hệ tọa độ': 'EPSG:$srsId',
                  'Diện tích bao phủ': '${areaHa.toStringAsFixed(1)} ha',
                  'Tọa độ tâm': '${centerLat.toStringAsFixed(6)}, ${centerLng.toStringAsFixed(6)}',
                },
              );
              plots.add(rasterPlot);

              pois.add(ForestPoi(
                id: 'POI_RASTER_${poiIndex++}',
                title: 'Bản đồ: $identifier',
                description: 'Tâm bản đồ ảnh Raster GPKG ($tileCount ô ngói, ${areaHa.toStringAsFixed(1)} ha)',
                position: LatLng(centerLat, centerLng),
                timestamp: DateTime.now(),
                type: PoiType.boundaryMark,
                groupName: group,
              ));
            }
          }

          if (plots.isNotEmpty) {
            return GpkgParseResult(
              plots: plots,
              pois: pois,
              info: 'Đã nạp ${plots.length} lớp bản đồ Raster từ GeoPackage ($group)',
            );
          }
        }
      }

      for (var content in contents) {
        final tableName = content['table_name'] as String;

        // Tìm cột hình học trong gpkg_geometry_columns
        String geomColumn = 'geom';
        try {
          final geomCols = await db.rawQuery(
            "SELECT column_name, geometry_type_name, srs_id FROM gpkg_geometry_columns WHERE table_name = ?",
            [tableName],
          );
          if (geomCols.isNotEmpty) {
            geomColumn = geomCols.first['column_name'] as String;
          } else {
            final cols = await db.rawQuery("PRAGMA table_info($tableName)");
            for (var c in cols) {
              final colName = c['name']?.toString().toLowerCase() ?? '';
              if (colName == 'geom' || colName == 'geometry' || colName == 'the_geom' || colName == 'shape') {
                geomColumn = c['name'] as String;
                break;
              }
            }
          }
        } catch (_) {}

        // Truy vấn dữ liệu thuộc tính và hình học
        final rows = await db.query(tableName, limit: 3000);

        for (var row in rows) {
          final geomData = row[geomColumn];
          if (geomData == null || geomData is! Uint8List) continue;

          final geometries = parseGpbGeometry(geomData);
          if (geometries.isEmpty) continue;

          // Trích xuất các thuộc tính
          final rowMap = Map<String, dynamic>.from(row);
          rowMap.remove(geomColumn);

          final lo = rowMap['lo']?.toString() ??
              rowMap['ten_lo']?.toString() ??
              rowMap['tenlo']?.toString() ??
              rowMap['name']?.toString() ??
              'Lô GPKG $plotIndex';

          final khoanh = rowMap['khoanh']?.toString() ??
              rowMap['ntruong']?.toString() ??
              rowMap['khoanh_so']?.toString() ??
              'K1';

          final tieuKhu = rowMap['tieu_khu']?.toString() ??
              rowMap['tieukhu']?.toString() ??
              rowMap['cty']?.toString() ??
              'GPKG';

          final chuRung = rowMap['chu_rung']?.toString() ??
              rowMap['cty']?.toString() ??
              'Nhập từ GeoPackage';

          final trangThai = rowMap['trang_thai']?.toString() ??
              rowMap['trangthai']?.toString() ??
              rowMap['hien_tr']?.toString() ??
              'Rừng quy hoạch GPKG';

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
    } catch (e) {
      debugPrint('Lỗi đọc GeoPackage: $e');
    } finally {
      await db?.close();
    }

    return GpkgParseResult(plots: plots, pois: pois);
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
          // Cần nhảy qua độ dài của polygon con (ước lượng an toàn)
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
