import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/user_profile.dart';
import '../utils/device_helper.dart';
import 'firebase_sync_service.dart';

class UserSessionTracker {
  static final UserSessionTracker _instance = UserSessionTracker._internal();
  factory UserSessionTracker() => _instance;
  UserSessionTracker._internal();

  DateTime? _installTime;
  DateTime? _sessionStartTime;
  DateTime? _sessionEndTime;
  int _accumulatedSecondsBeforeSession = 0;
  int _sessionCount = 0;
  String _currentSessionKey = 'Lan_01';
  Timer? _heartbeatTimer;
  UserProfile _userProfile = UserProfile();
  bool _isInitialized = false;

  DateTime get installTime => _installTime ?? DateTime.now();
  int get sessionCount => _sessionCount;

  static String formatVietnameseDateTime(DateTime dt) {
    final h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    return '$h giờ $m phút $s giây ngày $day/$month/$year';
  }

  static String formatVietnameseDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h giờ $m phút $s giây';
  }

  Future<File> _getStatsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_gis_usage_stats.json');
  }

  /// Khởi tạo và bắt đầu theo dõi phiên làm việc
  Future<void> initAndStartSession({UserProfile? userProfile}) async {
    if (userProfile != null) {
      _userProfile = userProfile;
    } else {
      _userProfile = await UserProfile.load();
    }

    try {
      final file = await _getStatsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          if (map['installTime'] != null) {
            _installTime = DateTime.tryParse(map['installTime'].toString());
          }
          _accumulatedSecondsBeforeSession = (map['accumulatedSeconds'] as num?)?.toInt() ?? 0;
          _sessionCount = (map['sessionCount'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc stats sử dụng: $e');
    }

    // Nếu là lần đầu tiên mở app, ghi nhận thời gian cài đặt
    _installTime ??= DateTime.now();

    _sessionCount += 1;
    _currentSessionKey = 'Lan_${_sessionCount.toString().padLeft(2, '0')}';
    _sessionStartTime = DateTime.now();
    _sessionEndTime = DateTime.now();
    _isInitialized = true;

    // Lưu lại file stats local
    await _saveStats();

    // Đồng bộ mở đầu phiên lên Firebase
    await _pushSessionToFirebase(isInitial: true);

    // Heartbeat định kỳ mỗi 30 giây để cập nhật liên tục thời gian kết thúc và tổng thời gian sử dụng
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _onHeartbeat();
    });
  }

  /// Cập nhật thông tin cán bộ khi người dùng sửa hồ sơ
  Future<void> updateUserProfile(UserProfile profile) async {
    _userProfile = profile;
    if (_isInitialized) {
      await _pushSessionToFirebase(isInitial: false);
    }
  }

  /// Gọi khi app tiếp tục hoạt động (Resumed)
  Future<void> resumeSession(UserProfile? profile) async {
    if (profile != null) _userProfile = profile;
    if (!_isInitialized) {
      await initAndStartSession(userProfile: _userProfile);
      return;
    }
    _sessionEndTime = DateTime.now();
    _onHeartbeat();
  }

  /// Gọi khi app tạm dừng hoặc thoát (Paused / Detached / Inactive)
  Future<void> endSession() async {
    if (!_isInitialized || _sessionStartTime == null) return;

    _sessionEndTime = DateTime.now();
    final sessionSeconds = _sessionEndTime!.difference(_sessionStartTime!).inSeconds;
    final totalSeconds = _accumulatedSecondsBeforeSession + sessionSeconds;
    _accumulatedSecondsBeforeSession = totalSeconds;
    _sessionStartTime = _sessionEndTime; // Reset cho phiên tiếp theo nếu có

    await _saveStats();
    await _pushSessionToFirebase(isInitial: false);
  }

  void _onHeartbeat() {
    if (!_isInitialized || _sessionStartTime == null) return;
    _sessionEndTime = DateTime.now();
    _pushSessionToFirebase(isInitial: false);
  }

  Future<void> _saveStats() async {
    try {
      final file = await _getStatsFile();
      final map = {
        'installTime': _installTime?.toIso8601String(),
        'accumulatedSeconds': _accumulatedSecondsBeforeSession,
        'sessionCount': _sessionCount,
        'lastActive': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('Lỗi lưu stats sử dụng: $e');
    }
  }

  String _sanitizeKey(String key) {
    var k = key.trim();
    if (k.isEmpty) return 'Can_Bo_Chua_Cap_Nhat';
    return k.replaceAll(RegExp(r'[\.\#\$\[\]\/]'), '_');
  }

  /// Đẩy bản ghi phiên này lên Firebase Realtime Database
  Future<void> _pushSessionToFirebase({bool isInitial = false}) async {
    try {
      final syncService = FirebaseSyncService();
      final baseUrl = syncService.normalizeUrl(syncService.config.url);
      if (baseUrl.isEmpty) return;

      final now = DateTime.now();
      final start = _sessionStartTime ?? now;
      final end = _sessionEndTime ?? now;
      final currentSessionSec = end.difference(start).inSeconds;
      final totalSec = _accumulatedSecondsBeforeSession + currentSessionSec;

      final strCaiDat = formatVietnameseDateTime(installTime);
      final strBatDau = formatVietnameseDateTime(start);
      final strKetThuc = formatVietnameseDateTime(end);
      final strPhienNay = formatVietnameseDuration(Duration(seconds: currentSessionSec));
      final strTongTimes = formatVietnameseDuration(Duration(seconds: totalSec));

      final deviceDetails = await DeviceHelper.getDeviceDetails();
      final phoneName = deviceDetails.shortName; // ví dụ: iPhone 15 Pro Max, Samsung SM-S918B
      final deviceFull = deviceDetails.displayName;

      final hoTen = _userProfile.fullName.trim().isNotEmpty
          ? _userProfile.fullName.trim()
          : 'Cán bộ thực địa';
      final congTy = _userProfile.company.trim().isNotEmpty
          ? _userProfile.company.trim()
          : 'Công ty chưa cập nhật';
      final donVi = _userProfile.unit.trim().isNotEmpty
          ? _userProfile.unit.trim()
          : 'Đơn vị chưa cập nhật';

      final sessionPayload = {
        'Họ và Tên': hoTen,
        'Công ty': congTy,
        'Đơn vị': donVi,
        'Điện thoại': phoneName,
        'Thiết bị': deviceFull,
        'Hãng sản xuất': deviceDetails.manufacturer,
        'Model': deviceDetails.model,
        'Hệ điều hành': deviceDetails.osVersion,
        'Times cài đặt': strCaiDat,
        'Times bắt đầu': strBatDau,
        'Times kết thúc': strKetThuc,
        'Thời gian dùng phiên này': strPhienNay,
        'Tổng Times sử dụng': strTongTimes,
        'Lần mở app': 'Lần $_sessionCount',
        'hoVaTen': hoTen,
        'congTy': congTy,
        'donVi': donVi,
        'dienThoai': phoneName,
        'thietBi': deviceFull,
        'hangMay': deviceDetails.manufacturer,
        'model': deviceDetails.model,
        'heDieuHanh': deviceDetails.osVersion,
        'timesCaiDat': strCaiDat,
        'timesBatDau': strBatDau,
        'timesKetThuc': strKetThuc,
        'thoiGianPhienNay': strPhienNay,
        'tongTimesSuDung': strTongTimes,
        'lanMo': 'Lần $_sessionCount',
        'deviceTag': syncService.config.deviceTag,
        'updatedAt': now.toIso8601String(),
      };

      final summaryPayload = {
        'Họ và Tên': hoTen,
        'Công ty': congTy,
        'Đơn vị': donVi,
        'Điện thoại': phoneName,
        'Thiết bị': deviceFull,
        'Hãng sản xuất': deviceDetails.manufacturer,
        'Model': deviceDetails.model,
        'Hệ điều hành': deviceDetails.osVersion,
        'Times cài đặt': strCaiDat,
        'Tổng Times sử dụng': strTongTimes,
        'Tổng số lần mở app': _sessionCount,
        'Lần cuối hoạt động': strKetThuc,
        'hoVaTen': hoTen,
        'congTy': congTy,
        'donVi': donVi,
        'dienThoai': phoneName,
        'thietBi': deviceFull,
        'hangMay': deviceDetails.manufacturer,
        'model': deviceDetails.model,
        'heDieuHanh': deviceDetails.osVersion,
        'timesCaiDat': strCaiDat,
        'tongTimesSuDung': strTongTimes,
        'tongSoLanMo': _sessionCount,
        'lanCuoiHoatDong': strKetThuc,
        'deviceTag': syncService.config.deviceTag,
        'updatedAt': now.toIso8601String(),
      };

      final devicePayload = {
        'Họ và Tên': hoTen,
        'Công ty': congTy,
        'Đơn vị': donVi,
        'Điện thoại': phoneName,
        'Tên thiết bị': deviceFull,
        'Hãng máy': deviceDetails.manufacturer,
        'Model': deviceDetails.model,
        'Hệ điều hành': deviceDetails.osVersion,
        'Times cài đặt': strCaiDat,
        'Lần cuối mở app': strBatDau,
        'Tổng số lần mở app': _sessionCount,
        'Tổng Times sử dụng': strTongTimes,
        'updatedAt': now.toIso8601String(),
        'hoVaTen': hoTen,
        'congTy': congTy,
        'donVi': donVi,
        'dienThoai': phoneName,
        'tenThietBi': deviceFull,
        'hangMay': deviceDetails.manufacturer,
        'model': deviceDetails.model,
        'heDieuHanh': deviceDetails.osVersion,
        'timesCaiDat': strCaiDat,
        'tongSoLanMo': _sessionCount,
        'tongTimesSuDung': strTongTimes,
      };

      final userKey = _sanitizeKey(hoTen);
      var authQuery = '';
      if (syncService.config.secret.trim().isNotEmpty) {
        authQuery = '?auth=${syncService.config.secret.trim()}';
      }

      // 1. Lưu phiên riêng biệt: /thong_tin_su_dung_app/{userKey}/{currentSessionKey}.json
      // Và /vdm_gis/thong_tin_su_dung_app/{userKey}/{currentSessionKey}.json
      final sessionEndpoints = [
        '$baseUrl/thong_tin_su_dung_app/$userKey/$_currentSessionKey.json$authQuery',
        '$baseUrl/vdm_gis/thong_tin_su_dung_app/$userKey/$_currentSessionKey.json$authQuery',
      ];

      for (var ep in sessionEndpoints) {
        http.put(
          Uri.parse(ep),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(sessionPayload),
        ).timeout(const Duration(seconds: 6)).catchError((_) => http.Response('', 500));
      }

      // 2. Cập nhật node Tổng quan: /thong_tin_su_dung_app/{userKey}/Tong_Quan.json
      final summaryEndpoints = [
        '$baseUrl/thong_tin_su_dung_app/$userKey/Tong_Quan.json$authQuery',
        '$baseUrl/vdm_gis/thong_tin_su_dung_app/$userKey/Tong_Quan.json$authQuery',
      ];

      for (var ep in summaryEndpoints) {
        http.put(
          Uri.parse(ep),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(summaryPayload),
        ).timeout(const Duration(seconds: 6)).catchError((_) => http.Response('', 500));
      }

      // 3. Cập nhật node Nhận diện thiết bị cài đặt app: /thiet_bi_cai_dat/{userKey}.json
      final deviceEndpoints = [
        '$baseUrl/thiet_bi_cai_dat/$userKey.json$authQuery',
        '$baseUrl/vdm_gis/thiet_bi_cai_dat/$userKey.json$authQuery',
      ];

      for (var ep in deviceEndpoints) {
        http.put(
          Uri.parse(ep),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(devicePayload),
        ).timeout(const Duration(seconds: 6)).catchError((_) => http.Response('', 500));
      }
    } catch (e) {
      debugPrint('Lỗi đẩy session lên Firebase: $e');
    }
  }

  void dispose() {
    _heartbeatTimer?.cancel();
  }
}
