import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';
import 'gis_calculator.dart';

class KmlParseResult {
  final List<ForestPlot> plots;
  final List<ForestPoi> pois;

  KmlParseResult({required this.plots, required this.pois});
}

class KmlParser {
  /// Đọc và phân tích file KML hoặc file nén KMZ trực tiếp từ đường dẫn file
  static Future<KmlParseResult> parseFile(File file, {String? defaultGroupName}) async {
    final bytes = await file.readAsBytes();
    final path = file.path.toLowerCase();
    final group = defaultGroupName ?? file.uri.pathSegments.last;

    if (path.endsWith('.kmz')) {
      return parseKmzBytes(bytes, defaultGroupName: group);
    } else {
      // Decode an toàn với allowMalformed để tránh FileSystemException UTF-8
      final content = utf8.decode(bytes, allowMalformed: true);
      return parse(content, defaultGroupName: group);
    }
  }

  /// Giải nén file KMZ (chuẩn Zip) và phân tích file .kml bên trong
  static KmlParseResult parseKmzBytes(List<int> bytes, {String defaultGroupName = 'Tập dữ liệu KMZ'}) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.name.toLowerCase().endsWith('.kml')) {
          final content = utf8.decode(file.content as List<int>, allowMalformed: true);
          return parse(content, defaultGroupName: defaultGroupName);
        }
      }
    } catch (e) {
      debugPrint('Lỗi giải nén file KMZ: $e');
    }
    return KmlParseResult(plots: [], pois: []);
  }

  /// Phân tích nội dung HTML hoặc chuỗi thuộc tính trong thẻ `<description>` của file KML/KMZ
  static Map<String, String> parseKmlDescriptionHtml(String html) {
    final Map<String, String> result = {};
    if (html.isEmpty) return result;

    // Chuẩn hóa <BR>, <br>, <br/> thành xuống dòng
    String text = html.replaceAll(RegExp(r'<[bB][rR]\s*/?>'), '\n');

    // Tìm các cặp <B>Tên_Trường</B> = Giá_Trị hoặc <B>Tên_Trường:</B> Giá_Trị
    final regex = RegExp(r'<[bB]>([^<]+)<\/[bB]>\s*[:=]\s*([^<\n\r]+)');
    for (var m in regex.allMatches(text)) {
      final key = m.group(1)!.trim();
      final val = m.group(2)!.trim();
      if (key.isNotEmpty && val.isNotEmpty) {
        result[key] = val;
      }
    }

    // Quét thêm dạng thông thường Tên_Trường = Giá_Trị hoặc Tên_Trường: Giá_Trị
    final lines = text.split(RegExp(r'[\r\n]+'));
    for (var line in lines) {
      final cleanLine = line.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (cleanLine.contains('=')) {
        final parts = cleanLine.split('=');
        if (parts.length >= 2) {
          final k = parts[0].trim();
          final v = parts.sublist(1).join('=').trim();
          if (k.isNotEmpty && v.isNotEmpty && !result.containsKey(k)) {
            result[k] = v;
          }
        }
      } else if (cleanLine.contains(':')) {
        final parts = cleanLine.split(':');
        if (parts.length >= 2) {
          final k = parts[0].trim();
          final v = parts.sublist(1).join(':').trim();
          if (k.isNotEmpty && v.isNotEmpty && !result.containsKey(k)) {
            result[k] = v;
          }
        }
      }
    }

    return result;
  }

  /// Phân tích cú pháp KML: Hỗ trợ Placemark, Polygon, MultiGeometry, Point, LineString
  static KmlParseResult parse(String kmlContent, {String defaultGroupName = 'Tập dữ liệu KML/KMZ'}) {
    final List<ForestPlot> plots = [];
    final List<ForestPoi> pois = [];

    try {
      final document = XmlDocument.parse(kmlContent);
      final placemarks = document.findAllElements('Placemark');

      int plotIndex = 1;
      int poiIndex = 1;

      for (var placemark in placemarks) {
        final nameEl = placemark.findElements('name').firstOrNull;
        final descEl = placemark.findElements('description').firstOrNull;
        final rawName = nameEl?.innerText.trim() ?? 'Lô KML $plotIndex';
        final rawDesc = descEl?.innerText.trim() ?? '';

        final Map<String, String> attrs = parseKmlDescriptionHtml(rawDesc);

        // Đọc ExtendedData nếu có (rất phổ biến trong file KMZ cao su / lâm nghiệp)
        final extendedData = placemark.findElements('ExtendedData').firstOrNull;
        if (extendedData != null) {
          for (var data in extendedData.findElements('Data')) {
            final attrName = data.getAttribute('name') ?? '';
            final val = data.findElements('value').firstOrNull?.innerText.trim() ?? '';
            if (attrName.isNotEmpty && val.isNotEmpty && !attrs.containsKey(attrName)) {
              attrs[attrName] = val;
            }
          }
        }

        // Tách các trường thông tin chuẩn từ thuộc tính (ví dụ file Kratie)
        final plotName = attrs['tenlo'] ?? (attrs['ID_lo'] ?? rawName);
        final khoanhName = attrs['ntruong'] ?? (attrs['khoanh'] ?? 'K1');
        final tieuKhuName = attrs['tieu_khu'] ?? (attrs['tieukhu'] ?? (attrs['cTy'] ?? 'KMZ'));
        final chuRungName = attrs['cTy'] ?? (attrs['chu_rung'] ?? 'Nhập từ KMZ/KML');

        String loaiCay = attrs['loai_cay'] ?? 'Theo hồ sơ KMZ';
        if (attrs.containsKey('giong')) {
          loaiCay = 'Cao su giống ${attrs['giong']}';
        }

        int? namTrong;
        if (attrs.containsKey('namtrong')) {
          namTrong = double.tryParse(attrs['namtrong']!)?.toInt();
        } else if (attrs.containsKey('nam_trong')) {
          namTrong = int.tryParse(attrs['nam_trong']!);
        }

        String trangThai = 'Rừng quy hoạch KMZ';
        if (attrs.containsKey('Hiện_tr')) {
          final ht = attrs['Hiện_tr']!;
          trangThai = (ht == 'CS.KD') ? 'Cao su kinh doanh (CS.KD)' : ht;
        } else if (attrs.containsKey('trang_thai')) {
          trangThai = attrs['trang_thai']!;
        }

        // Tạo ghi chú sạch (không chứa thẻ HTML rác)
        String cleanNote;
        if (attrs.isNotEmpty) {
          cleanNote = attrs.entries.map((e) => '${e.key}: ${e.value}').join(' | ');
        } else {
          cleanNote = rawDesc.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        }

        // 1. Quét toàn bộ Polygon (kể cả trong MultiGeometry)
        final polygons = placemark.findAllElements('Polygon');
        for (var polygon in polygons) {
          final coordsEl = polygon.findAllElements('coordinates').firstOrNull;
          if (coordsEl != null) {
            final rawCoords = coordsEl.innerText;
            final points = parseCoordinatesString(rawCoords);

            if (points.length >= 3) {
              final areaHa = GisCalculator.calculateAreaInHectares(points);
              double plotArea = double.parse(areaHa.toStringAsFixed(2));
              if (attrs.containsKey('Dien_tich1')) {
                final a = double.tryParse(attrs['Dien_tich1']!);
                if (a != null && a > 0) plotArea = double.parse(a.toStringAsFixed(2));
              }

              final colors = [
                const Color(0xFF2E7D32),
                const Color(0xFF43A047),
                const Color(0xFF66BB6A),
                const Color(0xFF00897B),
                const Color(0xFFFB8C00),
                const Color(0xFF5C6BC0),
                const Color(0xFF8E24AA),
              ];
              final color = colors[plotIndex % colors.length];

              plots.add(ForestPlot(
                id: 'KMZ_${DateTime.now().millisecondsSinceEpoch}_$plotIndex',
                tieuKhu: tieuKhuName,
                khoanh: khoanhName,
                lo: plotName,
                dienTich: plotArea,
                chuRung: chuRungName,
                trangThaiRung: trangThai,
                loaiCay: loaiCay,
                namTrong: namTrong,
                boundary: points,
                color: color,
                note: cleanNote,
                attributes: attrs,
                groupName: defaultGroupName,
              ));
              plotIndex++;
            }
          }
        }

        // 2. Quét LineString (nếu có ranh giới tuyến dạng LineString khép kín >= 3 điểm)
        if (polygons.isEmpty) {
          final lineStrings = placemark.findAllElements('LineString');
          for (var lineEl in lineStrings) {
            final coordsEl = lineEl.findAllElements('coordinates').firstOrNull;
            if (coordsEl != null) {
              final points = parseCoordinatesString(coordsEl.innerText);
              if (points.length >= 3) {
                final areaHa = GisCalculator.calculateAreaInHectares(points);
                plots.add(ForestPlot(
                  id: 'KMZ_LINE_${DateTime.now().millisecondsSinceEpoch}_$plotIndex',
                  tieuKhu: tieuKhuName,
                  khoanh: khoanhName,
                  lo: plotName,
                  dienTich: double.parse(areaHa.toStringAsFixed(2)),
                  chuRung: chuRungName,
                  trangThaiRung: 'Ranh giới từ LineString',
                  loaiCay: loaiCay,
                  boundary: points,
                  color: const Color(0xFF1E88E5),
                  note: cleanNote,
                  attributes: attrs,
                  groupName: defaultGroupName,
                ));
                plotIndex++;
              }
            }
          }
        }

        // 3. Quét Point (Chỉ tạo POI nếu Placemark là điểm độc lập, không chứa Polygon hoặc LineString để tránh bị hàng trăm cờ đè lên lô rừng)
        if (polygons.isEmpty) {
          final pointsList = placemark.findAllElements('Point');
          for (var pointEl in pointsList) {
            final coordsEl = pointEl.findAllElements('coordinates').firstOrNull;
            if (coordsEl != null) {
              final points = parseCoordinatesString(coordsEl.innerText);
              if (points.isNotEmpty) {
                pois.add(ForestPoi(
                  id: 'KMZ_POI_${DateTime.now().millisecondsSinceEpoch}_$poiIndex',
                  title: plotName,
                  description: cleanNote,
                  position: points.first,
                  type: PoiType.boundaryMark,
                  timestamp: DateTime.now(),
                  severity: 'Bình thường',
                  groupName: defaultGroupName,
                ));
                poiIndex++;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc KML: $e');
    }

    return KmlParseResult(plots: plots, pois: pois);
  }

  /// Trích xuất danh sách LatLng từ chuỗi coordinates bất kể định dạng xuống dòng, dấu phẩy, khoảng trắng
  static List<LatLng> parseCoordinatesString(String raw) {
    final List<LatLng> points = [];
    final cleaned = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (cleaned.isEmpty) return points;

    final tokens = cleaned.split(RegExp(r'\s+'));

    for (var token in tokens) {
      if (!token.contains(',')) continue;
      final parts = token.split(',');
      if (parts.length >= 2) {
        final lng = double.tryParse(parts[0].trim());
        final lat = double.tryParse(parts[1].trim());
        if (lat != null && lng != null) {
          if (lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
            points.add(LatLng(lat, lng));
          }
        }
      }
    }

    return points;
  }
}
