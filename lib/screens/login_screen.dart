import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_profile.dart';
import '../services/user_session_tracker.dart';
import '../services/device_license_manager.dart';
import 'map_screen.dart';

class LoginScreen extends StatefulWidget {
  final bool isEditing;
  const LoginScreen({super.key, this.isEditing = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _fullNameController = TextEditingController();
  final _companyController = TextEditingController();
  final _unitController = TextEditingController();
  final _activationCodeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String _installCode = '';
  bool _isActivated = false;
  bool _isLoading = false;
  DateTime? _lastBackPressTime;

  @override
  void initState() {
    super.initState();
    _loadExistingProfile();
    _loadLicenseInfo();
  }

  Future<void> _loadLicenseInfo() async {
    final code = await DeviceLicenseManager.getInstallationCode();
    final activated = await DeviceLicenseManager.isDeviceActivated();
    if (mounted) {
      setState(() {
        _installCode = code;
        _isActivated = activated;
      });
    }
  }

  Future<void> _loadExistingProfile() async {
    final profile = await UserProfile.load();
    if (mounted) {
      setState(() {
        _fullNameController.text = profile.fullName;
        _companyController.text = profile.company;
        _unitController.text = profile.unit;
      });
    }
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _companyController.dispose();
    _unitController.dispose();
    _activationCodeController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final name = _fullNameController.text.trim();
    final company = _companyController.text.trim();
    final unit = _unitController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập Họ và Tên cán bộ!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Bắt buộc phải có mã kích hoạt nếu máy chưa được kích hoạt
    if (!_isActivated) {
      final enteredKey = _activationCodeController.text.trim();
      if (enteredKey.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng nhập Mã kích hoạt để đăng nhập vào ứng dụng!'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final isValid = DeviceLicenseManager.verifyActivationKey(_installCode, enteredKey);
      if (!isValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mã kích hoạt không chính xác cho thiết bị này! Vui lòng liên hệ Quản lý.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      // Kích hoạt máy thành công
      await DeviceLicenseManager.activateDevice(enteredKey);
      _isActivated = true;
    }

    setState(() => _isLoading = true);
    final profile = UserProfile(
      fullName: name,
      company: company,
      unit: unit,
    );
    await profile.save();
    await UserSessionTracker().updateUserProfile(profile);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (widget.isEditing) {
      Navigator.pop(context, true);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MapScreen(isGuestReadOnly: false)),
      );
    }
  }

  void _handleSkip() {
    if (widget.isEditing) {
      Navigator.pop(context, false);
    } else {
      // Chức năng Dùng ngay: CHỈ ĐƯỢC XEM GIAO DIỆN BÊN TRONG, KHÔNG THAO TÁC ĐƯỢC GÌ
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MapScreen(isGuestReadOnly: true)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.of(context).padding;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (widget.isEditing) {
          Navigator.pop(context, false);
          return;
        }

        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          ScaffoldMessenger.of(context).removeCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Nhấn nút quay lại lần nữa để thoát ứng dụng',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.black87,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              margin: EdgeInsets.only(
                bottom: safePadding.bottom + 16,
                left: 32,
                right: 32,
              ),
            ),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF1B5E20),
                Color(0xFF2E7D32),
                Color(0xFF0F3812),
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24, 20, 24, safePadding.bottom + 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo & App Name
                      Container(
                        width: 86,
                        height: 86,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/icon_app.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.forest,
                            size: 50,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'VDM GIS',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'HỆ THỐNG GIS LÂM NGHIỆP THỰC ĐỊA',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.white70,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 22),

                      // Card Form
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.verified_user_rounded,
                                    color: Color(0xFF1B5E20), size: 22),
                                const SizedBox(width: 8),
                                Text(
                                  widget.isEditing
                                      ? 'CẬP NHẬT THÔNG TIN'
                                      : 'ĐĂNG NHẬP THIẾT BỊ',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1B5E20),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Mỗi máy có 1 Mã cài đặt riêng. Bắt buộc có mã kích hoạt để sử dụng đầy đủ tính năng.',
                              style: TextStyle(fontSize: 11.5, color: Colors.black54),
                            ),
                            const Divider(height: 20),

                            // KHỐI HIỂN THỊ MÃ CÀI ĐẶT RIÊNG CỦA MÁY NÀY
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8F5E9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF2E7D32), width: 1.2),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.qr_code_2_rounded, color: Color(0xFF1B5E20), size: 28),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'MÃ CÀI ĐẶT THIẾT BỊ',
                                          style: TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.bold),
                                        ),
                                        const SizedBox(height: 2),
                                        SelectableText(
                                          _installCode.isNotEmpty ? _installCode : 'Đang lấy mã...',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF1B5E20),
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.copy_rounded, color: Color(0xFF2E7D32), size: 20),
                                    tooltip: 'Sao chép mã cài đặt',
                                    onPressed: () {
                                      if (_installCode.isNotEmpty) {
                                        Clipboard.setData(ClipboardData(text: _installCode));
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Đã sao chép Mã cài đặt! Hãy gửi cho Quản lý để nhận mã kích hoạt.'),
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),

                            // TRẠNG THÁI BẢN QUYỀN
                            if (_isActivated) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.green.shade300),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.check_circle_rounded, color: Color(0xFF2E7D32), size: 18),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Thiết bị đã được kích hoạt bản quyền hợp lệ',
                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                            ] else ...[
                              // Ô NHẬP MÃ KÍCH HOẠT (BẮT BUỘC KHI CHƯA KÍCH HOẠT)
                              const Text(
                                'Mã kích hoạt đăng nhập *',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: Colors.redAccent,
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _activationCodeController,
                                keyboardType: TextInputType.text,
                                textCapitalization: TextCapitalization.characters,
                                decoration: InputDecoration(
                                  hintText: 'Nhập mã kích hoạt (Ví dụ: 6829-4153)',
                                  hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                  prefixIcon: const Icon(Icons.vpn_key_rounded, color: Colors.redAccent),
                                  filled: true,
                                  fillColor: Colors.red.shade50.withValues(alpha: 0.3),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(color: Colors.redAccent),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(color: Colors.red.shade300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],

                            // 1. Họ và Tên
                            const Text(
                              'Họ và Tên cán bộ *',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _fullNameController,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                hintText: 'Ví dụ: Lê Văn Minh',
                                hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                prefixIcon: const Icon(Icons.person, color: Color(0xFF2E7D32)),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 1.5),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),

                            // 2. Công ty
                            const Text(
                              'Công ty',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _companyController,
                              decoration: InputDecoration(
                                hintText: 'Ví dụ: Công ty Lâm Nghiệp Kratie',
                                hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                prefixIcon: const Icon(Icons.business, color: Color(0xFF2E7D32)),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 1.5),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),

                            // 3. Đơn vị
                            const Text(
                              'Đơn vị',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _unitController,
                              decoration: InputDecoration(
                                hintText: 'Ví dụ: Đội Tuần Tra Rừng Số 2',
                                hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                prefixIcon: const Icon(Icons.badge, color: Color(0xFF2E7D32)),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 1.5),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Nút Đăng nhập
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1B5E20),
                                  foregroundColor: Colors.white,
                                  elevation: 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: _isLoading ? null : _handleSave,
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                      )
                                    : Text(
                                        widget.isEditing
                                            ? 'LƯU THAY ĐỔI'
                                            : (_isActivated ? 'BẮT ĐẦU VÀO BẢN ĐỒ' : 'KÍCH HOẠT & VÀO BẢN ĐỒ'),
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                              ),
                            ),

                            // NÚT DÙNG NGAY (CHỈ ĐƯỢC XEM GIAO DIỆN, KHÔNG THAO TÁC ĐƯỢC GÌ)
                            if (!widget.isEditing) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.grey.shade800,
                                    side: BorderSide(color: Colors.grey.shade400),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Icon(Icons.visibility_outlined, size: 16),
                                  label: const Text(
                                    'Dùng ngay (Chế độ xem thử - Chỉ xem)',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                  onPressed: _handleSkip,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Center(
                                child: Text(
                                  'Chế độ xem thử chỉ cho phép xem bản đồ, bị khóa toàn bộ chức năng thao tác',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Thông tin phiên bản & nhà phát triển
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.verified, size: 15, color: Colors.amberAccent),
                                SizedBox(width: 6),
                                Text(
                                  'Phiên bản: 1.0.4 • Bảo vệ bản quyền máy',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Phát triển bởi: Lê Văn Minh',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
