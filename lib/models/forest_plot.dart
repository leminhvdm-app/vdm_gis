import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class ForestPlot {
  final String id;
  String tieuKhu;
  String khoanh;
  String lo;
  double dienTich; // hec-ta
  String chuRung;
  String trangThaiRung;
  String loaiCay;
  int? namTrong;
  double? truLuong; // m3/ha
  List<LatLng> boundary;
  Color color;
  String note;
  Map<String, String> attributes;
  String groupName;

  double? _minLat;
  double? _maxLat;
  double? _minLng;
  double? _maxLng;

  ForestPlot({
    required this.id,
    required this.tieuKhu,
    required this.khoanh,
    required this.lo,
    required this.dienTich,
    required this.chuRung,
    required this.trangThaiRung,
    required this.loaiCay,
    this.namTrong,
    this.truLuong,
    required this.boundary,
    required this.color,
    this.note = '',
    this.attributes = const {},
    this.groupName = 'Dữ liệu mặc định',
  }) {
    _computeBoundsIfNeeded();
  }

  void _computeBoundsIfNeeded() {
    if (boundary.isEmpty) {
      _minLat = _maxLat = _minLng = _maxLng = 0;
      return;
    }
    double minLat = boundary[0].latitude;
    double maxLat = boundary[0].latitude;
    double minLng = boundary[0].longitude;
    double maxLng = boundary[0].longitude;
    for (int i = 1; i < boundary.length; i++) {
      final p = boundary[i];
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _minLat = minLat;
    _maxLat = maxLat;
    _minLng = minLng;
    _maxLng = maxLng;
  }

  void invalidateBounds() {
    _minLat = null;
    _maxLat = null;
    _minLng = null;
    _maxLng = null;
    _computeBoundsIfNeeded();
  }

  /// Kiểm tra nhanh lô có nằm trong khung nhìn màn hình hay không (Spatial Viewport Culling)
  bool isVisibleIn(double south, double north, double west, double east) {
    if (boundary.isEmpty) return true;
    _computeBoundsIfNeeded();
    if (_minLat == null) return true;
    return !(_minLat! > north ||
        _maxLat! < south ||
        _minLng! > east ||
        _maxLng! < west);
  }

  String get fullName => '$tieuKhu - $khoanh - $lo';

  LatLng get center {
    if (boundary.isEmpty) return const LatLng(11.35, 107.05);
    double sumLat = 0;
    double sumLng = 0;
    for (var point in boundary) {
      sumLat += point.latitude;
      sumLng += point.longitude;
    }
    return LatLng(sumLat / boundary.length, sumLng / boundary.length);
  }

  /// Kiểm tra nhanh toạ độ có nằm trong Lô rừng (kết hợp Bounding Box và Ray-Casting)
  bool containsPoint(LatLng pt) {
    if (boundary.length < 3) return false;
    _computeBoundsIfNeeded();
    if (_minLat == null) return false;
    if (pt.latitude < _minLat! || pt.latitude > _maxLat! || pt.longitude < _minLng! || pt.longitude > _maxLng!) {
      return false;
    }
    int intersectCount = 0;
    for (int i = 0; i < boundary.length; i++) {
      int next = (i + 1) % boundary.length;
      final p1 = boundary[i];
      final p2 = boundary[next];
      if ((p1.longitude > pt.longitude) != (p2.longitude > pt.longitude)) {
        double intersectLat = (p2.latitude - p1.latitude) *
                (pt.longitude - p1.longitude) /
                (p2.longitude - p1.longitude) +
            p1.latitude;
        if (pt.latitude < intersectLat) {
          intersectCount++;
        }
      }
    }
    return (intersectCount % 2) == 1;
  }

  ForestPlot copyWith({
    String? id,
    String? tieuKhu,
    String? khoanh,
    String? lo,
    double? dienTich,
    String? chuRung,
    String? trangThaiRung,
    String? loaiCay,
    int? namTrong,
    double? truLuong,
    List<LatLng>? boundary,
    Color? color,
    String? note,
    Map<String, String>? attributes,
    String? groupName,
  }) {
    return ForestPlot(
      id: id ?? this.id,
      tieuKhu: tieuKhu ?? this.tieuKhu,
      khoanh: khoanh ?? this.khoanh,
      lo: lo ?? this.lo,
      dienTich: dienTich ?? this.dienTich,
      chuRung: chuRung ?? this.chuRung,
      trangThaiRung: trangThaiRung ?? this.trangThaiRung,
      loaiCay: loaiCay ?? this.loaiCay,
      namTrong: namTrong ?? this.namTrong,
      truLuong: truLuong ?? this.truLuong,
      boundary: boundary ?? List.from(this.boundary),
      color: color ?? this.color,
      note: note ?? this.note,
      attributes: attributes ?? Map.from(this.attributes),
      groupName: groupName ?? this.groupName,
    );
  }

  Map<String, dynamic> toGeoJsonFeature() {
    return {
      'type': 'Feature',
      'properties': {
        'id': id,
        'tieu_khu': tieuKhu,
        'khoanh': khoanh,
        'lo': lo,
        'dien_tich': dienTich,
        'chu_rung': chuRung,
        'trang_thai': trangThaiRung,
        'loai_cay': loaiCay,
        'nam_trong': namTrong,
        'tru_luong': truLuong,
        'ghi_chu': note,
        'attributes': attributes,
        'group_name': groupName,
      },
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            ...boundary.map((p) => [p.longitude, p.latitude]),
            if (boundary.isNotEmpty) [boundary.first.longitude, boundary.first.latitude],
          ]
        ],
      },
    };
  }

  factory ForestPlot.fromGeoJsonFeature(Map<String, dynamic> feature, int index) {
    final properties = feature['properties'] as Map<String, dynamic>? ?? {};
    final geometry = feature['geometry'] as Map<String, dynamic>? ?? {};
    final coordinates = geometry['coordinates'] as List? ?? [];

    List<LatLng> points = [];
    if (coordinates.isNotEmpty) {
      var ring = coordinates[0];
      if (ring is List) {
        for (var coord in ring) {
          if (coord is List && coord.length >= 2) {
            points.add(LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()));
          }
        }
      }
    }

    final trangThai = properties['trang_thai']?.toString() ??
        properties['trangthai']?.toString() ??
        properties['trang_thai_rung']?.toString() ??
        'Rừng tự nhiên';

    Color plotColor;
    if (trangThai.toLowerCase().contains('trồng') || trangThai.toLowerCase().contains('keo')) {
      plotColor = const Color(0xFF66BB6A);
    } else if (trangThai.toLowerCase().contains('cao su')) {
      plotColor = const Color(0xFFFFA726);
    } else if (trangThai.toLowerCase().contains('trống') || trangThai.toLowerCase().contains('bụi')) {
      plotColor = const Color(0xFF8D6E63);
    } else {
      plotColor = const Color(0xFF2E7D32);
    }

    return ForestPlot(
      id: properties['id']?.toString() ?? 'Lô $index',
      tieuKhu: properties['tieu_khu']?.toString() ?? properties['tieukhu']?.toString() ?? 'TK 101',
      khoanh: properties['khoanh']?.toString() ?? 'K 1',
      lo: properties['lo']?.toString() ?? 'Lô $index',
      dienTich: (properties['dien_tich'] as num?)?.toDouble() ?? 5.0,
      chuRung: properties['chu_rung']?.toString() ?? 'Ban Quản Lý Rừng',
      trangThaiRung: trangThai,
      loaiCay: properties['loai_cay']?.toString() ?? 'Hỗn giao bản địa',
      namTrong: (properties['nam_trong'] as num?)?.toInt(),
      truLuong: (properties['tru_luong'] as num?)?.toDouble(),
      boundary: points,
      color: plotColor,
      note: properties['ghi_chu']?.toString() ?? '',
      attributes: (properties['attributes'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? const {},
      groupName: properties['group_name']?.toString() ?? properties['nhom']?.toString() ?? 'Dữ liệu GeoJSON',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tieuKhu': tieuKhu,
      'khoanh': khoanh,
      'lo': lo,
      'dienTich': dienTich,
      'chuRung': chuRung,
      'trangThaiRung': trangThaiRung,
      'loaiCay': loaiCay,
      'namTrong': namTrong,
      'truLuong': truLuong,
      'boundary': boundary.map((p) => [p.latitude, p.longitude]).toList(),
      'color': color.toARGB32(),
      'note': note,
      'attributes': attributes,
      'groupName': groupName,
    };
  }

  factory ForestPlot.fromMap(Map<String, dynamic> map) {
    final rawBoundary = map['boundary'] as List<dynamic>? ?? [];
    final boundary = rawBoundary.map((pt) {
      if (pt is List && pt.length >= 2) {
        return LatLng((pt[0] as num).toDouble(), (pt[1] as num).toDouble());
      }
      return const LatLng(0, 0);
    }).toList();

    return ForestPlot(
      id: map['id']?.toString() ?? '',
      tieuKhu: map['tieuKhu']?.toString() ?? '',
      khoanh: map['khoanh']?.toString() ?? '',
      lo: map['lo']?.toString() ?? '',
      dienTich: (map['dienTich'] as num?)?.toDouble() ?? 0.0,
      chuRung: map['chuRung']?.toString() ?? '',
      trangThaiRung: map['trangThaiRung']?.toString() ?? '',
      loaiCay: map['loaiCay']?.toString() ?? '',
      namTrong: (map['namTrong'] as num?)?.toInt(),
      truLuong: (map['truLuong'] as num?)?.toDouble(),
      boundary: boundary,
      color: Color((map['color'] as num?)?.toInt() ?? 0xFF2E7D32),
      note: map['note']?.toString() ?? '',
      attributes: (map['attributes'] as Map<dynamic, dynamic>?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          {},
      groupName: map['groupName']?.toString() ?? 'Dữ liệu mặc định',
    );
  }
}
