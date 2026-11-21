import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum PoiType {
  fire,       // Cháy rừng
  logging,    // Khai thác gỗ lậu
  landslide,  // Sạt lở đất
  wildlife,   // Động vật / bẫy săn
  encroach,   // Lấn chiếm rừng
  boundaryMark// Cột mốc ranh giới
}

class ForestPoi {
  final String id;
  final String title;
  final String description;
  final LatLng position;
  final PoiType type;
  final DateTime timestamp;
  final String tieuKhu;
  final String khoanh;
  final String lo;
  final String severity; // Nhẹ, Cảnh báo, Khẩn cấp
  final String groupName;
  final DateTime? reminderTime; // Thời gian báo thức / nhắc nhở
  final bool reminderEnabled;   // Bật/tắt chế độ nhắc nhở
  final bool proximityAlert;    // Cảnh báo khi đi vào bán kính gần (<100m)

  ForestPoi({
    required this.id,
    required this.title,
    required this.description,
    required this.position,
    required this.type,
    required this.timestamp,
    this.tieuKhu = '',
    this.khoanh = '',
    this.lo = '',
    this.severity = 'Cảnh báo',
    this.groupName = 'Dữ liệu mặc định',
    this.reminderTime,
    this.reminderEnabled = false,
    this.proximityAlert = true,
  });

  String get typeName {
    switch (type) {
      case PoiType.fire:
        return 'Điểm cháy rừng';
      case PoiType.logging:
        return 'Khai thác trái phép';
      case PoiType.landslide:
        return 'Sạt lở đất đá';
      case PoiType.wildlife:
        return 'Bẫy săn / Động vật';
      case PoiType.encroach:
        return 'Lấn chiếm đất rừng';
      case PoiType.boundaryMark:
        return 'Cột mốc ranh giới';
    }
  }

  IconData get icon {
    switch (type) {
      case PoiType.fire:
        return Icons.local_fire_department;
      case PoiType.logging:
        return Icons.warning_amber_rounded;
      case PoiType.landslide:
        return Icons.landslide;
      case PoiType.wildlife:
        return Icons.pets;
      case PoiType.encroach:
        return Icons.fence;
      case PoiType.boundaryMark:
        return Icons.flag;
    }
  }

  Color get color {
    switch (type) {
      case PoiType.fire:
        return Colors.red;
      case PoiType.logging:
        return Colors.deepOrange;
      case PoiType.landslide:
        return Colors.amber[800]!;
      case PoiType.wildlife:
        return Colors.purple;
      case PoiType.encroach:
        return Colors.brown;
      case PoiType.boundaryMark:
        return Colors.blue[800]!;
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'tieuKhu': tieuKhu,
      'khoanh': khoanh,
      'lo': lo,
      'severity': severity,
      'groupName': groupName,
      'reminderTime': reminderTime?.toIso8601String(),
      'reminderEnabled': reminderEnabled,
      'proximityAlert': proximityAlert,
    };
  }

  factory ForestPoi.fromMap(Map<String, dynamic> map) {
    PoiType poiType = PoiType.boundaryMark;
    final typeStr = map['type']?.toString();
    for (var t in PoiType.values) {
      if (t.name == typeStr) {
        poiType = t;
        break;
      }
    }

    return ForestPoi(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      position: LatLng(
        (map['latitude'] as num?)?.toDouble() ?? 0.0,
        (map['longitude'] as num?)?.toDouble() ?? 0.0,
      ),
      type: poiType,
      timestamp: DateTime.tryParse(map['timestamp']?.toString() ?? '') ?? DateTime.now(),
      tieuKhu: map['tieuKhu']?.toString() ?? '',
      khoanh: map['khoanh']?.toString() ?? '',
      lo: map['lo']?.toString() ?? '',
      severity: map['severity']?.toString() ?? 'Cảnh báo',
      groupName: map['groupName']?.toString() ?? 'Dữ liệu mặc định',
      reminderTime: map['reminderTime'] != null
          ? DateTime.tryParse(map['reminderTime'].toString())
          : null,
      reminderEnabled: map['reminderEnabled'] as bool? ?? false,
      proximityAlert: map['proximityAlert'] as bool? ?? true,
    );
  }
}
