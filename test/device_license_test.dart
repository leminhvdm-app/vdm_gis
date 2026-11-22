import 'package:flutter_test/flutter_test.dart';
import 'package:forest_gis/services/device_license_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceLicenseManager Tests', () {
    test('generateActivationKey tạo mã kích hoạt đúng định dạng và ổn định', () {
      const installCode = 'VDM-7A8B-9C2D';
      final actKey = DeviceLicenseManager.generateActivationKey(installCode);

      expect(actKey.contains('-'), true, reason: 'Mã kích hoạt phải có dấu gạch ngang phân tách');
      expect(actKey.length, 9, reason: 'Định dạng 4 số - 4 số (ví dụ 6829-4153)');

      // Cùng 1 mã cài đặt thì luôn sinh ra cùng 1 mã kích hoạt (deterministic)
      final actKey2 = DeviceLicenseManager.generateActivationKey(installCode);
      expect(actKey, actKey2);

      // Mã cài đặt khác nhau sẽ sinh mã kích hoạt khác nhau
      const installCodeOther = 'VDM-1122-3344';
      final actKeyOther = DeviceLicenseManager.generateActivationKey(installCodeOther);
      expect(actKey != actKeyOther, true);
    });

    test('verifyActivationKey xác thực chính xác mã kích hoạt', () {
      const installCode = 'VDM-8F4A-92BC';
      final validKey = DeviceLicenseManager.generateActivationKey(installCode);

      // Mã đúng
      expect(DeviceLicenseManager.verifyActivationKey(installCode, validKey), true);
      // Mã đúng nhưng người dùng gõ không có dấu gạch ngang
      expect(DeviceLicenseManager.verifyActivationKey(installCode, validKey.replaceAll('-', '')), true);
      // Mã sai
      expect(DeviceLicenseManager.verifyActivationKey(installCode, '0000-0000'), false);
      expect(DeviceLicenseManager.verifyActivationKey(installCode, '12345678'), false);
    });
  });
}
