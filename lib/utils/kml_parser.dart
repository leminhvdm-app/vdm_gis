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

    // 1. Quét cấu trúc bảng HTML: <table> <tr> <td>Tên trường</td> <td>Giá trị</td> </tr>
    // Rất phổ biến khi xuất từ QGIS, ArcGIS, MapInfo (như file Mi_2026_All, CaoSu_GuiTD...)
    final tableRowRegex = RegExp(
      r'<tr[^>]*>\s*<t[dh][^>]*>(.*?)<\/t[dh]>\s*<t[dh][^>]*>(.*?)<\/t[dh]>\s*<\/tr>',
      caseSensitive: false,
      dotAll: true,
    );
    for (var m in tableRowRegex.allMatches(html)) {
      final key = m.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      final val = m.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (key.isNotEmpty && val.isNotEmpty && !result.containsKey(key)) {
        result[key] = val;
      }
    }

    // Chuẩn hóa <BR>, <br>, <br/> thành xuống dòng
    String text = html.replaceAll(RegExp(r'<[bB][rR]\s*/?>'), '\n');

    // 2. Tìm các cặp <B>Tên_Trường</B> = Giá_Trị hoặc <B>Tên_Trường:</B> Giá_Trị (như file Kratie)
    final regex = RegExp(r'<[bB]>([^<]+)<\/[bB]>\s*[:=]\s*([^<\n\r]+)');
    for (var m in regex.allMatches(text)) {
      final key = m.group(1)!.trim();
      final val = m.group(2)!.trim();
      if (key.isNotEmpty && val.isNotEmpty && !result.containsKey(key)) {
        result[key] = val;
      }
    }

    // 3. Quét thêm dạng thông thường Tên_Trường = Giá_Trị hoặc Tên_Trường: Giá_Trị
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

  /// Trích xuất thuộc tính từ chuỗi ghi chú thô (dạng key: value | key: value hoặc chuỗi phẳng GIS dồn text)
  static Map<String, String> extractAttributesFromRawNote(String note) {
    final Map<String, String> result = {};
    if (note.trim().isEmpty) return result;

    // 1. Dạng ngăn cách bằng | (ví dụ: TEN_LO: 283 | DON_VI: DOI 2)
    if (note.contains(':') && note.contains('|')) {
      final parts = note.split('|');
      for (var p in parts) {
        final colonIdx = p.indexOf(':');
        if (colonIdx > 0) {
          final k = p.substring(0, colonIdx).trim();
          final v = p.substring(colonIdx + 1).trim();
          if (k.isNotEmpty && v.isNotEmpty) result[k] = v;
        }
      }
      if (result.isNotEmpty) return result;
    }

    // 2. Dạng chuỗi phẳng GIS dồn text (như hình người dùng: fid 260 TEN_LO 283 ID_LO_2_CAP 5.08NK.D2.10.044...)
    final candidateKeys = [
      'ID_LO_2_CAP', 'ID_LO', 'PHUONG_PHAP_TRONG', 'KHOANG_CACH_TRONG',
      'MAT_DO_CAY_CAO', 'TT_MAT_CAO_2025', 'TT_MAT_CAO', 'NANG_SUAT_2025', 'XEP_HANG_2025',
      'TUOI_CAO_2025', 'CAY_CAO_HH', 'NAM_MO_CAO', 'NAM_TRONG', 'HANG_DAT',
      'CAO_TRINH', 'TEN_DOI', 'DON_VI', 'TEN_LO', 'MAT_DO', 'DIEN_TICH',
      'GIONG', 'DU_AN', 'fid', 'FID', 'DT', 'GHI_CHU', 'NOTE', 'cTy', 'ntruong',
      'tenlo', 'hDat', 'PP_trồng', 'PP_trong', 'Khoảng_c', 'Khoang_c', 'giong',
      'Năm_cạo', 'Nam_cao', 'Chế_đ', 'Che_d', 'Ghi_chu', 'namtrong', 'Ct_TB',
      'Mật_đ', 'Mat_d', 'Dien_tich_', 'Hiện_tr', 'Hien_tr', 'Phân_lo', 'Phan_lo',
      'Dien_tich1', 'HT_VUON', 'ht_vuon', 'ht_vườn', 'NAM_CHUYEN', 'nam_chuyen',
      'CHU_VI', 'chu_vi'
    ];

    candidateKeys.sort((a, b) => b.length.compareTo(a.length));

    final pattern = RegExp(
      '(?:^|\\s)(${candidateKeys.map(RegExp.escape).join('|')})(?:\\s|:|=)',
      caseSensitive: false,
    );

    final matches = pattern.allMatches(note).toList();
    for (int i = 0; i < matches.length; i++) {
      final currentMatch = matches[i];
      final key = currentMatch.group(1)!.trim();
      final valStart = currentMatch.end;
      final valEnd = (i + 1 < matches.length) ? matches[i + 1].start : note.length;
      if (valEnd > valStart) {
        final val = note.substring(valStart, valEnd).replaceAll(RegExp(r'^[=:\s]+|[=:\s]+$'), '').trim();
        if (val.isNotEmpty && !result.containsKey(key)) {
          result[key] = val;
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
          // Quét SchemaData -> SimpleData (chuẩn xuất từ QGIS / ArcGIS / GDAL)
          for (var schemaData in extendedData.findElements('SchemaData')) {
            for (var simpleData in schemaData.findElements('SimpleData')) {
              final attrName = simpleData.getAttribute('name') ?? '';
              final val = simpleData.innerText.trim();
              if (attrName.isNotEmpty && val.isNotEmpty && !attrs.containsKey(attrName)) {
                attrs[attrName] = val;
              }
            }
          }
          for (var simpleData in extendedData.findElements('SimpleData')) {
            final attrName = simpleData.getAttribute('name') ?? '';
            final val = simpleData.innerText.trim();
            if (attrName.isNotEmpty && val.isNotEmpty && !attrs.containsKey(attrName)) {
              attrs[attrName] = val;
            }
          }
        }

        // Helper tìm giá trị thuộc tính linh hoạt (không phân biệt hoa/thường hay gạch dưới)
        String? getVal(List<String> candidateKeys) {
          for (final k in candidateKeys) {
            final target = k.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
            for (final entry in attrs.entries) {
              final current = entry.key.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
              if (current == target && entry.value.trim().isNotEmpty) {
                return entry.value.trim();
              }
            }
          }
          return null;
        }

        // Tách các trường thông tin chuẩn từ thuộc tính (hỗ trợ cả dạng bảng và dạng cặp Key = Value)
        final plotName = getVal(['ten_lo', 'tenlo', 'id_lo', 'idlo', 'lo', 'so_hieu_lo', 'solo']) ?? rawName;
        final khoanhName = getVal(['ntruong', 'nong_truong', 'ten_doi', 'tendoi', 'don_vi', 'donvi', 'khoanh', 'doi']) ?? 'K1';
        final tieuKhuName = getVal(['tieu_khu', 'tieukhu', 'cTy', 'cty', 'cong_ty', 'du_an', 'duan']) ?? 'KMZ';
        final chuRungName = getVal(['cTy', 'cty', 'cong_ty', 'chu_rung', 'churung', 'don_vi']) ?? 'Nhập từ KMZ/KML';

        String loaiCay = 'Theo hồ sơ KMZ';
        final giong = getVal(['giong', 'giong_cay', 'loai_cay', 'loaicay']);
        if (giong != null) {
          loaiCay = giong.toLowerCase().startsWith('cao su') ? giong : 'Cao su giống $giong';
        }

        int? namTrong;
        final rawNam = getVal(['nam_trong', 'namtrong']);
        if (rawNam != null) {
          namTrong = double.tryParse(rawNam)?.toInt();
        }

        String trangThai = 'Rừng quy hoạch KMZ';
        final ht = getVal(['Hiện_tr', 'hien_tr', 'hiện_trạng', 'hien_trang', 'trang_thai', 'trạng_thái', 'tt_mat_cao_2025']);
        if (ht != null) {
          trangThai = (ht == 'CS.KD') ? 'Cao su kinh doanh (CS.KD)' : ht;
        }

        // Tạo ghi chú sạch
        String cleanNote;
        final specificNote = getVal(['ghi_chu', 'note', 'ghi_chu_lo']);
        if (specificNote != null && specificNote.isNotEmpty) {
          cleanNote = specificNote;
        } else if (attrs.isNotEmpty) {
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
              final rawDt = getVal(['dien_tich1', 'dien_tich', 'dt', 'dientich', 'area']);
              if (rawDt != null) {
                final a = double.tryParse(rawDt);
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
