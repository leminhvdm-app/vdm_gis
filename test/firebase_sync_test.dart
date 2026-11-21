import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/services/firebase_sync_service.dart';

void main() {
  group('FirebaseSyncService Tests', () {
    test('SyncConfig serialization & deserialization', () {
      final config = SyncConfig(
        url: 'https://test-gis-default-rtdb.firebaseio.com',
        rememberUrl: true,
        secret: 'test-secret-123',
        deviceTag: 'Tổ Kiểm Lâm 1',
        autoSync: true,
        lastSyncTime: DateTime(2026, 11, 21, 10, 0),
      );

      final map = config.toMap();
      expect(map['url'], 'https://test-gis-default-rtdb.firebaseio.com');
      expect(map['rememberUrl'], true);
      expect(map['secret'], 'test-secret-123');

      final restored = SyncConfig.fromMap(map);
      expect(restored.url, config.url);
      expect(restored.rememberUrl, true);
      expect(restored.deviceTag, 'Tổ Kiểm Lâm 1');
    });

    test('SyncConfig when rememberUrl is false does not persist url in map', () {
      final config = SyncConfig(
        url: 'https://test-gis.firebaseio.com',
        rememberUrl: false,
        secret: 'secret',
      );

      final map = config.toMap();
      expect(map['url'], '');
      expect(map['rememberUrl'], false);
      expect(map['secret'], '');
    });

    test('normalizeUrl cleans trailing slashes and ensures protocol', () {
      final service = FirebaseSyncService();
      expect(service.normalizeUrl('my-db.firebaseio.com/'), 'https://my-db.firebaseio.com');
      expect(service.normalizeUrl('  https://my-db.firebaseio.com///  '), 'https://my-db.firebaseio.com');
    });

    test('sanitizeFirebaseKey removes forbidden characters', () {
      final service = FirebaseSyncService();
      expect(service.sanitizeFirebaseKey('Kratie.2025/Lô#1\$[test]'), 'Kratie_2025_Lô_1__test_');
    });

    test('SyncConfig default url is defaultFirebaseUrl', () {
      final config = SyncConfig();
      expect(config.url, SyncConfig.defaultFirebaseUrl);
    });
  });
}
