import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Đại diện cho một Lớp phủ Bản đồ Ảnh nắn tọa độ (Geo-referenced Raster Map Overlay)
/// Dùng để hiển thị các tờ bản đồ quy hoạch, sơ đồ đất đai từ file GeoPackage Raster Tiles (.gpkg)
class RasterOverlay {
  final String id;
  final String name;
  final String imagePath; // Đường dẫn file ảnh đã ghép lưu trên máy
  final double south;
  final double north;
  final double west;
  final double east;
  final String groupName;
  double opacity;
  bool isVisible;

  RasterOverlay({
    required this.id,
    required this.name,
    required this.imagePath,
    required this.south,
    required this.north,
    required this.west,
    required this.east,
    required this.groupName,
    this.opacity = 0.88,
    this.isVisible = true,
  });

  LatLngBounds get bounds => LatLngBounds(
        LatLng(south, west),
        LatLng(north, east),
      );

  LatLng get center => LatLng((south + north) / 2, (west + east) / 2);

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'imagePath': imagePath,
        'south': south,
        'north': north,
        'west': west,
        'east': east,
        'groupName': groupName,
        'opacity': opacity,
        'isVisible': isVisible,
      };

  factory RasterOverlay.fromMap(Map<String, dynamic> map) => RasterOverlay(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        imagePath: map['imagePath'] ?? '',
        south: (map['south'] as num).toDouble(),
        north: (map['north'] as num).toDouble(),
        west: (map['west'] as num).toDouble(),
        east: (map['east'] as num).toDouble(),
        groupName: map['groupName'] ?? '',
        opacity: (map['opacity'] as num?)?.toDouble() ?? 0.88,
        isVisible: map['isVisible'] as bool? ?? true,
      );
}
