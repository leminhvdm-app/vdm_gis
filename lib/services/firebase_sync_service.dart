import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';

class SyncConfig {
  static const String defaultFirebaseUrl =
      'https://vdm-gis-default-rtdb.asia-southeast1.firebasedatabase.app';

  String url;
  bool rememberUrl;
  String secret;
  String deviceTag;
  bool autoSync;
  DateTime? lastSyncTime;

  SyncConfig({
    this.url = defaultFirebaseUrl,
    this.rememberUrl = true,
    this.secret = '',
    this.deviceTag = 'Thiết bị thực địa 1',
    this.autoSync = true,
    this.lastSyncTime,
  });

  Map<String, dynamic> toMap() => {
        'url': rememberUrl ? url : '',
        'rememberUrl': rememberUrl,
        'secret': rememberUrl ? secret : '',
        'deviceTag': deviceTag,
        'autoSync': autoSync,
        'lastSyncTime': lastSyncTime?.toIso8601String(),
      };

  factory SyncConfig.fromMap(Map<String, dynamic> map) {
    final rawUrl = map['url'] as String? ?? '';
    return SyncConfig(
      url: rawUrl.trim().isNotEmpty ? rawUrl.trim() : defaultFirebaseUrl,
      rememberUrl: map['rememberUrl'] as bool? ?? true,
      secret: map['secret'] as String? ?? '',
      deviceTag: map['deviceTag'] as String? ?? 'Thiết bị thực địa 1',
      autoSync: map['autoSync'] as bool? ?? true,
      lastSyncTime: map['lastSyncTime'] != null
          ? DateTime.tryParse(map['lastSyncTime'] as String)
          : null,
    );
  }
}

class SyncResult {
  final bool success;
  final bool isOfflineQueued;
  final String message;
  final int plotCount;
  final int poiCount;

  SyncResult({
    required this.success,
    this.isOfflineQueued = false,
    required this.message,
    this.plotCount = 0,
    this.poiCount = 0,
  });

  factory SyncResult.success(String message, {int plotCount = 0, int poiCount = 0}) =>
      SyncResult(success: true, message: message, plotCount: plotCount, poiCount: poiCount);

  factory SyncResult.offlineQueued(String message, {int plotCount = 0, int poiCount = 0}) =>
      SyncResult(success: true, isOfflineQueued: true, message: message, plotCount: plotCount, poiCount: poiCount);

  factory SyncResult.failure(String message) =>
      SyncResult(success: false, message: message);
}

class FirebaseDatasetItem {
  final String key;
  final String groupName;
  final int plotCount;
  final int poiCount;
  final String deviceTag;
  final DateTime? updatedAt;
  final String path;

  FirebaseDatasetItem({
    required this.key,
    required this.groupName,
    this.plotCount = 0,
    this.poiCount = 0,
    this.deviceTag = '',
    this.updatedAt,
    this.path = 'vdm_gis/datasets',
  });

  String get displayName => groupName.trim().isNotEmpty ? groupName.trim() : key;
}

class FirebaseSyncService {
  static final FirebaseSyncService _instance = FirebaseSyncService._internal();
  factory FirebaseSyncService() => _instance;
  FirebaseSyncService._internal();

  SyncConfig _config = SyncConfig();
  SyncConfig get config => _config;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  Future<File> _getConfigFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_gis_sync_config.json');
  }

  Future<File> _getQueueFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_gis_offline_sync_queue.json');
  }

  Future<void> loadConfig() async {
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          _config = SyncConfig.fromMap(map);
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc config đồng bộ: $e');
    }
  }

  Future<void> saveConfig(SyncConfig config) async {
    _config = config;
    try {
      final file = await _getConfigFile();
      await file.writeAsString(jsonEncode(config.toMap()));
    } catch (e) {
      debugPrint('Lỗi lưu config đồng bộ: $e');
    }
  }

  String normalizeUrl(String rawUrl) {
    var u = rawUrl.trim();
    if (u.isEmpty) {
      u = SyncConfig.defaultFirebaseUrl;
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  String sanitizeFirebaseKey(String key) {
    return key.replaceAll(RegExp(r'[\.\#\$\[\]\/]'), '_');
  }

  /// Đẩy dữ liệu của một nhóm hoặc toàn bộ lên Firebase.
  /// Nếu không có mạng hoặc lỗi kết nối, tự động lưu vào hàng đợi Offline Cache.
  Future<SyncResult> pushDataset({
    required String groupName,
    required List<ForestPlot> plots,
    required List<ForestPoi> pois,
  }) async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) {
      return SyncResult.failure('Chưa cấu hình URL Firebase. Vui lòng nhập URL!');
    }

    _isSyncing = true;
    final sanitizedKey = sanitizeFirebaseKey(groupName);
    final authQuery = _config.secret.trim().isNotEmpty ? '?auth=${_config.secret.trim()}' : '';
    final endpoints = [
      '$baseUrl/vdm_gis/datasets/$sanitizedKey.json$authQuery',
      '$baseUrl/datasets/$sanitizedKey.json$authQuery',
    ];

    final payload = {
      'groupName': groupName,
      'deviceTag': _config.deviceTag,
      'updatedAt': DateTime.now().toIso8601String(),
      'plotCount': plots.length,
      'poiCount': pois.length,
      'plots': plots.map((p) => p.toMap()).toList(),
      'pois': pois.map((p) => p.toMap()).toList(),
    };

    try {
      bool anySuccess = false;
      int lastStatusCode = 0;
      for (var ep in endpoints) {
        final res = await http
            .put(
              Uri.parse(ep),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 8))
            .catchError((_) => http.Response('', 500));
        lastStatusCode = res.statusCode;
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anySuccess = true;
        }
      }

      _isSyncing = false;
      if (anySuccess) {
        _config.lastSyncTime = DateTime.now();
        await saveConfig(_config);
        processOfflineQueue();
        return SyncResult.success(
          'Đã đồng bộ thành công lên Firebase!\n(${plots.length} Lô, ${pois.length} Mốc)',
          plotCount: plots.length,
          poiCount: pois.length,
        );
      } else {
        await _enqueueOffline(payload);
        return SyncResult.offlineQueued(
          'Máy chủ phản hồi mã $lastStatusCode. Đã lưu vào bộ nhớ cache máy để thử lại khi có mạng!',
          plotCount: plots.length,
          poiCount: pois.length,
        );
      }
    } catch (e) {
      _isSyncing = false;
      // Không có mạng (SocketException, Timeout, ClientException) -> lưu hàng đợi offline
      await _enqueueOffline(payload);
      return SyncResult.offlineQueued(
        'Không có mạng (Ngoại tuyến). Đã lưu vào bộ nhớ cache máy!\nKhi có mạng sẽ tự động đẩy lên server.',
        plotCount: plots.length,
        poiCount: pois.length,
      );
    }
  }

  Future<void> _enqueueOffline(Map<String, dynamic> item) async {
    try {
      final file = await _getQueueFile();
      List<dynamic> queue = [];
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          queue = jsonDecode(content) as List<dynamic>;
        }
      }
      // Tránh trùng groupName trong queue
      queue.removeWhere((e) => e is Map && e['groupName'] == item['groupName']);
      queue.add(item);
      await file.writeAsString(jsonEncode(queue));
    } catch (e) {
      debugPrint('Lỗi ghi offline queue: $e');
    }
  }

  Future<int> getPendingQueueCount() async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return 0;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return 0;
      final queue = jsonDecode(content) as List<dynamic>;
      return queue.length;
    } catch (_) {
      return 0;
    }
  }

  /// Tự động xử lý đẩy dữ liệu từ hàng đợi Offline lên Firebase khi có mạng
  Future<int> processOfflineQueue() async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) return 0;

    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return 0;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return 0;

      final queue = (jsonDecode(content) as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (queue.isEmpty) return 0;

      int syncedCount = 0;
      final remaining = <Map<String, dynamic>>[];

      for (var item in queue) {
        final groupName = item['groupName'] as String? ?? 'Chung';
        final sanitizedKey = sanitizeFirebaseKey(groupName);
        var endpoint = '$baseUrl/vdm_gis/datasets/$sanitizedKey.json';
        if (_config.secret.trim().isNotEmpty) {
          endpoint += '?auth=${_config.secret.trim()}';
        }

        try {
          final uri = Uri.parse(endpoint);
          final response = await http
              .put(
                uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(item),
              )
              .timeout(const Duration(seconds: 6));

          if (response.statusCode >= 200 && response.statusCode < 300) {
            syncedCount++;
          } else {
            remaining.add(item);
          }
        } catch (_) {
          remaining.add(item);
        }
      }

      await file.writeAsString(jsonEncode(remaining));
      if (syncedCount > 0) {
        _config.lastSyncTime = DateTime.now();
        await saveConfig(_config);
      }
      return syncedCount;
    } catch (e) {
      debugPrint('Lỗi xử lý offline queue: $e');
      return 0;
    }
  }

  /// Lấy danh sách các nhóm dữ liệu có trên Firebase
  Future<List<String>> fetchFirebaseDatasets() async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) return [];

    final Set<String> allKeys = {};
    final authParam = _config.secret.trim().isNotEmpty ? '&auth=${_config.secret.trim()}' : '';

    for (var path in ['vdm_gis/datasets', 'datasets']) {
      final endpoint = '$baseUrl/$path.json?shallow=true$authParam';
      try {
        final response = await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final data = jsonDecode(response.body);
          if (data is Map) {
            allKeys.addAll(data.keys.map((k) => k.toString()));
          }
        }
      } catch (e) {
        debugPrint('Lỗi lấy danh sách dataset từ $endpoint: $e');
      }
    }
    return allKeys.toList();
  }

  /// Lấy danh sách các file/nhóm dữ liệu kèm đầy đủ chi tiết (tên, số lô, số mốc, ngày giờ cập nhật, thiết bị)
  Future<List<FirebaseDatasetItem>> fetchDetailedDatasets() async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) return [];

    final authParam = _config.secret.trim().isNotEmpty ? '?auth=${_config.secret.trim()}' : '';
    final Map<String, String> keyPathMap = {};

    // 1. Quét /vdm_gis/datasets
    try {
      final ep1 = '$baseUrl/vdm_gis/datasets.json?shallow=true${authParam.isNotEmpty ? '&auth=${_config.secret.trim()}' : ''}';
      final res1 = await http.get(Uri.parse(ep1)).timeout(const Duration(seconds: 8));
      if (res1.statusCode >= 200 && res1.statusCode < 300) {
        final data = jsonDecode(res1.body);
        if (data is Map) {
          for (var k in data.keys) {
            keyPathMap[k.toString()] = 'vdm_gis/datasets';
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi quét /vdm_gis/datasets: $e');
    }

    // 2. Quét /datasets
    try {
      final ep2 = '$baseUrl/datasets.json?shallow=true${authParam.isNotEmpty ? '&auth=${_config.secret.trim()}' : ''}';
      final res2 = await http.get(Uri.parse(ep2)).timeout(const Duration(seconds: 8));
      if (res2.statusCode >= 200 && res2.statusCode < 300) {
        final data = jsonDecode(res2.body);
        if (data is Map) {
          for (var k in data.keys) {
            keyPathMap.putIfAbsent(k.toString(), () => 'datasets');
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi quét /datasets: $e');
    }

    if (keyPathMap.isEmpty) return [];

    // 3. Tải metadata của từng key song song
    final List<FirebaseDatasetItem> items = [];
    final futures = keyPathMap.entries.map((entry) async {
      final key = entry.key;
      final path = entry.value;

      String groupName = key;
      int plotCount = 0;
      int poiCount = 0;
      String deviceTag = '';
      DateTime? updatedAt;

      try {
        final fieldUrl = '$baseUrl/$path/$key/groupName.json$authParam';
        final countUrl = '$baseUrl/$path/$key/plotCount.json$authParam';
        final poiUrl = '$baseUrl/$path/$key/poiCount.json$authParam';
        final devUrl = '$baseUrl/$path/$key/deviceTag.json$authParam';
        final dateUrl = '$baseUrl/$path/$key/updatedAt.json$authParam';

        final results = await Future.wait([
          http.get(Uri.parse(fieldUrl)).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 500)),
          http.get(Uri.parse(countUrl)).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 500)),
          http.get(Uri.parse(poiUrl)).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 500)),
          http.get(Uri.parse(devUrl)).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 500)),
          http.get(Uri.parse(dateUrl)).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 500)),
        ]);

        if (results[0].statusCode == 200 && results[0].body.isNotEmpty && results[0].body != 'null') {
          final val = jsonDecode(results[0].body);
          if (val is String && val.trim().isNotEmpty) groupName = val.trim();
        }
        if (results[1].statusCode == 200 && results[1].body.isNotEmpty && results[1].body != 'null') {
          final val = jsonDecode(results[1].body);
          if (val is num) plotCount = val.toInt();
        }
        if (results[2].statusCode == 200 && results[2].body.isNotEmpty && results[2].body != 'null') {
          final val = jsonDecode(results[2].body);
          if (val is num) poiCount = val.toInt();
        }
        if (results[3].statusCode == 200 && results[3].body.isNotEmpty && results[3].body != 'null') {
          final val = jsonDecode(results[3].body);
          if (val is String) deviceTag = val;
        }
        if (results[4].statusCode == 200 && results[4].body.isNotEmpty && results[4].body != 'null') {
          final val = jsonDecode(results[4].body);
          if (val is String) updatedAt = DateTime.tryParse(val);
        }
      } catch (_) {}

      items.add(FirebaseDatasetItem(
        key: key,
        groupName: groupName,
        plotCount: plotCount,
        poiCount: poiCount,
        deviceTag: deviceTag,
        updatedAt: updatedAt,
        path: path,
      ));
    });

    await Future.wait(futures);
    // Sắp xếp: ngày cập nhật mới nhất lên đầu
    items.sort((a, b) {
      if (a.updatedAt == null && b.updatedAt == null) return a.displayName.compareTo(b.displayName);
      if (a.updatedAt == null) return 1;
      if (b.updatedAt == null) return -1;
      return b.updatedAt!.compareTo(a.updatedAt!);
    });

    return items;
  }

  /// Tải dữ liệu của một nhóm từ Firebase về máy
  Future<Map<String, dynamic>?> pullDataset(String datasetKey, {String? customPath}) async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) return null;

    final sanitizedKey = sanitizeFirebaseKey(datasetKey);
    final authParam = _config.secret.trim().isNotEmpty ? '?auth=${_config.secret.trim()}' : '';

    final pathsToTry = customPath != null
        ? [customPath]
        : ['vdm_gis/datasets', 'datasets'];

    for (var path in pathsToTry) {
      final endpoint = '$baseUrl/$path/$sanitizedKey.json$authParam';
      try {
        final response = await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && (data['plots'] != null || data['pois'] != null || data['groupName'] != null)) {
            return data;
          }
        }
      } catch (e) {
        debugPrint('Lỗi kéo dữ liệu từ $endpoint: $e');
      }
    }
    return null;
  }

  /// Xóa một nhóm dữ liệu trên Firebase
  Future<bool> deleteDataset(String datasetKey) async {
    final baseUrl = normalizeUrl(_config.url);
    if (baseUrl.isEmpty) return false;

    final sanitizedKey = sanitizeFirebaseKey(datasetKey);
    final authParam = _config.secret.trim().isNotEmpty ? '?auth=${_config.secret.trim()}' : '';

    bool deletedAny = false;
    for (var path in ['vdm_gis/datasets', 'datasets']) {
      final endpoint = '$baseUrl/$path/$sanitizedKey.json$authParam';
      try {
        final response = await http.delete(Uri.parse(endpoint)).timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          deletedAny = true;
        }
      } catch (e) {
        debugPrint('Lỗi xóa dataset $datasetKey tại $endpoint: $e');
      }
    }
    return deletedAny;
  }
}
