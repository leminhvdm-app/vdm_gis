import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/user_profile.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'services/user_session_tracker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const VdmGisApp());
}

class VdmGisApp extends StatelessWidget {
  const VdmGisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DNKC GIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          primary: const Color(0xFF2E7D32),
          secondary: const Color(0xFF388E3C),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1B5E20),
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      home: const AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  bool _isLoading = true;
  bool _hasUser = false;

  @override
  void initState() {
    super.initState();
    _checkUser();
  }

  Future<void> _checkUser() async {
    final profile = await UserProfile.load();
    await UserSessionTracker().initAndStartSession(userProfile: profile);
    if (mounted) {
      setState(() {
        _hasUser = !profile.isEmpty;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF1B5E20),
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    return _hasUser ? const MapScreen() : const LoginScreen();
  }
}

typedef ForestGisApp = VdmGisApp;

