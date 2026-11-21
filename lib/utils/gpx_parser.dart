import 'dart:io';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';
import 'gis_calculator.dart';

class GpxParseResult {
  final List<ForestPlot> plots;
  final List<ForestPoi> pois;

  GpxParseResult({required this.plots, required this.pois});
}

class GpxParser {
  /// Đọc và phân tích file GPX từ File
  static Future<GpxParseResult> parseFile(File file, {String? defaultGroupName}) async {
    final content = await file.readAsString();
    final group = defaultGroupName ?? file.uri.pathSegments.last;
    return parse(content, defaultGroupName: group);
  }

  /// Phân tích nội dung chuỗi XML GPX
  static GpxParseResult parse(String gpxContent, {String defaultGroupName = 'Tập dữ liệu GPX'}) {
    final List<ForestPlot> plots = [];
    final List<ForestPoi> pois = [];

    try {
      final doc = XmlDocument.parse(gpxContent);

      // 1. Quét Waypoints (<wpt>) -> ForestPoi
      final waypoints = doc.findAllElements('wpt');
      int poiIndex = 1;
      for (var wpt in waypoints) {
        final latStr = wpt.getAttribute('lat');
        final lonStr = wpt.getAttribute('lon');
        if (latStr == null || lonStr == null) continue;

        final lat = double.tryParse(latStr);
        final lon = double.tryParse(lonStr);
        if (lat == null || lon == null) continue;

        final name = wpt.findElements('name').firstOrNull?.innerText.trim() ?? 'Điểm GPX $poiIndex';
        final desc = wpt.findElements('desc').firstOrNull?.innerText.trim() ?? 'Tọa độ từ file GPX';

        pois.add(ForestPoi(
          id: 'GPX_POI_${DateTime.now().millisecondsSinceEpoch}_$poiIndex',
          title: name,
          description: desc,
          position: LatLng(lat, lon),
          type: PoiType.boundaryMark,
          timestamp: DateTime.now(),
          severity: 'Bình thường',
          groupName: defaultGroupName,
        ));
        poiIndex++;
      }

      // 2. Quét Tracks (<trk>) -> Tuyến hoặc Đa giác Lô
      final tracks = doc.findAllElements('trk');
      int trackIndex = 1;
      for (var trk in tracks) {
        final trackName = trk.findElements('name').firstOrNull?.innerText.trim() ?? 'Đường ranh GPX $trackIndex';
        final desc = trk.findElements('desc').firstOrNull?.innerText.trim() ?? '';

        final List<LatLng> points = [];
        final segments = trk.findAllElements('trkseg');
        for (var seg in segments) {
          final trkpts = seg.findAllElements('trkpt');
          for (var pt in trkpts) {
            final latStr = pt.getAttribute('lat');
            final lonStr = pt.getAttribute('lon');
            if (latStr != null && lonStr != null) {
              final lat = double.tryParse(latStr);
              final lon = double.tryParse(lonStr);
              if (lat != null && lon != null) {
                points.add(LatLng(lat, lon));
              }
            }
          }
        }

        if (points.length >= 3) {
          final areaHa = GisCalculator.calculateAreaInHectares(points);
          plots.add(ForestPlot(
            id: 'GPX_${DateTime.now().millisecondsSinceEpoch}_$trackIndex',
            tieuKhu: 'GPX',
            khoanh: 'K1',
            lo: trackName,
            dienTich: double.parse(areaHa.toStringAsFixed(2)),
            chuRung: 'Nhập từ file GPX',
            trangThaiRung: 'Ranh giới đo đạc GPX',
            loaiCay: 'Theo định vị GPS',
            boundary: points,
            color: const Color(0xFF00897B),
            note: desc.isNotEmpty ? desc : 'Đường ranh khép kín từ máy định vị GPS cầm tay',
            groupName: defaultGroupName,
          ));
          trackIndex++;
        }
      }

      // 3. Quét Routes (<rte>) nếu có
      final routes = doc.findAllElements('rte');
      int routeIndex = 1;
      for (var rte in routes) {
        final rName = rte.findElements('name').firstOrNull?.innerText.trim() ?? 'Tuyến lộ trình GPX $routeIndex';
        final List<LatLng> points = [];
        for (var pt in rte.findAllElements('rtept')) {
          final latStr = pt.getAttribute('lat');
          final lonStr = pt.getAttribute('lon');
          if (latStr != null && lonStr != null) {
            final lat = double.tryParse(latStr);
            final lon = double.tryParse(lonStr);
            if (lat != null && lon != null) {
              points.add(LatLng(lat, lon));
            }
          }
        }

        if (points.length >= 3) {
          final areaHa = GisCalculator.calculateAreaInHectares(points);
          plots.add(ForestPlot(
            id: 'GPX_RTE_${DateTime.now().millisecondsSinceEpoch}_$routeIndex',
            tieuKhu: 'GPX',
            khoanh: 'Tuyến $routeIndex',
            lo: rName,
            dienTich: double.parse(areaHa.toStringAsFixed(2)),
            chuRung: 'Lộ trình GPX',
            trangThaiRung: 'Tuyến đo thực địa',
            loaiCay: 'Theo định vị GPS',
            boundary: points,
            color: const Color(0xFF3F51B5),
            note: 'Tuyến đo từ thiết bị định vị GPS',
            groupName: defaultGroupName,
          ));
          routeIndex++;
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc GPX: $e');
    }

    return GpxParseResult(plots: plots, pois: pois);
  }
}
