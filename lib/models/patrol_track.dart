import 'package:latlong2/latlong.dart';
import '../utils/gis_calculator.dart';

class PatrolTrack {
  final String id;
  final String officerName;
  final DateTime startTime;
  DateTime? endTime;
  final List<LatLng> points;
  bool isActive;

  PatrolTrack({
    required this.id,
    required this.officerName,
    required this.startTime,
    this.endTime,
    List<LatLng>? points,
    this.isActive = true,
  }) : points = points ?? [];

  double get totalDistanceKm {
    return GisCalculator.calculateTotalDistanceInMeters(points) / 1000.0;
  }

  Duration get duration {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime);
  }
}
