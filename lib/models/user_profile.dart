import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class UserProfile {
  String fullName;
  String company;
  String unit;

  UserProfile({
    this.fullName = '',
    this.company = '',
    this.unit = '',
  });

  bool get isEmpty =>
      fullName.trim().isEmpty && company.trim().isEmpty && unit.trim().isEmpty;

  /// Lấy chữ cái viết tắt sắc nét từ họ và tên người dùng (ví dụ: võ đức minh -> VDM)
  String get initials {
    final clean = fullName.trim();
    if (clean.isEmpty) return 'VDM';
    final parts = clean.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'VDM';

    String unaccent(String str) {
      if (str.isEmpty) return '';
      final ch = str[0].toUpperCase();
      const vietnameseMap = {
        'A': ['Á', 'À', 'Ả', 'Ã', 'Ạ', 'Ă', 'Ắ', 'Ằ', 'Ẳ', 'Ẵ', 'Ặ', 'Â', 'Ấ', 'Ầ', 'Ẩ', 'Ẫ', 'Ậ'],
        'D': ['Đ'],
        'E': ['É', 'È', 'Ẻ', 'Ẽ', 'Ẹ', 'Ê', 'Ế', 'Ề', 'Ể', 'Ễ', 'Ệ'],
        'I': ['Í', 'Ì', 'Ỉ', 'Ĩ', 'Ị'],
        'O': ['Ó', 'Ò', 'Ỏ', 'Õ', 'Ọ', 'Ô', 'Ố', 'Ồ', 'Ổ', 'Ỗ', 'Ộ', 'Ơ', 'Ớ', 'Ờ', 'Ở', 'Ỡ', 'Ợ'],
        'U': ['Ú', 'Ù', 'Ủ', 'Ũ', 'Ụ', 'Ư', 'Ứ', 'Ừ', 'Ử', 'Ữ', 'Ự'],
        'Y': ['Ý', 'Ỳ', 'Ỷ', 'Ỹ', 'Ỵ'],
      };
      for (final entry in vietnameseMap.entries) {
        if (entry.value.contains(ch)) return entry.key;
      }
      return ch;
    }

    if (parts.length == 1) {
      final p = parts[0];
      if (p.length >= 3) {
        return '${unaccent(p[0])}${unaccent(p[1])}${unaccent(p[2])}';
      }
      return unaccent(p[0]);
    }

    if (parts.length <= 4) {
      return parts.map((p) => unaccent(p)).join();
    } else {
      return '${unaccent(parts.first)}${unaccent(parts[parts.length - 2])}${unaccent(parts.last)}';
    }
  }

  Map<String, dynamic> toMap() => {
        'fullName': fullName.trim(),
        'company': company.trim(),
        'unit': unit.trim(),
      };

  factory UserProfile.fromMap(Map<String, dynamic> map) => UserProfile(
        fullName: map['fullName'] as String? ?? '',
        company: map['company'] as String? ?? '',
        unit: map['unit'] as String? ?? '',
      );

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_gis_user_profile.json');
  }

  static Future<UserProfile> load() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          return UserProfile.fromMap(map);
        }
      }
    } catch (e) {
      debugPrint('Lỗi load user profile: $e');
    }
    return UserProfile();
  }

  Future<void> save() async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(toMap()));
    } catch (e) {
      debugPrint('Lỗi save user profile: $e');
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Lỗi clear user profile: $e');
    }
  }
}
