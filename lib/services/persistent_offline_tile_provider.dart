import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Provider gạch bản đồ lưu trữ vĩnh viễn vào bộ nhớ máy (Offline Persistent Tile Cache)
/// Đảm bảo khi mất mạng / ngoại tuyến 100% trong rừng sâu, bản đồ vẫn hiển thị mượt mà.
class PersistentOfflineTileProvider extends TileProvider {
  final String baseLayerKey;
  static Directory? _cacheDirectory;
  static final Map<String, Uint8List> _memCache = {};

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

  /// Tải trước toàn bộ gạch bản đồ cho một khu vực để dùng ngoại tuyến
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
    final client = http.Client();

    try {
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
              final url = urlTemplate
                  .replaceAll('{z}', '$z')
                  .replaceAll('{x}', '$x')
                  .replaceAll('{y}', '$y');

              try {
                final res = await client.get(
                  Uri.parse(url),
                  headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 10; VDM_GIS)'},
                ).timeout(const Duration(seconds: 5));

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
    } finally {
      client.close();
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
          if (PersistentOfflineTileProvider._memCache.length > 600) {
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

    // 3. Nếu chưa có trên đĩa, tải từ mạng và ghi ngay vào đĩa
    try {
      final uri = Uri.parse(key.url);
      final reqHeaders = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10; VDM_GIS)',
        'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8',
        ...headers,
      };

      final response = await http.get(uri, headers: reqHeaders).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final bytes = response.bodyBytes;

        // Lưu vào đĩa ngay lập tức
        tileFile.parent.create(recursive: true).then((_) {
          tileFile.writeAsBytes(bytes).catchError((_) => tileFile);
        });

        if (PersistentOfflineTileProvider._memCache.length > 600) {
          PersistentOfflineTileProvider._memCache.clear();
        }
        PersistentOfflineTileProvider._memCache[memKey] = bytes;

        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return await decode(buffer);
      }
    } catch (_) {}

    // 4. Nếu tải chính thất bại và có fallbackUrl
    if (fallbackUrl != null && fallbackUrl!.isNotEmpty) {
      try {
        final fallbackUri = Uri.parse(fallbackUrl!);
        final response = await http.get(fallbackUri, headers: headers).timeout(const Duration(seconds: 6));
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

    // 5. Nếu ngoại tuyến hoàn toàn và chưa có gạch này: Trả về ảnh trong suốt để không làm crash hay đơ map
    final buffer = await ui.ImmutableBuffer.fromUint8List(TileProvider.transparentImage);
    return await decode(buffer);
  }
}
