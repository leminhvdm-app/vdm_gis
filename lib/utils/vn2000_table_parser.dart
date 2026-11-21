import 'dart:io';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/forest_plot.dart';
import 'gis_calculator.dart';
import 'vn2000_converter.dart';

class Vn2000TableParser {
  /// Danh sách kinh tuyến trục phổ biến các tỉnh lâm nghiệp Việt Nam
  static final Map<String, double> provinceMeridians = {
    'Đắk Nông': 108.5,
    'Đắk Lắk': 108.5,
    'Đồng Nai': 107.75,
    'Lâm Đồng': 107.75,
    'Bình Phước': 106.25,
    'Gia Lai': 108.25,
    'Kon Tum': 107.5,
    'Bình Thuận': 107.5,
    'Bà Rịa - Vũng Tàu': 107.75,
    'Tây Ninh': 105.75,
    'Khánh Hòa': 108.25,
    'Phú Yên': 108.5,
    'Quảng Nam': 107.75,
    'Thừa Thiên Huế': 107.0,
    'Hà Nội': 105.0,
  };

  /// Trích xuất bảng tọa độ VN-2000 trực tiếp từ file PDF (như file Ban Do Tong DNK.pdf)
  static Future<List<LatLng>> extractCoordinatesFromPdf(String filePath, {double centralMeridian = 108.5}) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final document = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(document).extractText();
      document.dispose();

      if (text.trim().isNotEmpty) {
        return parseCoordinatesFromText(text, centralMeridian: centralMeridian);
      }
    } catch (e) {
      debugPrint('Lỗi trích xuất PDF: $e');
    }
    return [];
  }

  /// Phân tích chuỗi văn bản chứa bảng tọa độ X, Y (hoặc copy-paste từ PDF/Sổ đỏ/Biên bản)
  static List<LatLng> parseCoordinatesFromText(String text, {double centralMeridian = 108.5}) {
    final List<LatLng> points = [];
    final lines = text.split(RegExp(r'[\r\n]+'));

    for (var line in lines) {
      // 1. Tìm cặp: 6 chữ số (Easting ~ 300.000 - 700.000) và 7 chữ số (Northing ~ 1.000.000 - 2.500.000)
      final match1 = RegExp(r'\b([3-8]\d{5}(?:\.\d+)?)\b[\s,\t]+([1-2]\d{6}(?:\.\d+)?)\b').firstMatch(line);
      if (match1 != null) {
        final easting = double.tryParse(match1.group(1)!);
        final northing = double.tryParse(match1.group(2)!);
        if (easting != null && northing != null) {
          points.add(Vn2000Converter.toWGS84(
            northing: northing,
            easting: easting,
            centralMeridian: centralMeridian,
          ));
          continue;
        }
      }

      // 2. Tìm cặp ngược lại: 7 chữ số trước (Northing), 6 chữ số sau (Easting)
      final match2 = RegExp(r'\b([1-2]\d{6}(?:\.\d+)?)\b[\s,\t]+([3-8]\d{5}(?:\.\d+)?)\b').firstMatch(line);
      if (match2 != null) {
        final northing = double.tryParse(match2.group(1)!);
        final easting = double.tryParse(match2.group(2)!);
        if (northing != null && easting != null) {
          points.add(Vn2000Converter.toWGS84(
            northing: northing,
            easting: easting,
            centralMeridian: centralMeridian,
          ));
        }
      }
    }

    return points;
  }

  /// Tạo một đối tượng ForestPlot từ danh sách tọa độ VN-2000
  static ForestPlot createPlotFromVn2000Points({
    required String name,
    required List<LatLng> points,
    String tieuKhu = 'Bản đồ PDF',
    String khoanh = 'K1',
    String trangThai = 'Rừng quy hoạch theo bản đồ',
    Color color = const Color(0xFF673AB7),
    String groupName = 'Bản đồ PDF VN-2000',
  }) {
    final areaHa = GisCalculator.calculateAreaInHectares(points);

    return ForestPlot(
      id: 'VN2000_${DateTime.now().millisecondsSinceEpoch}',
      tieuKhu: tieuKhu,
      khoanh: khoanh,
      lo: name,
      dienTich: double.parse(areaHa.toStringAsFixed(2)),
      chuRung: 'Trích lục từ bản đồ',
      trangThaiRung: trangThai,
      loaiCay: 'Theo hồ sơ bản vẽ',
      boundary: points,
      color: color,
      note: 'Nhập từ bảng tọa độ VN-2000 (${points.length} đỉnh)',
      groupName: groupName,
    );
  }
}
