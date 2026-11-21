import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import '../services/user_session_tracker.dart';
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
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadExistingProfile();
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
    super.dispose();
  }

  Future<void> _handleSave() async {
    final name = _fullNameController.text.trim();
    final company = _companyController.text.trim();
    final unit = _unitController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập Họ và Tên!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
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
        MaterialPageRoute(builder: (_) => const MapScreen()),
      );
    }
  }

  void _handleSkip() {
    if (widget.isEditing) {
      Navigator.pop(context, false);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MapScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.of(context).padding;

    return Scaffold(
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
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Padding(
                          padding: const EdgeInsets.all(6.0),
                          child: Image.asset(
                            'assets/icon_app.png',
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.forest,
                              size: 46,
                              color: Color(0xFF1B5E20),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'VDM GIS',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'HỆ THỐNG GIS LÂM NGHIỆP THỰC ĐỊA',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.white70,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Card Form
                    Container(
                      padding: const EdgeInsets.all(22),
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
                              const Icon(Icons.person_pin,
                                  color: Color(0xFF1B5E20), size: 24),
                              const SizedBox(width: 8),
                              Text(
                                widget.isEditing
                                    ? 'CẬP NHẬT THÔNG TIN'
                                    : 'ĐĂNG NHẬP THỰC ĐỊA',
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
                            'Thông tin cán bộ được gắn vào dữ liệu tuần tra & đo đạc bản đồ.',
                            style: TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          const Divider(height: 24),

                          // 1. Họ và Tên
                          const Text(
                            'Họ và Tên *',
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
                              hintStyle: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.person,
                                  color: Color(0xFF2E7D32)),
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
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
                                borderSide: const BorderSide(
                                    color: Color(0xFF2E7D32), width: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

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
                              hintStyle: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.business,
                                  color: Color(0xFF2E7D32)),
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
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
                                borderSide: const BorderSide(
                                    color: Color(0xFF2E7D32), width: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

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
                              hintStyle: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.badge,
                                  color: Color(0xFF2E7D32)),
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
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
                                borderSide: const BorderSide(
                                    color: Color(0xFF2E7D32), width: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Nút Lưu / Đăng nhập
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
                                      child: CircularProgressIndicator(
                                          color: Colors.white, strokeWidth: 2),
                                    )
                                  : Text(
                                      widget.isEditing
                                          ? 'LƯU THAY ĐỔI'
                                          : 'BẮT ĐẦU VÀO BẢN ĐỒ',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                            ),
                          ),

                          if (!widget.isEditing) ...[
                            const SizedBox(height: 10),
                            Center(
                              child: TextButton(
                                onPressed: _handleSkip,
                                child: Text(
                                  'Bỏ qua (Dùng ngay)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
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
                                'Phiên bản: 1.0.1',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.person, size: 14, color: Colors.white70),
                              SizedBox(width: 6),
                              Text(
                                'Nhà phát triển: Lê Minh',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.email, size: 14, color: Colors.white70),
                              SizedBox(width: 6),
                              Text(
                                'Liên hệ: leminh.vdm@gmail.com',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                            ],
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
    );
  }
}
