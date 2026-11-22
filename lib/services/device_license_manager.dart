import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/device_helper.dart';

/// Quản lý Bản quyền, Mã Cài Đặt (Installation Code) và Mã Kích Hoạt (Activation Key)
class DeviceLicenseManager {
  static final DeviceLicenseManager _instance = DeviceLicenseManager._internal();
  factory DeviceLicenseManager() => _instance;
  DeviceLicenseManager._internal();

  static const String _secretSalt = "VDM_GIS_FOREST_2026_LICENSE_SECRET";
  static String? _cachedInstallCode;
  static bool? _cachedIsActivated;

  static String get cachedInstallCode => _cachedInstallCode ?? 'Đang tải...';
  static bool get isActivatedSync => _cachedIsActivated ?? false;

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

    // Lưu vào file
    await _saveLicense(installCode: newCode, isActivated: false, activationKey: '');
    return newCode;
  }

  /// Thuật toán sinh Mã kích hoạt (Activation Key) từ Mã cài đặt (Installation Code)
  /// Định dạng: XXXX-YYYY (ví dụ: 6829-4153 hoặc VDM-6829-4153)
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
    if (_cachedIsActivated != null) return _cachedIsActivated!;

    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
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
    await _saveLicense(
      installCode: code,
      isActivated: true,
      activationKey: activationKey,
      activatedAt: DateTime.now().toIso8601String(),
    );
  }

  /// Đặt lại trạng thái kích hoạt (dành cho quản trị)
  static Future<void> resetActivation() async {
    final code = await getInstallationCode();
    _cachedIsActivated = false;
    await _saveLicense(
      installCode: code,
      isActivated: false,
      activationKey: '',
    );
  }

  static Future<void> _saveLicense({
    required String installCode,
    required bool isActivated,
    required String activationKey,
    String? activatedAt,
  }) async {
    try {
      final file = await _getFile();
      final map = {
        'installCode': installCode,
        'isActivated': isActivated,
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
