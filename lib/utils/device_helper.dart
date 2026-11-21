import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceDetails {
  final String displayName;
  final String shortName;
  final String manufacturer;
  final String model;
  final String osVersion;

  const DeviceDetails({
    required this.displayName,
    required this.shortName,
    required this.manufacturer,
    required this.model,
    required this.osVersion,
  });

  Map<String, dynamic> toMap() => {
        'Tên điện thoại': shortName,
        'Thiết bị': displayName,
        'Hãng sản xuất': manufacturer,
        'Model máy': model,
        'Hệ điều hành': osVersion,
        'tenDienThoai': shortName,
        'thietBi': displayName,
        'hangMay': manufacturer,
        'model': model,
        'heDieuHanh': osVersion,
      };

  @override
  String toString() => displayName;
}

class DeviceHelper {
  static DeviceDetails? _cachedDetails;

  static Future<DeviceDetails> getDeviceDetails() async {
    if (_cachedDetails != null) return _cachedDetails!;

    final plugin = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        final rawMfg = (info.manufacturer).trim();
        final rawBrand = (info.brand).trim();
        final rawModel = (info.model).trim();
        final release = info.version.release;
        final sdk = info.version.sdkInt;

        final mfg = _capitalize(rawMfg.isNotEmpty ? rawMfg : rawBrand);
        String short;
        if (rawModel.toLowerCase().startsWith(mfg.toLowerCase())) {
          short = rawModel;
        } else {
          short = '$mfg $rawModel'.trim();
        }

        final os = 'Android $release (SDK $sdk)';
        final display = '$short ($os)';

        _cachedDetails = DeviceDetails(
          displayName: display,
          shortName: short,
          manufacturer: mfg.isNotEmpty ? mfg : 'Android',
          model: rawModel,
          osVersion: os,
        );
        return _cachedDetails!;
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final machine = info.utsname.machine;
        final friendlyModel = _mapIosMachine(machine) ?? info.model;
        final os = 'iOS ${info.systemVersion}';
        final display = '$friendlyModel ($os)';

        _cachedDetails = DeviceDetails(
          displayName: display,
          shortName: friendlyModel,
          manufacturer: 'Apple',
          model: machine,
          osVersion: os,
        );
        return _cachedDetails!;
      } else if (Platform.isWindows) {
        _cachedDetails = const DeviceDetails(
          displayName: 'Máy tính Windows',
          shortName: 'Windows PC',
          manufacturer: 'Microsoft',
          model: 'Windows',
          osVersion: 'Windows',
        );
        return _cachedDetails!;
      }
    } catch (e) {
      debugPrint('Lỗi đọc thông tin thiết bị: $e');
    }

    _cachedDetails = const DeviceDetails(
      displayName: 'Thiết bị di động',
      shortName: 'Smartphone',
      manufacturer: 'Di động',
      model: 'Chưa xác định',
      osVersion: 'Mobile',
    );
    return _cachedDetails!;
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  static String? _mapIosMachine(String machine) {
    const map = {
      // iPhone 16
      'iPhone17,1': 'iPhone 16 Pro',
      'iPhone17,2': 'iPhone 16 Pro Max',
      'iPhone17,3': 'iPhone 16',
      'iPhone17,4': 'iPhone 16 Plus',
      // iPhone 15
      'iPhone16,1': 'iPhone 15 Pro',
      'iPhone16,2': 'iPhone 15 Pro Max',
      'iPhone15,4': 'iPhone 15',
      'iPhone15,5': 'iPhone 15 Plus',
      // iPhone 14
      'iPhone15,2': 'iPhone 14 Pro',
      'iPhone15,3': 'iPhone 14 Pro Max',
      'iPhone14,7': 'iPhone 14',
      'iPhone14,8': 'iPhone 14 Plus',
      // iPhone 13
      'iPhone14,2': 'iPhone 13 Pro',
      'iPhone14,3': 'iPhone 13 Pro Max',
      'iPhone14,4': 'iPhone 13 mini',
      'iPhone14,5': 'iPhone 13',
      // iPhone 12
      'iPhone13,1': 'iPhone 12 mini',
      'iPhone13,2': 'iPhone 12',
      'iPhone13,3': 'iPhone 12 Pro',
      'iPhone13,4': 'iPhone 12 Pro Max',
      // iPhone 11
      'iPhone12,1': 'iPhone 11',
      'iPhone12,3': 'iPhone 11 Pro',
      'iPhone12,5': 'iPhone 11 Pro Max',
    };
    return map[machine];
  }
}
