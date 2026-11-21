import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import '../models/forest_plot.dart';
import 'vn2000_converter.dart';

class TiffParseResult {
  final int width;
  final int height;
  final List<LatLng>? bounds;
  final ForestPlot? plot;
  final Uint8List? pngBytes;
  final String info;

  TiffParseResult({
    required this.width,
    required this.height,
    this.bounds,
    this.plot,
    this.pngBytes,
    required this.info,
  });
}

class TiffParser {
  /// Đọc và phân tích file ảnh TIFF / GeoTIFF
  static Future<TiffParseResult> parseFile(File file, {String? defaultGroupName}) async {
    final bytes = await file.readAsBytes();
    final fileName = defaultGroupName ?? file.uri.pathSegments.last;
    return parse(bytes, fileName: fileName, filePath: file.path);
  }

  /// Phân tích dữ liệu byte của TIFF
  static TiffParseResult parse(Uint8List bytes, {String fileName = 'anh_ve_tinh.tif', String? filePath}) {
    if (bytes.length < 8) {
      return TiffParseResult(
        width: 0,
        height: 0,
        info: 'File TIFF không hợp lệ hoặc kích thước quá nhỏ.',
      );
    }

    // 1. Kiểm tra byte order (II = Little Endian, MM = Big Endian)
    final isLittleEndian = bytes[0] == 0x49 && bytes[1] == 0x49;
    final isBigEndian = bytes[0] == 0x4D && bytes[1] == 0x4D;

    if (!isLittleEndian && !isBigEndian) {
      return TiffParseResult(
        width: 0,
        height: 0,
        info: 'Định dạng file không phải chuẩn TIFF.',
      );
    }

    int width = 0;
    int height = 0;

    try {
      final decoded = img.decodeTiff(bytes);
      if (decoded != null) {
        width = decoded.width;
        height = decoded.height;
      }
    } catch (_) {}

    // 2. Thử đọc file định vị toạ độ thế giới đi kèm (World file: .tfw hoặc .wld) nếu có
    if (filePath != null) {
      final tfwPath = filePath.replaceAll(RegExp(r'\.tiff?$', caseSensitive: false), '.tfw');
      final wldPath = filePath.replaceAll(RegExp(r'\.tiff?$', caseSensitive: false), '.wld');

      File worldFile = File(tfwPath);
      if (!worldFile.existsSync()) {
        worldFile = File(wldPath);
      }

      if (worldFile.existsSync()) {
        try {
          final lines = worldFile.readAsLinesSync().map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
          if (lines.length >= 6) {
            final xDim = double.parse(lines[0]); // Kích thước pixel trục X
            // lines[1], lines[2] là góc xoay
            final yDim = double.parse(lines[3]); // Kích thước pixel trục Y (thường là số âm)
            final xUpperLeft = double.parse(lines[4]);
            final yUpperLeft = double.parse(lines[5]);

            if (width > 0 && height > 0) {
              final xBottomRight = xUpperLeft + (xDim * width);
              final yBottomRight = yUpperLeft + (yDim * height);

              final corners = _createCornersFromBbox(
                xMin: xUpperLeft < xBottomRight ? xUpperLeft : xBottomRight,
                xMax: xUpperLeft > xBottomRight ? xUpperLeft : xBottomRight,
                yMin: yUpperLeft < yBottomRight ? yUpperLeft : yBottomRight,
                yMax: yUpperLeft > yBottomRight ? yUpperLeft : yBottomRight,
              );

              final plot = _createPlotFromCorners(corners, fileName, width, height);
              return TiffParseResult(
                width: width,
                height: height,
                bounds: corners,
                plot: plot,
                info: 'Đã nạp ảnh TIFF và tọa độ GeoTIFF (World file: .tfw) thành công: $width x $height px.',
              );
            }
          }
        } catch (e) {
          debugPrint('Lỗi đọc World file: $e');
        }
      }
    }

    // 3. Nếu không có World file, trả về thông tin ảnh độ phân giải cao
    return TiffParseResult(
      width: width > 0 ? width : 1024,
      height: height > 0 ? height : 1024,
      info: 'Ảnh TIFF viễn thám $fileName ($width x $height px). Chưa có tệp toạ độ trực giao (.tfw).',
    );
  }

  static List<LatLng> _createCornersFromBbox({
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
  }) {
    // Kiểm tra xem là tọa độ VN-2000 (mét, > 100000) hay WGS84 (độ kinh vĩ)
    if (xMin > 100000 || yMin > 100000) {
      // VN-2000: Y là Bắc (Northing ~ 1,000,000 - 2,500,000), X là Đông (Easting ~ 300,000 - 800,000)
      final nw = Vn2000Converter.toWGS84(northing: yMax, easting: xMin, centralMeridian: 107.75);
      final ne = Vn2000Converter.toWGS84(northing: yMax, easting: xMax, centralMeridian: 107.75);
      final se = Vn2000Converter.toWGS84(northing: yMin, easting: xMax, centralMeridian: 107.75);
      final sw = Vn2000Converter.toWGS84(northing: yMin, easting: xMin, centralMeridian: 107.75);
      return [nw, ne, se, sw];
    } else {
      // WGS84: Lon / Lat
      return [
        LatLng(yMax, xMin), // NW
        LatLng(yMax, xMax), // NE
        LatLng(yMin, xMax), // SE
        LatLng(yMin, xMin), // SW
      ];
    }
  }

  static ForestPlot _createPlotFromCorners(List<LatLng> corners, String fileName, int w, int h) {
    return ForestPlot(
      id: 'TIFF_${DateTime.now().millisecondsSinceEpoch}',
      tieuKhu: 'GeoTIFF',
      khoanh: 'Khung ảnh',
      lo: fileName,
      dienTich: 0.0,
      chuRung: 'Ảnh viễn thám / Drone',
      trangThaiRung: 'Ảnh trực giao TIFF ($w x $h px)',
      loaiCay: 'Bản đồ nền viễn thám',
      boundary: corners,
      color: const Color(0xFF009688),
      note: 'Khung ảnh viễn thám định vị không gian GeoTIFF ($w x $h px)',
      groupName: fileName,
    );
  }
}
