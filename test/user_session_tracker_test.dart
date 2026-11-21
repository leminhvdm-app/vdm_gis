import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/services/user_session_tracker.dart';

void main() {
  group('UserSessionTracker Tests', () {
    test('formatVietnameseDateTime formats correctly', () {
      final dt = DateTime(2026, 11, 21, 13, 20, 15);
      final formatted = UserSessionTracker.formatVietnameseDateTime(dt);
      expect(formatted, '13 giờ 20 phút 15 giây ngày 21/11/2026');
    });

    test('formatVietnameseDuration formats hours, minutes, seconds', () {
      const d1 = Duration(hours: 2, minutes: 50, seconds: 0);
      expect(UserSessionTracker.formatVietnameseDuration(d1), '2 giờ 50 phút 00 giây');

      const d2 = Duration(hours: 5, minutes: 30, seconds: 15);
      expect(UserSessionTracker.formatVietnameseDuration(d2), '5 giờ 30 phút 15 giây');

      const d3 = Duration(minutes: 9, seconds: 10);
      expect(UserSessionTracker.formatVietnameseDuration(d3), '0 giờ 09 phút 10 giây');
    });
  });
}
