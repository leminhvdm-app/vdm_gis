import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../utils/device_helper.dart';

/// Quản lý Bản quyền, Mã Cài Đặt (Installation Code) và Khóa/Mở từ xa
class DeviceLicenseManager {
  static final DeviceLicenseManager _instance = DeviceLicenseManager._internal();
  factory DeviceLicenseManager() => _instance;
  DeviceLicenseManager._internal();

  static const String _secretSalt = "VDM_GIS_FOREST_2026_LICENSE_SECRET";
  static String? _cachedInstallCode;
  static bool? _cachedIsActivated;
  static bool? _cachedIsBlocked;

  static String get cachedInstallCode => _cachedInstallCode ?? 'Đang tải...';
  static bool get isActivatedSync => (_cachedIsActivated ?? false) && !(_cachedIsBlocked ?? false);
  static bool get isBlockedSync => _cachedIsBlocked ?? false;

  static const String defaultFirebaseBaseUrl =
      'https://vdm-gis-default-rtdb.asia-southeast1.firebasedatabase.app';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_device_license.json');
  }

  /// Lấy hoặc tạo mới Mã Cài Đặt (Installation Code) duy nhất cho thiết bị này
  /// Định dạng: VDM-XXXX-YYYY (ví dụ: VDM-7A8B-9C2D)
  static Future<String> getInstallationCode() async {
    if (_cachedInstallCode != null && _cachedInstallCode!.isNotEmpty) {
      return _cachedInstallCode!;
    }

    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          final code = map['installCode'] as String?;
          if (code != null && code.isNotEmpty) {
            _cachedInstallCode = code;
            _cachedIsActivated = map['isActivated'] as bool? ?? false;
            _cachedIsBlocked = map['isBlocked'] as bool? ?? false;
            return code;
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc device license: $e');
    }

    // Nếu chưa có, sinh mã mới dựa trên thông tin máy
    final device = await DeviceHelper.getDeviceDetails();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rawSeed = '${device.manufacturer}_${device.model}_${device.displayName}_$nowMs';

    // Băm sinh ra 8 ký tự Hex viết hoa
    int hash = 0x811c9dc5;
    const prime = 0x01000193;
    for (var i = 0; i < rawSeed.length; i++) {
      hash ^= rawSeed.codeUnitAt(i);
      hash = (hash * prime) & 0xFFFFFFFF;
    }

    final hex1 = ((hash >> 16) & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase();
    final hex2 = (hash & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase();
    final newCode = 'VDM-$hex1-$hex2';

    _cachedInstallCode = newCode;
    _cachedIsActivated = false;
    _cachedIsBlocked = false;

    // Lưu vào file
    await _saveLicense(installCode: newCode, isActivated: false, isBlocked: false, activationKey: '');
    return newCode;
  }

  /// Thuật toán sinh Mã kích hoạt (Activation Key) từ Mã cài đặt (Installation Code)
  /// Định dạng: XXXX-YYYY (ví dụ: 6829-4153)
  static String generateActivationKey(String installCode) {
    final clean = installCode.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    final combined = "$clean$_secretSalt";

    int hash1 = 0x811c9dc5;
    const prime = 0x01000193;
    for (var i = 0; i < combined.length; i++) {
      hash1 ^= combined.codeUnitAt(i);
      hash1 = (hash1 * prime) & 0xFFFFFFFF;
    }

    int hash2 = 0x55555555;
    for (var i = 0; i < combined.length; i++) {
      hash2 = ((hash2 << 5) + hash2) ^ combined.codeUnitAt(i);
      hash2 &= 0xFFFFFFFF;
    }

    final part1 = ((hash1.abs() % 9000) + 1000).toString();
    final part2 = ((hash2.abs() % 9000) + 1000).toString();
    return '$part1-$part2';
  }

  /// Kiểm tra xem mã kích hoạt người dùng nhập có khớp không
  static bool verifyActivationKey(String installCode, String enteredKey) {
    final cleanEntered = enteredKey.replaceAll(RegExp(r'[^0-9]'), '');
    final expectedKey = generateActivationKey(installCode).replaceAll(RegExp(r'[^0-9]'), '');
    return cleanEntered == expectedKey;
  }

  /// Kiểm tra trạng thái kích hoạt của máy
  static Future<bool> isDeviceActivated() async {
    if (_cachedIsBlocked == true) return false;
    if (_cachedIsActivated != null) return _cachedIsActivated!;

    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          _cachedIsBlocked = map['isBlocked'] as bool? ?? false;
          if (_cachedIsBlocked == true) return false;
          _cachedIsActivated = map['isActivated'] as bool? ?? false;
          _cachedInstallCode = map['installCode'] as String?;
          return _cachedIsActivated!;
        }
      }
    } catch (_) {}

    _cachedIsActivated = false;
    return false;
  }

  /// Kích hoạt máy thành công
  static Future<void> activateDevice(String activationKey) async {
    final code = await getInstallationCode();
    _cachedIsActivated = true;
    _cachedIsBlocked = false;
    await _saveLicense(
      installCode: code,
      isActivated: true,
      isBlocked: false,
      activationKey: activationKey,
      activatedAt: DateTime.now().toIso8601String(),
    );
  }

  /// Đặt lại trạng thái kích hoạt hoặc khóa máy
  static Future<void> resetActivation({bool isBlocked = false}) async {
    final code = await getInstallationCode();
    _cachedIsActivated = false;
    _cachedIsBlocked = isBlocked;
    await _saveLicense(
      installCode: code,
      isActivated: false,
      isBlocked: isBlocked,
      activationKey: '',
    );
  }

  /// Kiểm tra trực tiếp trên Firebase xem máy này có bị Quản trị viên KHÓA không
  /// Trả về true nếu bị khóa, false nếu bình thường
  static Future<bool> checkRemoteBlockStatus({String? firebaseBaseUrl}) async {
    try {
      final code = await getInstallationCode();
      final cleanCode = code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      final base = (firebaseBaseUrl != null && firebaseBaseUrl.isNotEmpty)
          ? firebaseBaseUrl
          : defaultFirebaseBaseUrl;

      // 1. Kiểm tra node danh sách khóa tập trung
      final blockUrl = '$base/vdm_gis/danh_sach_khoa/$cleanCode.json';
      try {
        final res = await http.get(Uri.parse(blockUrl)).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
          final dynamic val = jsonDecode(res.body);
          if (val == true || val == 'true') {
            // Bị khóa từ xa!
            await resetActivation(isBlocked: true);
            return true;
          }
        }
      } catch (_) {}

      // 2. Kiểm tra node danh sách kích hoạt trực tiếp
      final actUrl = '$base/vdm_gis/danh_sach_kich_hoat/$cleanCode.json';
      try {
        final resAct = await http.get(Uri.parse(actUrl)).timeout(const Duration(seconds: 4));
        if (resAct.statusCode == 200 && resAct.body.isNotEmpty && resAct.body != 'null') {
          final dynamic val = jsonDecode(resAct.body);
          if (val == false || val == 'false') {
            await resetActivation(isBlocked: true);
            return true;
          }
        }
      } catch (_) {}

      // 3. Kiểm tra trường isBlocked & isActivated trong /vdm_gis/thiet_bi_cai_dat.json
      final listUrl = '$base/vdm_gis/thiet_bi_cai_dat.json';
      try {
        final resList = await http.get(Uri.parse(listUrl)).timeout(const Duration(seconds: 4));
        if (resList.statusCode == 200 && resList.body.isNotEmpty && resList.body != 'null') {
          final dynamic data = jsonDecode(resList.body);
          if (data is Map) {
            for (final entry in data.values) {
              if (entry is Map) {
                final deviceCode = (entry['maCaiDat'] ?? entry['Mã cài đặt'] ?? entry['installCode'])?.toString();
                if (deviceCode == code) {
                  final isBlk = entry['isBlocked'] == true || entry['Đã khóa'] == true;
                  final isAct = entry['isActivated'] == true || entry['Đã kích hoạt'] == true;
                  final trangThai = entry['trangThai']?.toString();
                  // Nếu quản lý đánh dấu khóa hoặc chưa kích hoạt
                  if (isBlk || !isAct || trangThai == 'Đã khóa' || trangThai == 'Chưa kích hoạt') {
                    await resetActivation(isBlocked: true);
                    return true;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      _cachedIsBlocked = false;
      return false;
    } catch (_) {
      // Ngoại tuyến thì giữ nguyên trạng thái cache
      return _cachedIsBlocked ?? false;
    }
  }

  /// Kiểm tra trực tiếp trên Firebase xem thiết bị này đã được Quản trị viên duyệt kích hoạt chưa
  static Future<bool> checkRemoteActivationStatus({String? firebaseBaseUrl}) async {
    try {
      final code = await getInstallationCode();
      final cleanCode = code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      final base = (firebaseBaseUrl != null && firebaseBaseUrl.isNotEmpty)
          ? firebaseBaseUrl
          : defaultFirebaseBaseUrl;

      // 1. Kiểm tra node danh sách kích hoạt trực tiếp: /vdm_gis/danh_sach_kich_hoat/$cleanCode.json
      final directUrl = '$base/vdm_gis/danh_sach_kich_hoat/$cleanCode.json';
      try {
        final res = await http.get(Uri.parse(directUrl)).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
          final dynamic val = jsonDecode(res.body);
          if (val == true || val == 'true') {
            final expectedKey = generateActivationKey(code);
            await activateDevice(expectedKey);
            return true;
          }
        }
      } catch (_) {}

      // 2. Kiểm tra trong danh sách thiết bị cài đặt /vdm_gis/thiet_bi_cai_dat.json
      final listUrl = '$base/vdm_gis/thiet_bi_cai_dat.json';
      try {
        final resList = await http.get(Uri.parse(listUrl)).timeout(const Duration(seconds: 4));
        if (resList.statusCode == 200 && resList.body.isNotEmpty && resList.body != 'null') {
          final dynamic data = jsonDecode(resList.body);
          if (data is Map) {
            for (final entry in data.values) {
              if (entry is Map) {
                final deviceCode = (entry['maCaiDat'] ?? entry['Mã cài đặt'])?.toString();
                if (deviceCode == code) {
                  final isBlk = entry['isBlocked'] == true || entry['Đã khóa'] == true;
                  if (isBlk) {
                    await resetActivation(isBlocked: true);
                    return false;
                  }
                  final isAct = entry['isActivated'] == true || entry['Đã kích hoạt'] == true;
                  if (isAct) {
                    final expectedKey = generateActivationKey(code);
                    await activateDevice(expectedKey);
                    return true;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('Lỗi check remote activation: $e');
    }
    return _cachedIsActivated ?? false;
  }

  static Future<void> _saveLicense({
    required String installCode,
    required bool isActivated,
    required bool isBlocked,
    required String activationKey,
    String? activatedAt,
  }) async {
    try {
      final file = await _getFile();
      final map = {
        'installCode': installCode,
        'isActivated': isActivated,
        'isBlocked': isBlocked,
        'activationKey': activationKey,
        'activatedAt': activatedAt,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('Lỗi lưu license: $e');
    }
  }
}
