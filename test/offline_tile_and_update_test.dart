import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:forest_gis/services/persistent_offline_tile_provider.dart';
import 'package:forest_gis/services/app_update_service.dart';

void main() {
  group('Kiểm thử PersistentOfflineTileProvider (Gạch bản đồ ngoại tuyến)', () {
    test('countTilesForBounds tính toán số gạch chính xác cho khu vực', () {
      final bounds = LatLngBounds(
        const LatLng(13.20, 106.20),
        const LatLng(13.35, 106.35),
      );

      final count = PersistentOfflineTileProvider.countTilesForBounds(bounds, 12, 14);
      expect(count, greaterThan(0));
      expect(count, lessThan(200));
    });

    test('PersistentTileKey so sánh bằng nhau chính xác', () {
      const key1 = PersistentTileKey(url: 'https://test.com/1/2/3', baseLayerKey: 'googleHybrid', x: 2, y: 3, z: 1);
      const key2 = PersistentTileKey(url: 'https://test.com/1/2/3', baseLayerKey: 'googleHybrid', x: 2, y: 3, z: 1);
      const key3 = PersistentTileKey(url: 'https://test.com/1/2/4', baseLayerKey: 'googleHybrid', x: 2, y: 4, z: 1);

      expect(key1 == key2, isTrue);
      expect(key1 == key3, isFalse);
      expect(key1.hashCode, equals(key2.hashCode));
    });
  });

  group('Kiểm thử AppUpdateService (Tự động cập nhật app)', () {
    test('AppUpdateInfo serialization & deserialization', () {
      final map = {
        'versionCode': 6,
        'versionName': '1.0.5',
        'apkUrl': 'https://github.com/leminhvdm-app/vdm_gis/releases/latest/download/VDM_GIS-release.apk',
        'releaseNotes': 'Bản cập nhật tối ưu bản đồ ngoại tuyến và cập nhật trực tiếp.',
        'forceUpdate': false,
        'publishedAt': '2026-11-22',
      };

      final info = AppUpdateInfo.fromMap(map);
      expect(info.versionCode, 6);
      expect(info.versionName, '1.0.5');
      expect(info.forceUpdate, isFalse);

      final convertedMap = info.toMap();
      expect(convertedMap['versionCode'], 6);
      expect(convertedMap['versionName'], '1.0.5');
    });

    test('currentVersionCode và currentVersionName hợp lệ', () {
      expect(AppUpdateService.currentVersionCode, greaterThanOrEqualTo(4));
      expect(AppUpdateService.currentVersionName.isNotEmpty, isTrue);
    });
  });
}
