import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// Provider gạch bản đồ lưu trữ vĩnh viễn vào bộ nhớ máy (Offline Persistent Tile Cache)
/// Tối ưu đa luồng kết nối, hỗ trợ bản đồ khu vực mặc định, không bao giờ bị trắng khi zoom xa.
class PersistentOfflineTileProvider extends TileProvider {
  final String baseLayerKey;
  static Directory? _cacheDirectory;
  static final Map<String, Uint8List> _memCache = {};

  /// Tái sử dụng HTTP Client với kết nối Keep-Alive (tránh mở lại SSL handshake)
  static final http.Client _sharedHttpClient = http.Client();

  PersistentOfflineTileProvider({
    required this.baseLayerKey,
    super.headers,
  });

  /// Thư mục lưu trữ gạch bản đồ vĩnh viễn (nằm trong Documents, không bị OS tự xóa)
  static Future<Directory> getCacheDir() async {
    if (_cacheDirectory != null) return _cacheDirectory!;
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/map_tile_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDirectory = dir;
    return dir;
  }

  /// Tính tổng dung lượng gạch bản đồ đã lưu trên máy
  static Future<double> getCacheSizeInMb() async {
    try {
      final dir = await getCacheDir();
      int totalBytes = 0;
      if (await dir.exists()) {
        await for (final file in dir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            totalBytes += await file.length();
          }
        }
      }
      return totalBytes / (1024 * 1024);
    } catch (_) {
      return 0.0;
    }
  }

  /// Xóa toàn bộ bộ nhớ đệm gạch bản đồ
  static Future<void> clearAllCache() async {
    try {
      _memCache.clear();
      final dir = await getCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('Lỗi xóa cache gạch bản đồ: $e');
    }
  }

  // ==========================================
  // QUẢN LÝ BẢN ĐỒ KHU VỰC NGOẠI TUYẾN MẶC ĐỊNH
  // ==========================================

  /// Lưu khu vực hiện tại làm "Bản đồ Mặc định" của máy
  static Future<void> saveDefaultRegion({
    required LatLngBounds bounds,
    String name = 'Khu vực làm việc mặc định',
  }) async {
    try {
      final dir = await getCacheDir();
      final file = File('${dir.path}/default_region.json');
      final data = {
        'name': name,
        'south': bounds.south,
        'west': bounds.west,
        'north': bounds.north,
        'east': bounds.east,
        'savedAt': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Lỗi lưu khu vực mặc định: $e');
    }
  }

  /// Lấy thông tin khu vực mặc định đã lưu
  static Future<Map<String, dynamic>?> getDefaultRegion() async {
    try {
      final dir = await getCacheDir();
      final file = File('${dir.path}/default_region.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Lỗi đọc khu vực mặc định: $e');
    }
    return null;
  }

  /// Kiểm tra xem một tọa độ có nằm trong khu vực mặc định hay không
  static Future<bool> isInsideDefaultRegion(LatLng point) async {
    try {
      final region = await getDefaultRegion();
      if (region == null) return false;
      final south = (region['south'] as num).toDouble();
      final west = (region['west'] as num).toDouble();
      final north = (region['north'] as num).toDouble();
      final east = (region['east'] as num).toDouble();

      return point.latitude >= south &&
          point.latitude <= north &&
          point.longitude >= west &&
          point.longitude <= east;
    } catch (_) {
      return false;
    }
  }

  /// Tự động nạp ngầm các mức zoom tổng quan (Zoom nhỏ z=6..12) cho khu vực
  /// Đảm bảo khi zoom xa thu nhỏ bản đồ không bao giờ bị màu trắng
  static Future<int> preloadOverviewTiles({
    required LatLngBounds bounds,
    required String urlTemplate,
    required String baseLayerKey,
    int minZoom = 7,
    int maxZoom = 12,
  }) async {
    final cacheDir = await getCacheDir();
    int count = 0;

    for (int z = minZoom; z <= maxZoom; z++) {
      final x1 = _lon2tile(bounds.west, z);
      final x2 = _lon2tile(bounds.east, z);
      final y1 = _lat2tile(bounds.north, z);
      final y2 = _lat2tile(bounds.south, z);
      final xMin = math.min(x1, x2);
      final xMax = math.max(x1, x2);
      final yMin = math.min(y1, y2);
      final yMax = math.max(y1, y2);

      for (int x = xMin; x <= xMax; x++) {
        for (int y = yMin; y <= yMax; y++) {
          final tileFile = File('${cacheDir.path}/$baseLayerKey/$z/${x}_$y.tile');
          if (!await tileFile.exists()) {
            final s = ((x + y).abs() % 4).toString();
            final url = urlTemplate
                .replaceAll('{z}', '$z')
                .replaceAll('{x}', '$x')
                .replaceAll('{y}', '$y')
                .replaceAll('{s}', s)
                .replaceAll('mt1.google.com', 'mt$s.google.com');

            try {
              final res = await _sharedHttpClient.get(
                Uri.parse(url),
                headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 10; VDM_GIS)'},
              ).timeout(const Duration(seconds: 4));

              if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
                await tileFile.parent.create(recursive: true);
                await tileFile.writeAsBytes(res.bodyBytes);
                count++;
              }
            } catch (_) {}
          }
        }
      }
    }
    return count;
  }

  /// Tính toán số gạch bản đồ (tiles) cho một khu vực tọa độ và dải zoom
  static int countTilesForBounds(LatLngBounds bounds, int minZoom, int maxZoom) {
    int count = 0;
    for (int z = minZoom; z <= maxZoom; z++) {
      final x1 = _lon2tile(bounds.west, z);
      final x2 = _lon2tile(bounds.east, z);
      final y1 = _lat2tile(bounds.north, z);
      final y2 = _lat2tile(bounds.south, z);
      final xMin = math.min(x1, x2);
      final xMax = math.max(x1, x2);
      final yMin = math.min(y1, y2);
      final yMax = math.max(y1, y2);
      count += (xMax - xMin + 1) * (yMax - yMin + 1);
    }
    return count;
  }

  /// Tải trước toàn bộ gạch bản đồ cho một khu vực (cả tổng quan lẫn chi tiết)
  static Stream<double> downloadRegion({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    required String urlTemplate,
    required String baseLayerKey,
    void Function(int downloaded, int total)? onProgress,
  }) async* {
    final cacheDir = await getCacheDir();
    final total = countTilesForBounds(bounds, minZoom, maxZoom);
    if (total == 0) return;

    int downloaded = 0;

    for (int z = minZoom; z <= maxZoom; z++) {
      final x1 = _lon2tile(bounds.west, z);
      final x2 = _lon2tile(bounds.east, z);
      final y1 = _lat2tile(bounds.north, z);
      final y2 = _lat2tile(bounds.south, z);
      final xMin = math.min(x1, x2);
      final xMax = math.max(x1, x2);
      final yMin = math.min(y1, y2);
      final yMax = math.max(y1, y2);

      for (int x = xMin; x <= xMax; x++) {
        for (int y = yMin; y <= yMax; y++) {
          final tileFile = File('${cacheDir.path}/$baseLayerKey/$z/${x}_$y.tile');
          if (!await tileFile.exists()) {
            final s = ((x + y).abs() % 4).toString();
            final url = urlTemplate
                .replaceAll('{z}', '$z')
                .replaceAll('{x}', '$x')
                .replaceAll('{y}', '$y')
                .replaceAll('{s}', s)
                .replaceAll('mt1.google.com', 'mt$s.google.com');

            try {
              final res = await _sharedHttpClient.get(
                Uri.parse(url),
                headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 10; VDM_GIS)'},
              ).timeout(const Duration(seconds: 4));

              if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
                await tileFile.parent.create(recursive: true);
                await tileFile.writeAsBytes(res.bodyBytes);
              }
            } catch (_) {}
          }

          downloaded++;
          final progress = downloaded / total;
          onProgress?.call(downloaded, total);
          yield progress;
        }
      }
    }
  }

  static int _lon2tile(double lon, int zoom) =>
      ((lon + 180.0) / 360.0 * (1 << zoom)).floor().clamp(0, (1 << zoom) - 1);

  static int _lat2tile(double lat, int zoom) {
    final latRad = lat * math.pi / 180.0;
    final n = math.log(math.tan(latRad) + 1.0 / math.cos(latRad));
    final y = ((1.0 - n / math.pi) / 2.0 * (1 << zoom)).floor();
    return y.clamp(0, (1 << zoom) - 1);
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final fallbackUrl = getTileFallbackUrl(coordinates, options);
    return PersistentTileImageProvider(
      url: url,
      fallbackUrl: fallbackUrl,
      coordinates: coordinates,
      baseLayerKey: baseLayerKey,
      headers: headers,
    );
  }
}

@immutable
class PersistentTileKey {
  final String url;
  final String baseLayerKey;
  final int x;
  final int y;
  final int z;

  const PersistentTileKey({
    required this.url,
    required this.baseLayerKey,
    required this.x,
    required this.y,
    required this.z,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistentTileKey &&
          other.url == url &&
          other.baseLayerKey == baseLayerKey &&
          other.x == x &&
          other.y == y &&
          other.z == z;

  @override
  int get hashCode => Object.hash(url, baseLayerKey, x, y, z);
}

class PersistentTileImageProvider extends ImageProvider<PersistentTileKey> {
  final String url;
  final String? fallbackUrl;
  final TileCoordinates coordinates;
  final String baseLayerKey;
  final Map<String, String> headers;

  PersistentTileImageProvider({
    required this.url,
    this.fallbackUrl,
    required this.coordinates,
    required this.baseLayerKey,
    required this.headers,
  });

  @override
  Future<PersistentTileKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<PersistentTileKey>(
      PersistentTileKey(
        url: url,
        baseLayerKey: baseLayerKey,
        x: coordinates.x,
        y: coordinates.y,
        z: coordinates.z,
      ),
    );
  }

  @override
  ImageStreamCompleter loadImage(PersistentTileKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<PersistentTileKey>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(PersistentTileKey key, ImageDecoderCallback decode) async {
    final memKey = '${key.baseLayerKey}_${key.z}_${key.x}_${key.y}';

    // 1. Kiểm tra RAM cache tốc độ cao
    final memBytes = PersistentOfflineTileProvider._memCache[memKey];
    if (memBytes != null && memBytes.isNotEmpty) {
      final buffer = await ui.ImmutableBuffer.fromUint8List(memBytes);
      return decode(buffer);
    }

    // 2. Kiểm tra bộ nhớ đĩa vĩnh viễn: map_tile_cache/{baseLayer}/{z}/{x}_{y}.tile
    final cacheDir = await PersistentOfflineTileProvider.getCacheDir();
    final tileFile = File('${cacheDir.path}/${key.baseLayerKey}/${key.z}/${key.x}_${key.y}.tile');

    if (await tileFile.exists()) {
      try {
        final bytes = await tileFile.readAsBytes();
        if (bytes.isNotEmpty) {
          if (PersistentOfflineTileProvider._memCache.length > 800) {
            PersistentOfflineTileProvider._memCache.clear();
          }
          PersistentOfflineTileProvider._memCache[memKey] = bytes;

          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          return await decode(buffer);
        }
      } catch (e) {
        debugPrint('Lỗi đọc tile cache từ đĩa: $e');
      }
    }

    // 3. Phân phối luồng tải Google sang 4 cụm máy chủ mt0, mt1, mt2, mt3
    final s = ((key.x + key.y).abs() % 4).toString();
    String effectiveUrl = key.url
        .replaceAll('{s}', s)
        .replaceAll('mt1.google.com', 'mt$s.google.com');

    try {
      final uri = Uri.parse(effectiveUrl);
      final reqHeaders = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10; VDM_GIS)',
        'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8',
        ...headers,
      };

      final response = await PersistentOfflineTileProvider._sharedHttpClient
          .get(uri, headers: reqHeaders)
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final bytes = response.bodyBytes;

        // Lưu vào đĩa ngay lập tức
        tileFile.parent.create(recursive: true).then((_) {
          tileFile.writeAsBytes(bytes).catchError((_) => tileFile);
        });

        if (PersistentOfflineTileProvider._memCache.length > 800) {
          PersistentOfflineTileProvider._memCache.clear();
        }
        PersistentOfflineTileProvider._memCache[memKey] = bytes;

        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return await decode(buffer);
      }
    } catch (_) {}

    // 4. Nếu tải chính thất bại: Tự động Fallback sang Esri World Imagery vệ tinh
    String? effectiveFallback = fallbackUrl;
    if ((effectiveFallback == null || effectiveFallback.isEmpty) && key.baseLayerKey.contains('google')) {
      effectiveFallback =
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${key.z}/${key.y}/${key.x}';
    }

    if (effectiveFallback != null && effectiveFallback.isNotEmpty) {
      try {
        final fallbackUri = Uri.parse(effectiveFallback);
        final response = await PersistentOfflineTileProvider._sharedHttpClient
            .get(fallbackUri, headers: headers)
            .timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          final bytes = response.bodyBytes;
          tileFile.parent.create(recursive: true).then((_) {
            tileFile.writeAsBytes(bytes).catchError((_) => tileFile);
          });
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          return await decode(buffer);
        }
      } catch (_) {}
    }

    // 5. Nếu ngoại tuyến hoàn toàn và chưa có gạch này: Trả về ảnh trong suốt
    final buffer = await ui.ImmutableBuffer.fromUint8List(TileProvider.transparentImage);
    return await decode(buffer);
  }
}
