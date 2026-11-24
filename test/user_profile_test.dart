import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/models/user_profile.dart';

void main() {
  group('UserProfile Tests', () {
    test('UserProfile serialization & deserialization', () {
      final profile = UserProfile(
        fullName: 'Lê Văn Minh',
        company: 'Công ty Lâm Nghiệp Kratie',
        unit: 'Đội Tuần Tra Rừng Số 2',
      );

      final map = profile.toMap();
      expect(map['fullName'], 'Lê Văn Minh');
      expect(map['company'], 'Công ty Lâm Nghiệp Kratie');
      expect(map['unit'], 'Đội Tuần Tra Rừng Số 2');

      final restored = UserProfile.fromMap(map);
      expect(restored.fullName, profile.fullName);
      expect(restored.company, profile.company);
      expect(restored.unit, profile.unit);
      expect(restored.isEmpty, false);
    });

    test('UserProfile isEmpty works correctly', () {
      final empty = UserProfile();
      expect(empty.isEmpty, true);

      final hasName = UserProfile(fullName: 'Minh');
      expect(hasName.isEmpty, false);
    });

    test('UserProfile initials generates sharp uppercase letters', () {
      expect(UserProfile(fullName: 'võ đức minh').initials, 'VDM');
      expect(UserProfile(fullName: 'Võ Đức Minh').initials, 'VDM');
      expect(UserProfile(fullName: 'vo duc minh').initials, 'VDM');
      expect(UserProfile(fullName: 'Lê Văn An').initials, 'LVA');
      expect(UserProfile(fullName: 'Nguyễn').initials, 'NGU');
      expect(UserProfile(fullName: '').initials, 'DNKC');
    });
  });
}
