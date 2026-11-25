import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

import '../models/raster_overlay.dart';
import '../constants/app_version.dart';
import '../models/forest_plot.dart';
import '../models/forest_poi.dart';
import '../models/patrol_track.dart';
import '../utils/gis_calculator.dart';
import '../utils/vn2000_converter.dart';
import '../utils/kml_parser.dart';
import '../utils/gpx_parser.dart';
import '../utils/gpkg_parser.dart';
import '../utils/tiff_parser.dart';
import '../utils/vn2000_table_parser.dart';
import '../services/firebase_sync_service.dart';
import '../services/user_session_tracker.dart';
import '../models/user_profile.dart';
import 'login_screen.dart';
import 'pdf_viewer_screen.dart';
import '../services/device_license_manager.dart';
import '../services/persistent_offline_tile_provider.dart';
import '../services/app_update_service.dart';

enum MapBaseLayer { googleHybrid, googleSatellite, esriSatellite, esriClarity, openTopo, openStreetMap }
enum AppInteractionMode { normal, measureDistance, measureArea, digitizePlot, editVertex, gpsSurveyWalk }

class MapScreen extends StatefulWidget {
  final bool isGuestReadOnly;
  const MapScreen({super.key, this.isGuestReadOnly = false});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();

  bool get _isReadOnly => widget.isGuestReadOnly || !DeviceLicenseManager.isActivatedSync || DeviceLicenseManager.isBlockedSync;

  bool _checkCanPerformAction(String actionName) {
    if (_isReadOnly) {
      if (DeviceLicenseManager.isBlockedSync) {
        _showDeviceBlockedDialog();
      } else {
        _showGuestRestrictedDialog(actionName);
      }
      return false;
    }
    return true;
  }

  void _showDeviceBlockedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.block, color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'THIẾT BỊ ĐÃ BỊ KHÓA',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: const Text(
          'Mã cài đặt của thiết bị này đã bị Quản trị viên khóa quyền sử dụng trên hệ thống Quản lý.\n\nMọi thao tác nhập và sửa dữ liệu đã bị chặn.',
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            },
            child: const Text('Về màn hình đăng nhập', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showGuestRestrictedDialog(String actionName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.lock_person_rounded, color: Colors.orange, size: 26),
            SizedBox(width: 10),
            Text('Chế độ Xem thử', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tính năng "$actionName" bị khóa trong Chế độ Xem thử.',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              'Bạn chỉ được phép xem giao diện và bản đồ. Vui lòng kích hoạt bản quyền ứng dụng bằng Mã cài đặt của máy để sử dụng đầy đủ các tính năng thực địa.',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B5E20),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.vpn_key_rounded, size: 16),
            label: const Text('Kích hoạt ngay'),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  // Dữ liệu GIS
  final List<ForestPlot> _plots = [];
  ForestPlot? _selectedPlot;
  ForestPlot? _editingPlot;
  int? _selectedVertexIndex;
  bool _isAddingVertexMode = false; // Chế độ thêm đỉnh ranh giới khi nắn sửa

  // Nổi bật Lô khi tìm kiếm (hỗ trợ đa vùng và làm tối các vùng khác)
  final Set<String> _highlightedPlotIds = {};
  String? _highlightedPlotName;
  int _highlightedRegionCount = 0;
  double _highlightedTotalArea = 0.0;

  // Cấu hình Tô màu & Nhãn nâng cao (Tử số / Mẫu số / Hệ suy LDLR)
  String _labelNumeratorField = 'TEN_LO'; // Dòng trên: TEN_LO, DIEN_TIC, CHU_V, X, Y, LDLR, CTY, NTRUONG
  String _labelDenominatorField = 'DIEN_TIC'; // Dòng dưới: DIEN_TIC, TEN_LO, CHU_V, X, Y, LDLR, LOAI_CAY
  double _labelFontSize = 10.0;
  double _labelMinZoom = 15.0; // Hiện nhãn từ mức Zoom 15 trở lên (tránh crash bộ nhớ khi zoom xa)
  Color _labelColor = const Color(0xFFFFEB3B); // Màu chữ vàng sáng
  bool _labelHasHalo = true; // Chữ đậm viền tương phản dễ đọc
  Color _labelHaloColor = const Color(0xFF000000); // Màu viền chữ (Mặc định: Đen)
  Color? _polygonBorderColor; // Màu viền các lớp đa giác (null = Mặc định theo màu Lô)
  double _polygonBorderWidth = 1.0; // Độ dày viền đa giác (mặc định 1.0 mảnh, sắc nét)
  double _gpsWalkCurrentDist = 0.0; // Khoảng cách GPS đã đi từ điểm gần nhất
  String _ldlrStandard = 'TT33'; // Hệ suy LDLR: TT33 hoặc TT16
  List<String> _datasetGroupOrder = []; // Thứ tự các lớp dữ liệu (Lớp 1 nằm đầu tiên trên cùng, lớp 2 nằm dưới...)
  bool _highPerformanceMode = true; // Chế độ Siêu Mượt khi nhiều Lô (Tối ưu GPU EvenOdd, nén đỉnh & nhãn thông minh)
  LatLng _lastRenderedCenter = const LatLng(11.3420, 107.0390);

  static const List<Map<String, dynamic>> basicBorderColors = [
    {'name': 'Theo màu Lô', 'color': null},
    {'name': 'Đen', 'color': Color(0xFF000000)},
    {'name': 'Trắng', 'color': Color(0xFFFFFFFF)},
    {'name': 'Đỏ', 'color': Color(0xFFD50000)},
    {'name': 'Vàng', 'color': Color(0xFFFFD600)},
    {'name': 'Cam', 'color': Color(0xFFFF6D00)},
    {'name': 'Xanh lá', 'color': Color(0xFF1B5E20)},
    {'name': 'Xanh dương', 'color': Color(0xFF2962FF)},
    {'name': 'Tím', 'color': Color(0xFF6200EA)},
  ];

  static const List<Color> appRichPalette = [
    // 1. Vàng & Chanh (Yellow & Lime)
    Color(0xFFFFEB3B), Color(0xFFFDD835), Color(0xFFFBC02D), Color(0xFFF57F17),
    Color(0xFFCDDC39), Color(0xFFAEEA00), Color(0xFF76FF03), Color(0xFF64DD17),
    // 2. Cam & Hổ phách (Orange & Amber)
    Color(0xFFFF9800), Color(0xFFFB8C00), Color(0xFFF57C00), Color(0xFFEF6C00),
    Color(0xFFFF6F00), Color(0xFFFF8F00), Color(0xFFFFA000), Color(0xFFFFB300),
    // 3. Đỏ & Hồng (Red & Pink)
    Color(0xFFF44336), Color(0xFFE53935), Color(0xFFD32F2F), Color(0xFFC62828),
    Color(0xFFB71C1C), Color(0xFFFF1744), Color(0xFFD50000), Color(0xFFFF5252),
    Color(0xFFE91E63), Color(0xFFD81B60), Color(0xFFC2185B), Color(0xFFAD1457),
    // 4. Tím & Tím than (Purple & Violet)
    Color(0xFF9C27B0), Color(0xFF8E24AA), Color(0xFF7B1FA2), Color(0xFF6A1B9A),
    Color(0xFF4A148C), Color(0xFF673AB7), Color(0xFF512DA8), Color(0xFF4527A0),
    // 5. Xanh dương & Cyan (Blue, Cyan, Teal)
    Color(0xFF00BCD4), Color(0xFF00ACC1), Color(0xFF0097A7), Color(0xFF00838F),
    Color(0xFF006064), Color(0xFF00E5FF), Color(0xFF00B0FF), Color(0xFF0091EA),
    Color(0xFF2196F3), Color(0xFF1976D2), Color(0xFF1565C0), Color(0xFF0D47A1),
    Color(0xFF3F51B5), Color(0xFF303F9F), Color(0xFF283593), Color(0xFF1A237E),
    // 6. Xanh lá & Xanh rừng (Green & Forest)
    Color(0xFF4CAF50), Color(0xFF43A047), Color(0xFF388E3C), Color(0xFF2E7D32),
    Color(0xFF1B5E20), Color(0xFF004D40), Color(0xFF00796B), Color(0xFF009688),
    // 7. Đen, Xám, Trắng, Nâu (Neutrals)
    Color(0xFFFFFFFF), Color(0xFFE0E0E0), Color(0xFF9E9E9E), Color(0xFF757575),
    Color(0xFF424242), Color(0xFF212121), Color(0xFF000000), Color(0xFF795548),
    Color(0xFF5D4037), Color(0xFF3E2723), Color(0xFF37474F), Color(0xFF263238),
  ];

  List<Shadow>? _cachedHaloShadows;
  Color? _cachedHaloColor;
  bool? _cachedHasHalo;

  List<Shadow>? _buildLabelShadows(bool hasHalo, Color haloColor) {
    if (!hasHalo) return null;
    if (_cachedHaloShadows != null && _cachedHaloColor == haloColor && _cachedHasHalo == hasHalo) {
      return _cachedHaloShadows;
    }
    _cachedHaloColor = haloColor;
    _cachedHasHalo = hasHalo;
    _cachedHaloShadows = [
      Shadow(color: haloColor, blurRadius: 2, offset: const Offset(-1, -1)),
      Shadow(color: haloColor, blurRadius: 2, offset: const Offset(1, -1)),
      Shadow(color: haloColor, blurRadius: 2, offset: const Offset(-1, 1)),
      Shadow(color: haloColor, blurRadius: 2, offset: const Offset(1, 1)),
    ];
    return _cachedHaloShadows;
  }

  List<String> _getCurrentGroupOrder() {
    final Set<String> existingGroups = {
      ..._plots.map((p) => p.groupName),
      ..._poiList.map((p) => p.groupName),
      ..._rasterOverlays.map((o) => o.groupName),
    };

    final List<String> ordered = _datasetGroupOrder.where((g) => existingGroups.contains(g)).toList();
    for (var g in existingGroups) {
      if (!ordered.contains(g)) {
        ordered.add(g);
      }
    }
    _datasetGroupOrder = ordered;
    return ordered;
  }

  // Tối ưu hiệu năng GPS và Bản đồ tránh đứng/văng app
  DateTime? _lastGpsCheckTime;
  LatLng? _lastGpsCheckPos;
  double _currentMapZoom = 15.2;
  double _currentMapRotation = 0.0;
  bool _isNorthLocked = true; // Chế độ Mở/Khóa hướng Bắc (Mặc định khóa hướng Bắc 0°)
  bool _isFollowLocation = false; // Chế độ Bật/Tắt tự động di chuyển bản đồ theo GPS
  bool _isPickingPoiLocation = false; // Đang trong chế độ chạm chọn vị trí đánh dấu điểm nóng trên bản đồ
  final Set<String> _alertedPoiIds = {}; // Tránh báo lặp lại liên tục cho cùng một điểm nóng

  // Quản lý hiển thị và nhóm dữ liệu đã nhập (Bật/tắt từng nhóm riêng biệt, tránh nằm chồng lên nhau)
  final Set<String> _hiddenGroups = {};
  final List<RasterOverlay> _rasterOverlays = [];
  List<ForestPlot>? _cachedVisiblePlots;

  void _invalidatePlotCache() {
    _cachedVisiblePlots = null;
  }

  List<ForestPlot> get _visiblePlots {
    if (_cachedVisiblePlots != null) return _cachedVisiblePlots!;
    final list = _plots.where((p) => !_hiddenGroups.contains(p.groupName)).toList();
    final order = _getCurrentGroupOrder();
    if (order.isNotEmpty) {
      list.sort((a, b) {
        final indexA = order.indexOf(a.groupName);
        final indexB = order.indexOf(b.groupName);
        final rankA = indexA == -1 ? 999 : indexA;
        final rankB = indexB == -1 ? 999 : indexB;
        // rankB.compareTo(rankA): Lớp thứ tự lớn vẽ trước, Lớp #1 (index 0) vẽ sau cùng để hiển thị trên cùng
        return rankB.compareTo(rankA);
      });
    }
    _cachedVisiblePlots = list;
    return list;
  }

  /// Tối ưu hóa hiệu năng render (Spatial Viewport Culling):
  /// Khi dữ liệu lớn (> 50 lô), chỉ render các Lô nằm trong khung nhìn màn hình hiện tại + viền đệm,
  /// giúp điện thoại mượt mà 60 FPS, không bị giật lag hay đơ máy.
  List<ForestPlot> get _renderedPlots {
    final all = _visiblePlots;
    if (all.length <= 50) return all;
    try {
      final bounds = _mapController.camera.visibleBounds;
      final latMargin = (bounds.north - bounds.south) * 0.45;
      final lngMargin = (bounds.east - bounds.west) * 0.45;
      final expandedBounds = LatLngBounds(
        LatLng(bounds.south - latMargin, bounds.west - lngMargin),
        LatLng(bounds.north + latMargin, bounds.east + lngMargin),
      );
      return all
          .where((p) => p.isVisibleIn(
                expandedBounds.south,
                expandedBounds.north,
                expandedBounds.west,
                expandedBounds.east,
              ))
          .toList();
    } catch (_) {
      return all;
    }
  }

  List<ForestPoi> get _visiblePois =>
      _poiList.where((p) => !_hiddenGroups.contains(p.groupName)).toList();

  // Lớp POI vi phạm và Vết tuần tra
  final List<ForestPoi> _poiList = [];
  PatrolTrack? _activePatrol;
  final List<PatrolTrack> _completedPatrols = [];
  StreamSubscription<Position>? _positionStreamSub;

  // Vị trí GPS thật
  Position? _rawPosition;
  LatLng? _currentGpsPosition;
  ForestPlot? _plotUnderGps;
  bool _isLiveGpsActive = false;
  bool _isHudExpanded = true;
  bool _isLocatingGps = false;

  // Cấu hình Lớp bản đồ (Layer Manager)
  MapBaseLayer _baseLayer = MapBaseLayer.googleHybrid;
  double _plotOpacity = 0.45;
  bool _showPlotPolygons = true;
  bool _showPlotLabels = true;
  bool _showPatrolTracks = true;
  bool _showPois = true;

  // Chế độ tương tác & Số hóa
  AppInteractionMode _mode = AppInteractionMode.normal;
  final List<LatLng> _digitizingPoints = [];
  String _searchQuery = '';

  // Hồ sơ cán bộ đăng nhập
  UserProfile _userProfile = UserProfile();

  // Đồng hồ thực tế & Nhiệt độ thời gian thực
  final ValueNotifier<DateTime> _clockNotifier = ValueNotifier(DateTime.now());
  final StreamController<void> _tileResetController = StreamController<void>.broadcast();
  Timer? _clockTimer;
  Timer? _licenseCheckTimer;
  String _currentTemperature = '--';
  DateTime? _lastWeatherFetchTime;
  LatLng? _lastWeatherFetchPos;
  bool _isFetchingWeather = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserProfile();
    // Tự động tải lại tất cả các lớp dữ liệu đã nạp trước đó từ bộ nhớ máy
    _loadPersistentData();

    // Cập nhật đồng hồ hiển thị theo thời gian thực mỗi giây (dùng ValueNotifier để tránh rebuild toàn bộ Map)
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _clockNotifier.value = DateTime.now();
    });

    // Nạp cấu hình Firebase và tự động đẩy các mục hàng đợi ngoại tuyến khi có mạng
    FirebaseSyncService().loadConfig().then((_) {
      FirebaseSyncService().processOfflineQueue();
    });

    // Bắt đầu định vị GPS thật của thiết bị ngay khi mở app
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestAndGetRealLocation();
      _checkRemoteBlockStatusPeriodically();
      AppUpdateService.checkForUpdate(context, silent: true);
    });

    // Định kỳ kiểm tra trạng thái khóa từ xa từ Quản lý (mỗi 5 giây khi có mạng)
    _licenseCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkRemoteBlockStatusPeriodically();
    });
  }

  Future<void> _clearAppCacheAndOptimize() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        for (var file in tempDir.listSync()) {
          try {
            file.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
      _alertedPoiIds.clear();
      _invalidatePlotCache();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      setState(() {});
      _showToast('Đã dọn sạch bộ nhớ đệm (Cache) & giải phóng RAM!');
    } catch (e) {
      _showToast('Đã dọn dẹp và tối ưu bộ nhớ app');
    }
  }

  Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vdm_gis_persistent_layers.json');
  }

  Future<void> _savePersistentData() async {
    try {
      _invalidatePlotCache();
      final file = await _getStorageFile();
      final data = {
        'plots': _plots.map((p) => p.toMap()).toList(),
        'pois': _poiList.map((p) => p.toMap()).toList(),
        'hiddenGroups': _hiddenGroups.toList(),
        'rasterOverlays': _rasterOverlays.map((o) => o.toMap()).toList(),
        'groupOrder': _datasetGroupOrder,
        'labelColor': _labelColor.toARGB32(),
        'labelHasHalo': _labelHasHalo,
        'labelHaloColor': _labelHaloColor.toARGB32(),
        'polygonBorderColor': _polygonBorderColor?.toARGB32(),
        'polygonBorderWidth': _polygonBorderWidth,
        'labelFontSize': _labelFontSize,
        'labelMinZoom': _labelMinZoom,
        'labelNumeratorField': _labelNumeratorField,
        'labelDenominatorField': _labelDenominatorField,
        'plotOpacity': _plotOpacity,
        'highPerformanceMode': _highPerformanceMode,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Lỗi lưu dữ liệu: $e');
    }
  }

  Future<void> _loadPersistentData() async {
    try {
      final file = await _getStorageFile();
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;

      final data = jsonDecode(content) as Map<String, dynamic>;
      final rawPlots = data['plots'] as List<dynamic>? ?? [];
      final rawPois = data['pois'] as List<dynamic>? ?? [];
      final rawHidden = data['hiddenGroups'] as List<dynamic>? ?? [];
      final rawOrder = data['groupOrder'] as List<dynamic>? ?? [];

      final loadedPlots = rawPlots.map((e) => ForestPlot.fromMap(e as Map<String, dynamic>)).toList();
      final loadedPois = rawPois.map((e) => ForestPoi.fromMap(e as Map<String, dynamic>)).toList();

      if (mounted) {
        setState(() {
          _plots.clear();
          _plots.addAll(loadedPlots);
          _poiList.clear();
          _poiList.addAll(loadedPois);
          _hiddenGroups.clear();
          _hiddenGroups.addAll(rawHidden.map((e) => e.toString()));
          _datasetGroupOrder.clear();
          _datasetGroupOrder.addAll(rawOrder.map((e) => e.toString()));

          if (data['labelColor'] != null) {
            _labelColor = Color(data['labelColor'] as int);
          }
          if (data['labelHasHalo'] != null) {
            _labelHasHalo = data['labelHasHalo'] as bool;
          }
          if (data['labelHaloColor'] != null) {
            _labelHaloColor = Color(data['labelHaloColor'] as int);
          }
          if (data['polygonBorderColor'] != null) {
            _polygonBorderColor = Color(data['polygonBorderColor'] as int);
          }
          if (data['polygonBorderWidth'] != null) {
            _polygonBorderWidth = (data['polygonBorderWidth'] as num).toDouble();
          }
          if (data['labelFontSize'] != null) {
            _labelFontSize = (data['labelFontSize'] as num).toDouble();
          }
          if (data['labelMinZoom'] != null) {
            _labelMinZoom = (data['labelMinZoom'] as num).toDouble();
          }
          if (data['labelNumeratorField'] != null) {
            _labelNumeratorField = data['labelNumeratorField'] as String;
          }
          if (data['labelDenominatorField'] != null) {
            _labelDenominatorField = data['labelDenominatorField'] as String;
          }
          if (data['plotOpacity'] != null) {
            _plotOpacity = (data['plotOpacity'] as num).toDouble();
          }
          if (data['highPerformanceMode'] != null) {
            _highPerformanceMode = data['highPerformanceMode'] as bool;
          }
          _invalidatePlotCache();
        });

        if (_plots.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _mapController.move(_plots.first.center, 15.0);
          });
        }
      }
    } catch (e) {
      debugPrint('Lỗi đọc dữ liệu đã lưu: $e');
    }
  }

  Future<void> _loadUserProfile() async {
    final p = await UserProfile.load();
    if (mounted) {
      setState(() => _userProfile = p);
      UserSessionTracker().updateUserProfile(p);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      UserSessionTracker().resumeSession(_userProfile);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      UserSessionTracker().endSession();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UserSessionTracker().endSession();
    _clockTimer?.cancel();
    _licenseCheckTimer?.cancel();
    _clockNotifier.dispose();
    _tileResetController.close();
    _positionStreamSub?.cancel();
    super.dispose();
  }

  /// Định kỳ kiểm tra nếu thiết bị bị Quản trị viên khóa từ xa
  Future<void> _checkRemoteBlockStatusPeriodically() async {
    final isBlocked = await DeviceLicenseManager.checkRemoteBlockStatus();
    if (isBlocked && mounted) {
      _licenseCheckTimer?.cancel();
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.block, color: Colors.redAccent, size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'THIẾT BỊ ĐÃ BỊ KHÓA',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
          content: const Text(
            'Mã cài đặt của thiết bị này đã bị Quản trị viên khóa quyền sử dụng từ xa trên hệ thống Quản lý.\n\nỨng dụng sẽ tự động chuyển về màn hình đăng nhập.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
              child: const Text('Về màn hình đăng nhập', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  /// Cập nhật nhiệt độ theo thời gian thực từ Open-Meteo API
  Future<void> _fetchRealtimeTemperature(LatLng pos) async {
    final now = DateTime.now();
    // Cache: Chỉ cập nhật lại sau 15 phút hoặc khi di chuyển > 3km để tiết kiệm pin/4G
    if (_lastWeatherFetchTime != null &&
        now.difference(_lastWeatherFetchTime!).inMinutes < 15 &&
        _lastWeatherFetchPos != null &&
        GisCalculator.calculateDistanceInMeters(_lastWeatherFetchPos!, pos) < 3000.0) {
      return;
    }

    if (_isFetchingWeather) return;
    _isFetchingWeather = true;

    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${pos.latitude.toStringAsFixed(4)}&longitude=${pos.longitude.toStringAsFixed(4)}&current_weather=true',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['current_weather'] != null) {
          final temp = data['current_weather']['temperature'];
          if (temp != null && mounted) {
            setState(() {
              _currentTemperature = '${temp.toString()}°C';
              _lastWeatherFetchTime = now;
              _lastWeatherFetchPos = pos;
            });
          }
        }
      }
    } catch (_) {
      // Giữ nguyên nhiệt độ nếu ngoại tuyến
    } finally {
      _isFetchingWeather = false;
    }
  }

  int _tileCacheBuster = DateTime.now().millisecondsSinceEpoch;

  String get _tileUrl {
    switch (_baseLayer) {
      case MapBaseLayer.googleHybrid:
        return 'https://mt{s}.google.com/vt/lyrs=y&x={x}&y={y}&z={z}';
      case MapBaseLayer.googleSatellite:
        return 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}';
      case MapBaseLayer.esriSatellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case MapBaseLayer.esriClarity:
        return 'https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case MapBaseLayer.openTopo:
        return 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
      case MapBaseLayer.openStreetMap:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }
  }

  int get _maxNativeZoom {
    switch (_baseLayer) {
      case MapBaseLayer.openTopo:
        return 17;
      case MapBaseLayer.openStreetMap:
        return 19;
      case MapBaseLayer.googleHybrid:
      case MapBaseLayer.googleSatellite:
      case MapBaseLayer.esriSatellite:
      case MapBaseLayer.esriClarity:
      default:
        return 18;
    }
  }

  void _refreshSatelliteTiles() {
    _tileResetController.add(null);
    _showToast('Đang kết nối và tải lại các gạch bản đồ hiển thị...');
  }

  void _showDownloadOfflineMapDialog() {
    final camera = _mapController.camera;
    final bounds = camera.visibleBounds;
    final baseLayerName = _baseLayer.name;
    final urlTemplate = _tileUrl;

    int currentZ = camera.zoom.round();
    int minZ = 8; // Tải từ mức zoom nhỏ toàn cảnh để khi zoom xa không bao giờ bị màu trắng
    int maxZ = (currentZ + 1).clamp(14, 16);
    int totalTiles = PersistentOfflineTileProvider.countTilesForBounds(bounds, minZ, maxZ);

    showDialog(
      context: context,
      builder: (ctx) {
        bool isDownloading = false;
        double progress = 0.0;
        int currentDownloaded = 0;
        String statusText = 'Sẵn sàng tải...';
        StreamSubscription<double>? sub;

        return StatefulBuilder(
          builder: (dialogCtx, setDlgState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFAFAFA),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.download_for_offline_rounded, color: Color(0xFF1B5E20), size: 26),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'TẢI BẢN ĐỒ NGOẠI TUYẾN',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1B5E20)),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ứng dụng sẽ tải và lưu toàn bộ gạch bản đồ vệ tinh của khu vực đang xem vào bộ nhớ máy, đảm bảo khi đi vào rừng sâu không có 4G/WiFi vẫn hiển thị sắc nét.',
                    style: TextStyle(fontSize: 12.5, color: Colors.black87),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Khu vực:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                            Text('${bounds.south.toStringAsFixed(3)}, ${bounds.west.toStringAsFixed(3)}',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Mức phóng đại (Zoom):', style: TextStyle(fontSize: 12, color: Colors.black54)),
                            Text('$minZ -> $maxZ',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Số lượng gạch bản đồ:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                            Text('$totalTiles gạch (~${(totalTiles * 0.025).toStringAsFixed(1)} MB)',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      color: const Color(0xFF1B5E20),
                      backgroundColor: Colors.grey.shade300,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(statusText, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                        Text('${(progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                      ],
                    ),
                  ],
                ],
              ),
              actions: [
                if (!isDownloading)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('Đóng'),
                  ),
                if (!isDownloading)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B5E20),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Bắt đầu tải về máy'),
                    onPressed: () {
                      setDlgState(() {
                        isDownloading = true;
                        statusText = 'Đang tải gạch bản đồ...';
                      });

                      sub = PersistentOfflineTileProvider.downloadRegion(
                        bounds: bounds,
                        minZoom: minZ,
                        maxZoom: maxZ,
                        urlTemplate: urlTemplate,
                        baseLayerKey: baseLayerName,
                        onProgress: (d, t) {
                          currentDownloaded = d;
                          setDlgState(() {
                            progress = d / t;
                            statusText = 'Đang tải: $d / $t gạch';
                          });
                        },
                      ).listen(null);

                      sub?.onDone(() async {
                        setDlgState(() {
                          isDownloading = false;
                          statusText = 'Đã tải hoàn tất!';
                        });
                        // Tự động lưu khu vực này làm Bản đồ Ngoại tuyến Mặc định của máy
                        await PersistentOfflineTileProvider.saveDefaultRegion(
                          bounds: bounds,
                          name: 'Khu vực làm việc mặc định',
                        );
                        // Nạp thêm ngầm các mức zoom xa z=6..8 nếu cần
                        PersistentOfflineTileProvider.preloadOverviewTiles(
                          bounds: bounds,
                          urlTemplate: urlTemplate,
                          baseLayerKey: baseLayerName,
                          minZoom: 6,
                          maxZoom: 8,
                        );

                        if (dialogCtx.mounted) {
                          Navigator.pop(dialogCtx);
                        }
                        _showToast(
                            'Đã lưu khu vực này làm Bản đồ Ngoại tuyến Mặc định! Dù zoom to hay zoom nhỏ, khi mất mạng bản đồ vẫn hiển thị 100%.');
                      });
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------
  // ĐỊNH VỊ GPS THỰC TẾ 100% (KHÔNG DÙNG TỌA ĐỘ GIẢ)
  // -------------------------------------------------------------
  Future<void> _requestAndGetRealLocation() async {
    setState(() => _isLocatingGps = true);

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showToast('GPS đang tắt. Vui lòng bật Vị Trí (Location) trên điện thoại');
        setState(() => _isLocatingGps = false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showToast('Quyền GPS bị từ chối.');
          setState(() => _isLocatingGps = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showToast('Vui lòng vào Cài đặt cấp quyền Vị trí cho ứng dụng');
        setState(() => _isLocatingGps = false);
        return;
      }

      // Lấy tọa độ GPS phần cứng thực tế
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );

      _updatePosition(pos);
      _mapController.move(LatLng(pos.latitude, pos.longitude), 16.5);
      _showToast('Đã bắt được tín hiệu GPS vệ tinh (Sai số: ±${pos.accuracy.toStringAsFixed(1)}m)');
    } catch (e) {
      _showToast('Đang chờ khóa vệ tinh GPS ngoài trời...');
    } finally {
      if (mounted) setState(() => _isLocatingGps = false);
    }
  }

  void _toggleLiveGps() {
    if (_isLiveGpsActive) {
      _positionStreamSub?.cancel();
      setState(() => _isLiveGpsActive = false);
      _showToast('Đã dừng theo dõi GPS liên tục');
    } else {
      _startLiveGpsStream();
    }
  }

  void _startLiveGpsStream() async {
    setState(() => _isLiveGpsActive = true);
    _showToast('Đang theo dõi GPS liên tục ngoài thực địa...');

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2, // Cập nhật mỗi 2 mét
    );

    _positionStreamSub?.cancel();
    _positionStreamSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position pos) {
        _updatePosition(pos);
      },
      onError: (_) {
        setState(() => _isLiveGpsActive = false);
      },
    );
  }

  void _updatePosition(Position pos) {
    final latLng = LatLng(pos.latitude, pos.longitude);

    // Throttling: Kiểm tra va chạm Lô rừng cách nhau tối thiểu 1.5 giây hoặc di chuyển > 3m (tránh treo/văng máy)
    final now = DateTime.now();
    bool shouldCheckPlot = false;
    if (_lastGpsCheckTime == null || now.difference(_lastGpsCheckTime!).inMilliseconds > 1500) {
      shouldCheckPlot = true;
    } else if (_lastGpsCheckPos != null &&
        GisCalculator.calculateDistanceInMeters(_lastGpsCheckPos!, latLng) > 3.0) {
      shouldCheckPlot = true;
    }

    ForestPlot? currentPlot = _plotUnderGps;
    if (shouldCheckPlot) {
      _lastGpsCheckTime = now;
      _lastGpsCheckPos = latLng;

      currentPlot = null;
      for (var plot in _visiblePlots) {
        if (plot.containsPoint(latLng)) {
          currentPlot = plot;
          break;
        }
      }
    }

    if (_activePatrol != null && _activePatrol!.isActive) {
      if (_activePatrol!.points.isEmpty ||
          GisCalculator.calculateDistanceInMeters(_activePatrol!.points.last, latLng) > 2.0) {
        _activePatrol!.points.add(latLng);
      }
    }

    // Đo đạc tự động theo GPS (cầm ĐT đi khoảng 5m tự thêm 1 điểm)
    if (_mode == AppInteractionMode.gpsSurveyWalk) {
      if (_digitizingPoints.isEmpty) {
        _digitizingPoints.add(latLng);
        _gpsWalkCurrentDist = 0.0;
      } else {
        final dist = GisCalculator.calculateDistanceInMeters(_digitizingPoints.last, latLng);
        _gpsWalkCurrentDist = dist;
        if (dist >= 5.0) {
          _digitizingPoints.add(latLng);
          _gpsWalkCurrentDist = 0.0;
        }
      }
    }

    if (mounted) {
      setState(() {
        _rawPosition = pos;
        _currentGpsPosition = latLng;
        _plotUnderGps = currentPlot;
      });

      // Tự động cập nhật nhiệt độ thời gian thực tại vị trí GPS
      _fetchRealtimeTemperature(latLng);

      // Tự động di chuyển bản đồ theo tâm GPS nếu đang bật chế độ Follow
      if (_isFollowLocation) {
        _mapController.move(latLng, _mapController.camera.zoom);
        if (!_isNorthLocked && pos.heading > 0) {
          _mapController.rotate(pos.heading);
        }
      }

      // Kiểm tra chuông báo thức / nhắc nhở điểm nóng thực địa
      _checkPoiAlarms(pos);
    }
  }

  void _checkPoiAlarms(Position pos) {
    final now = DateTime.now();
    for (var poi in _visiblePois) {
      if (!poi.reminderEnabled) continue;
      if (_alertedPoiIds.contains(poi.id)) continue;

      bool shouldAlert = false;
      String reason = '';

      // 1. Kiểm tra giờ hẹn báo thức
      if (poi.reminderTime != null && now.isAfter(poi.reminderTime!)) {
        shouldAlert = true;
        reason = 'Đã đến giờ hẹn kiểm tra hiện trường!';
      }

      // 2. Kiểm tra cự ly tuần tra đến gần (<100m)
      if (!shouldAlert && poi.proximityAlert) {
        final dist = GisCalculator.calculateDistanceInMeters(
          LatLng(pos.latitude, pos.longitude),
          poi.position,
        );
        if (dist <= 100.0) {
          shouldAlert = true;
          reason = 'Bạn đang ở rất gần điểm nóng (${dist.toStringAsFixed(0)}m)!';
        }
      }

      if (shouldAlert) {
        _alertedPoiIds.add(poi.id);
        _showPoiAlarmDialog(poi, reason);
        break;
      }
    }
  }

  void _showPoiAlarmDialog(ForestPoi poi, String reason) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.redAccent, width: 2),
        ),
        title: const Row(
          children: [
            Icon(Icons.notifications_active, color: Colors.amber, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'BÁO THỨC ĐIỂM NÓNG!',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              poi.title,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('Loại: ${poi.typeName} | Mức độ: ${poi.severity}',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
              ),
              child: Text(
                reason,
                style: const TextStyle(color: Color(0xFFFF8A80), fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            if (poi.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Ghi chú: ${poi.description}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Bỏ qua', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _mapController.move(poi.position, 16.5);
              _showPoiDetailSheet(poi);
            },
            icon: const Icon(Icons.location_on, size: 16),
            label: const Text('Xem vị trí'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // MENU HỒ SƠ CÁN BỘ & QUẢN TRỊ DỮ LIỆU (GÓC TRÊN BÊN TRÁI)
  // -------------------------------------------------------------
  void _showUserProfileMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
            ? MediaQuery.of(ctx).viewPadding.bottom
            : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 56.0);
        final safeBottom = bottomInset + 54.0;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom),
          child: SafeArea(
            top: false,
            bottom: true,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Thẻ thông tin người dùng
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1B5E20).withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF2E7D32), Color(0xFF1B5E20)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _userProfile.initials,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: _userProfile.initials.length > 3
                              ? 13
                              : (_userProfile.initials.length == 3 ? 16 : 18),
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _userProfile.fullName.isNotEmpty
                                ? _userProfile.fullName
                                : 'Chưa cập nhật tên',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _userProfile.company.isNotEmpty
                                ? '🏢 ${_userProfile.company}'
                                : '🏢 Công ty: ---',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _userProfile.unit.isNotEmpty
                                ? '🏷️ ${_userProfile.unit}'
                                : '🏷️ Đơn vị: ---',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.white70),
                      tooltip: 'Sửa thông tin',
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final updated = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LoginScreen(isEditing: true),
                          ),
                        );
                        if (updated == true) {
                          _loadUserProfile();
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                'QUẢN TRỊ DỮ LIỆU BẢN ĐỒ',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),

              // MỤC 1: NẠP DỮ LIỆU BẢN ĐỒ
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  _showImportMenu();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A237E).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF1A237E).withValues(alpha: 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: const Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(0xFFE8EAF6),
                        radius: 20,
                        child: Icon(Icons.file_open, color: Color(0xFF1A237E), size: 22),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'NẠP DỮ LIỆU BẢN ĐỒ',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A237E),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'KML / KMZ, GeoJSON / JSON, GPKG, GPX, TIFF, PDF',
                              style: TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF1A237E)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // MỤC 2: QUẢN LÝ LỚP & NHÓM DỮ LIỆU
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  _showLayerManagerSheet();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B5E20).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF1B5E20).withValues(alpha: 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: const Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(0xFFE8F5E9),
                        radius: 20,
                        child: Icon(Icons.layers, color: Color(0xFF1B5E20), size: 22),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'QUẢN LÝ LỚP VÀ NHÓM DỮ LIỆU',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1B5E20),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Bật/tắt lớp, đổi màu, nhãn nâng cao, đồng bộ Firebase',
                              style: TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF1B5E20)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // MỤC 3: DỌN DẸP BỘ NHỚ ĐỆM (CACHE) & TỐI ƯU APP
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  _clearAppCacheAndOptimize();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00796B).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF00796B).withValues(alpha: 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: const Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(0xFFE0F2F1),
                        radius: 20,
                        child: Icon(Icons.cleaning_services, color: Color(0xFF00796B), size: 22),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'DỌN DẸP BỘ NHỚ ĐỆM (CACHE)',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00796B),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Xóa rác, giải phóng RAM, giúp app chạy nhẹ & mượt hơn',
                              style: TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF00796B)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // MỤC 4: KIỂM TRA BẢN CẬP NHẬT MỚI (TỰ ĐỘNG TẢI & CÀI ĐẶT)
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  AppUpdateService.checkForUpdate(context, silent: false);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B5E20).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF2E7D32).withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                  ),
                  child: const Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(0xFFE8F5E9),
                        radius: 20,
                        child: Icon(Icons.system_update_rounded, color: Color(0xFF1B5E20), size: 22),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'KIỂM TRA BẢN CẬP NHẬT MỚI',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1B5E20),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Kiểm tra phiên bản mới, tự động tải & cài đặt trực tiếp',
                              style: TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF1B5E20)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // Thông tin ứng dụng
              Center(
                child: Column(
                  children: [
                    Text(
                      AppVersion.display,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Nhà phát triển: Lê Minh',
                      style: TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Liên hệ: leminh.vdm@gmail.com',
                      style: TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  },
);
  }

  // -------------------------------------------------------------
  // CHỨC NĂNG NHẬP FILE: KML/KMZ, GEOJSON, GPKG, GPX, TIFF
  // -------------------------------------------------------------
  void _showImportMenu() {
    if (!_checkCanPerformAction('Nạp tệp bản đồ')) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
            ? MediaQuery.of(ctx).viewPadding.bottom
            : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 48.0);
        final safeBottom = bottomInset + 24.0;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'NẠP DỮ LIỆU BẢN ĐỒ',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Chọn định dạng file bạn muốn nạp lên bản đồ vệ tinh:',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),

                // 1. KML / KMZ
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(backgroundColor: Color(0xFFE8F5E9), child: Icon(Icons.public, color: Colors.green)),
                  title: const Text('Nạp KML / KMZ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: const Text('Google Earth, bản đồ ranh giới kiểm lâm'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileWithExtension(['kml', 'kmz']);
                  },
                ),
                const Divider(height: 1),

                // 2. GeoJSON / JSON
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(backgroundColor: Color(0xFFEDE7F6), child: Icon(Icons.data_object, color: Colors.purple)),
                  title: const Text('Nạp GeoJSON / JSON', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: const Text('Chuẩn dữ liệu không gian mở QGIS, ArcGIS'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileWithExtension(['geojson', 'json']);
                  },
                ),
                const Divider(height: 1),

                // 3. GPKG (GeoPackage)
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(backgroundColor: Color(0xFFE0F2F1), child: Icon(Icons.layers, color: Colors.teal)),
                  title: const Text('Nạp GPKG (GeoPackage)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: const Text('Cơ sở dữ liệu GIS chuẩn OGC QGIS'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileWithExtension(['gpkg']);
                  },
                ),
                const Divider(height: 1),

                // 4. GPX
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(backgroundColor: Color(0xFFFFF3E0), child: Icon(Icons.route, color: Colors.orange)),
                  title: const Text('Nạp GPX (GPS Exchange)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: const Text('Lộ trình, tọa độ ranh đo bằng máy GPS Garmin'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileWithExtension(['gpx']);
                  },
                ),
                const Divider(height: 1),

                // 5. TIFF / GeoTIFF
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(backgroundColor: Color(0xFFFBE9E7), child: Icon(Icons.image, color: Colors.deepOrange)),
                  title: const Text('Nạp TIFF / GeoTIFF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: const Text('Ảnh viễn thám, ảnh bay chụp Drone trực giao'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileWithExtension(['tif', 'tiff']);
                  },
                ),
                const Divider(height: 1),

                // 6. TẢI TỪ SERVER CLOUD (FIREBASE)
                ListTile(
                  dense: true,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE3F2FD),
                    child: Icon(Icons.cloud_download, color: Color(0xFF1976D2)),
                  ),
                  title: const Text(
                    'Tải từ Server Cloud (Firebase)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1976D2)),
                  ),
                  subtitle: const Text('Chọn file / nhóm dữ liệu đã đồng bộ từ server về máy'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Color(0xFF1976D2)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFirebaseCloudDownloadDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickFileWithExtension(List<String> extensions) async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;
        final extension = fileName.split('.').last.toLowerCase();

        // 1. FILE KML / KMZ (Hỗ trợ cả file nén KMZ và file KML)
        if (extension == 'kml' || extension == 'kmz') {
          final file = File(filePath);
          final parseResult = await KmlParser.parseFile(file, defaultGroupName: fileName);

          if (parseResult.plots.isNotEmpty || parseResult.pois.isNotEmpty) {
            setState(() {
              _plots.addAll(parseResult.plots);
              _poiList.addAll(parseResult.pois);
              _hiddenGroups.remove(fileName); // Mặc định hiển thị nhóm mới nạp
            });
            _savePersistentData();

            if (parseResult.plots.isNotEmpty) {
              _mapController.move(parseResult.plots.first.center, 15.0);
            } else if (parseResult.pois.isNotEmpty) {
              _mapController.move(parseResult.pois.first.position, 15.0);
            }

            _showToast('Đã nạp và vẽ thành công ${parseResult.plots.length} Lô và ${parseResult.pois.length} Mốc từ nhóm "$fileName" lên bản đồ!');
          } else {
            _showToast('Không tìm thấy dữ liệu Polygon hoặc Point hợp lệ trong file $fileName');
          }
          return;
        }

        // 2. FILE GEOJSON
        if (extension == 'geojson' || extension == 'json') {
          final file = File(filePath);
          final content = await file.readAsString();
          final data = jsonDecode(content);

          List<ForestPlot> newPlots = [];
          if (data['type'] == 'FeatureCollection' && data['features'] is List) {
            int idx = 1;
            for (var feature in data['features']) {
              newPlots.add(ForestPlot.fromGeoJsonFeature(feature, idx++).copyWith(groupName: fileName));
            }
          }

          if (newPlots.isNotEmpty) {
            setState(() {
              _plots.addAll(newPlots);
              _hiddenGroups.remove(fileName);
            });
            _savePersistentData();
            _mapController.move(newPlots.first.center, 15.0);
            _showToast('Đã nạp ${newPlots.length} Lô từ nhóm "$fileName" lên bản đồ!');
          } else {
            _showToast('Không tìm thấy Polygon trong file GeoJSON');
          }
          return;
        }

        // 3. FILE GPKG (GeoPackage)
        if (extension == 'gpkg') {
          final file = File(filePath);
          final parseResult = await GpkgParser.parseFile(file, defaultGroupName: fileName);

          if (parseResult.plots.isNotEmpty || parseResult.pois.isNotEmpty || parseResult.overlays.isNotEmpty) {
            setState(() {
              _plots.addAll(parseResult.plots);
              _poiList.addAll(parseResult.pois);
              _rasterOverlays.addAll(parseResult.overlays);
              _hiddenGroups.remove(fileName);
              _invalidatePlotCache();
            });
            _savePersistentData();

            if (parseResult.overlays.isNotEmpty) {
              _mapController.move(parseResult.overlays.first.center, 13.0);
            } else if (parseResult.plots.isNotEmpty) {
              _mapController.move(parseResult.plots.first.center, 15.0);
            } else if (parseResult.pois.isNotEmpty) {
              _mapController.move(parseResult.pois.first.position, 15.0);
            }

            final overlayText = parseResult.overlays.isNotEmpty ? ' kèm ${parseResult.overlays.length} Bản đồ ảnh nắn tọa độ' : '';
            _showToast('Đã nạp ${parseResult.plots.length} Lô, ${parseResult.pois.length} Mốc$overlayText từ GPKG "$fileName"!');
          } else {
            _showToast(parseResult.info.isNotEmpty
                ? parseResult.info
                : 'Không tìm thấy dữ liệu Polygon hoặc Point trong file GPKG.');
          }
          return;
        }

        // 4. FILE GPX (GPS Exchange)
        if (extension == 'gpx') {
          final file = File(filePath);
          final parseResult = await GpxParser.parseFile(file, defaultGroupName: fileName);

          if (parseResult.plots.isNotEmpty || parseResult.pois.isNotEmpty) {
            setState(() {
              _plots.addAll(parseResult.plots);
              _poiList.addAll(parseResult.pois);
              _hiddenGroups.remove(fileName);
            });
            _savePersistentData();

            if (parseResult.plots.isNotEmpty) {
              _mapController.move(parseResult.plots.first.center, 15.0);
            } else if (parseResult.pois.isNotEmpty) {
              _mapController.move(parseResult.pois.first.position, 15.0);
            }

            _showToast('Đã nạp ${parseResult.plots.length} Lô/Tuyến và ${parseResult.pois.length} Điểm GPX từ "$fileName"!');
          } else {
            _showToast('Không tìm thấy dữ liệu Waypoint hoặc Track hợp lệ trong file GPX.');
          }
          return;
        }

        // 5. FILE TIFF / GeoTIFF
        if (extension == 'tif' || extension == 'tiff') {
          final file = File(filePath);
          final parseResult = await TiffParser.parseFile(file, defaultGroupName: fileName);

          if (parseResult.plot != null) {
            setState(() {
              _plots.add(parseResult.plot!);
              _hiddenGroups.remove(fileName);
            });
            _savePersistentData();
            _mapController.move(parseResult.plot!.center, 15.0);
            _showToast('Đã nạp và định vị khung ảnh TIFF "$fileName" lên bản đồ!');
          } else {
            _showToast(parseResult.info);
          }
          return;
        }

        // 6. FILE PDF (hỗ trợ dự phòng nếu chọn từ nguồn khác)
        if (extension == 'pdf') {
          _handlePdfImport(filePath, fileName);
          return;
        }
      }
    } catch (e) {
      _showToast('Lỗi đọc file: $e');
    }
  }

  // Xử lý nạp file PDF: Quét tọa độ VN-2000 hoặc mở trình xem
  Future<void> _handlePdfImport(String filePath, String fileName) async {
    _showToast('Đang quét bảng tọa độ VN-2000 trong file PDF...');

    // Mặc định kinh tuyến trục Đắk Nông (108.5°) nếu tên file có chữ DNK / Dak Nong
    double detectedMeridian = 108.5;
    if (fileName.toLowerCase().contains('dong nai')) {
      detectedMeridian = 107.75;
    } else if (fileName.toLowerCase().contains('lam dong')) {
      detectedMeridian = 107.75;
    }

    final points = await Vn2000TableParser.extractCoordinatesFromPdf(filePath, centralMeridian: detectedMeridian);

    if (points.length >= 3) {
      // Tìm thấy bảng tọa độ trong PDF!
      final newPlot = Vn2000TableParser.createPlotFromVn2000Points(
        name: fileName.replaceAll('.pdf', ''),
        points: points,
        tieuKhu: 'Bản đồ PDF',
        groupName: fileName,
      );

      setState(() {
        _plots.add(newPlot);
        _hiddenGroups.remove(fileName);
      });
      _savePersistentData();

      _mapController.move(newPlot.center, 15.0);
      _showToast('Đã trích xuất và vẽ thành công ${points.length} đỉnh từ file PDF lên bản đồ!');
      _showPlotDetailSheet(newPlot);
    } else {
      // PDF dạng ảnh scan, hỏi người dùng xem bản PDF hoặc nhập tay tọa độ
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            content: const Text(
              'File PDF này là bản vẽ scan hình ảnh (không chứa văn bản số hóa để tự trích xuất).\n\n'
              'Bạn có thể:\n'
              '1. Mở xem trực tiếp bản vẽ PDF.\n'
              '2. Hoặc dùng chức năng "Dán bảng tọa độ VN-2000" để nhập các đỉnh (1..34) vẽ lên bản đồ vệ tinh.',
              style: TextStyle(fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openPasteVn2000Dialog();
                },
                child: const Text('Dán tọa độ VN-2000'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1B5E20), foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (c) => PdfViewerScreen(filePath: filePath, fileName: fileName),
                    ),
                  );
                },
                child: const Text('Xem bản vẽ PDF'),
              ),
            ],
          );
        },
      );
    }
  }

  // HỘP THOẠI DÁN BẢNG TỌA ĐỘ VN-2000 (TỪ BẢN ĐỒ PDF / SỔ ĐỎ)
  void _openPasteVn2000Dialog() {
    if (!_checkCanPerformAction('Dán tọa độ VN-2000')) return;
    final textCtrl = TextEditingController(
      // Mẫu sẵn 34 đỉnh từ ảnh bản đồ của người dùng nếu trống
      text: '''1 627761 1477076
2 630570 1477076
3 630570 1477434
4 630776 1477411
5 631581 1477305
6 631581 1475323
7 635581 1475323
8 635581 1471282
9 638302 1471324
10 638302 1470552
11 638822 1470552
12 638813 1468305
13 638790 1464959
14 638068 1464959
15 636669 1467550
16 635872 1468305
17 635855 1466872
18 636673 1466852
19 636673 1464971
20 634621 1464971
21 632591 1464971
22 632603 1467320
23 631331 1467320
24 631255 1468324
25 628426 1468323
26 629581 1469323
27 629581 1470323
28 631581 1470323
29 631581 1472323
30 630176 1472323
31 630176 1473368
32 628591 1473282
33 628567 1474085
34 627761 1474068''',
    );

    String selectedProvince = 'Đắk Nông';
    final nameCtrl = TextEditingController(text: 'Bản Đồ Tổng ĐNK');

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final meridian = Vn2000TableParser.provinceMeridians[selectedProvince] ?? 108.5;

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.pin_drop, color: Color(0xFF2E7D32)),
                SizedBox(width: 8),
                Text('Dán Tọa Độ VN-2000', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Chọn Tỉnh / Kinh tuyến trục VN-2000:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: selectedProvince,
                    decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                    items: Vn2000TableParser.provinceMeridians.keys.map((p) {
                      final m = Vn2000TableParser.provinceMeridians[p];
                      return DropdownMenuItem(value: p, child: Text('$p (KTT $m°)'));
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setDlgState(() => selectedProvince = val);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Tên khu đất / Lô rừng', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  const Text('Dán danh sách đỉnh (Đỉnh | X | Y):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextFormField(
                    controller: textCtrl,
                    maxLines: 8,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Dán bảng tọa độ tại đây...\n1 627761 1477076\n2 630570 1477076...',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Vẽ lên Bản Đồ'),
                onPressed: () {
                  final rawText = textCtrl.text.trim();
                  if (rawText.isEmpty) {
                    _showToast('Vui lòng dán danh sách tọa độ');
                    return;
                  }

                  final points = Vn2000TableParser.parseCoordinatesFromText(rawText, centralMeridian: meridian);
                  if (points.length < 3) {
                    _showToast('Cần tối thiểu 3 đỉnh tọa độ VN-2000 để tạo đa giác');
                    return;
                  }

                  final groupTitle = 'Tọa độ VN-2000 ($selectedProvince)';
                  final newPlot = Vn2000TableParser.createPlotFromVn2000Points(
                    name: nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : 'Khu đất VN-2000',
                    points: points,
                    tieuKhu: selectedProvince,
                    color: const Color(0xFF8E24AA), // Màu tím nổi bật
                    groupName: groupTitle,
                  );

                  setState(() {
                    _plots.add(newPlot);
                    _hiddenGroups.remove(groupTitle);
                  });

                  Navigator.pop(ctx);
                  _mapController.move(newPlot.center, 15.0);
                  _showToast('Đã chuyển đổi ${points.length} đỉnh VN-2000 và VẼ THÀNH CÔNG lên bản đồ vệ tinh!');
                  _showPlotDetailSheet(newPlot);
                },
              ),
            ],
          );
        });
      },
    );
  }

  // -------------------------------------------------------------
  // TÔ MÀU & ĐỔI MÀU THEO VÙNG, NHÓM, HOẶC TỪNG LÔ (FULL MÀU SẮC)
  // -------------------------------------------------------------
  void _openFullColorPickerDialog({
    required String title,
    required Color currentColor,
    required ValueChanged<Color> onColorSelected,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        double currentHue = HSVColor.fromColor(currentColor).hue;
        const double currentSat = 0.85;
        const double currentVal = 0.9;
        Color pickedColor = currentColor;

        final fullPalette = [
          // Greens
          const Color(0xFF1B5E20), const Color(0xFF2E7D32), const Color(0xFF388E3C), const Color(0xFF43A047),
          const Color(0xFF4CAF50), const Color(0xFF66BB6A), const Color(0xFF81C784), const Color(0xFFA5D6A7),
          // Teals & Cyans
          const Color(0xFF004D40), const Color(0xFF00796B), const Color(0xFF009688), const Color(0xFF26A69A),
          const Color(0xFF006064), const Color(0xFF00838F), const Color(0xFF00ACC1), const Color(0xFF00BCD4),
          // Yellow & Lime
          const Color(0xFF827717), const Color(0xFF9E9D24), const Color(0xFFCDDC39), const Color(0xFF7CB342),
          const Color(0xFFF57F17), const Color(0xFFFBC02D), const Color(0xFFFDD835), const Color(0xFFFFEB3B),
          // Orange & Amber
          const Color(0xFFFF6F00), const Color(0xFFFF8F00), const Color(0xFFFFA000), const Color(0xFFFFB300),
          const Color(0xFFE65100), const Color(0xFFEF6C00), const Color(0xFFF57C00), const Color(0xFFFF9800),
          // Red & Pink
          const Color(0xFFB71C1C), const Color(0xFFC62828), const Color(0xFFE53935), const Color(0xFFF44336),
          const Color(0xFF880E4F), const Color(0xFFAD1457), const Color(0xFFC2185B), const Color(0xFFE91E63),
          // Purple & Deep Purple
          const Color(0xFF4A148C), const Color(0xFF6A1B9A), const Color(0xFF7B1FA2), const Color(0xFF9C27B0),
          const Color(0xFF311B92), const Color(0xFF4527A0), const Color(0xFF512DA8), const Color(0xFF673AB7),
          // Blue & Indigo
          const Color(0xFF1A237E), const Color(0xFF283593), const Color(0xFF303F9F), const Color(0xFF3F51B5),
          const Color(0xFF0D47A1), const Color(0xFF1565C0), const Color(0xFF1976D2), const Color(0xFF2196F3),
          // Browns & Neutrals
          const Color(0xFF3E2723), const Color(0xFF4E342E), const Color(0xFF5D4037), const Color(0xFF795548),
          const Color(0xFF212121), const Color(0xFF424242), const Color(0xFF757575), const Color(0xFF9E9E9E),
        ];

        return StatefulBuilder(builder: (ctx, setDlgState) {
          return AlertDialog(
            title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hộp xem trước màu đang chọn
                    Container(
                      height: 44,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: pickedColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.black26, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Mã màu: #${pickedColor.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
                        style: TextStyle(
                          color: pickedColor.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Thanh trượt quang phổ màu (Full 360° Hue)
                    const Text('Dải quang phổ màu tùy chỉnh (Full 360°):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 4),
                    Container(
                      height: 14,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        gradient: const LinearGradient(
                          colors: [
                            Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red,
                          ],
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                      ),
                      child: Slider(
                        value: currentHue,
                        min: 0,
                        max: 360,
                        onChanged: (val) {
                          setDlgState(() {
                            currentHue = val;
                            pickedColor = HSVColor.fromAHSV(1.0, currentHue, currentSat, currentVal).toColor();
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Bảng màu chuẩn đầy đủ
                    const Text('Bảng màu lâm nghiệp & GIS đa dạng:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: fullPalette.map((color) {
                        final isSel = pickedColor.toARGB32() == color.toARGB32();
                        return GestureDetector(
                          onTap: () {
                            setDlgState(() {
                              pickedColor = color;
                              currentHue = HSVColor.fromColor(color).hue;
                            });
                          },
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSel ? Colors.black : Colors.white,
                                width: isSel ? 3 : 1.5,
                              ),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
                            ),
                            child: isSel
                                ? Icon(Icons.check, size: 18, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(ctx);
                  onColorSelected(pickedColor);
                },
                child: const Text('Áp dụng màu này'),
              ),
            ],
          );
        });
      },
    );
  }

  void _openColorPickerForPlot(ForestPlot plot) {
    _openFullColorPickerDialog(
      title: 'Đổi màu Lô: ${plot.lo}',
      currentColor: plot.color,
      onColorSelected: (newColor) {
        setState(() => plot.color = newColor);
        _savePersistentData();
        _showToast('Đã đổi màu cho ${plot.lo}');
      },
    );
  }

  void _openColorPickerForDataset(String groupName, [VoidCallback? onDone]) {
    final firstPlot = _plots.firstWhere((p) => p.groupName == groupName, orElse: () => _plots.first);
    _openFullColorPickerDialog(
      title: 'Đổi màu nhóm dữ liệu: $groupName',
      currentColor: firstPlot.color,
      onColorSelected: (newColor) {
        setState(() {
          for (var p in _plots) {
            if (p.groupName == groupName) {
              p.color = newColor;
            }
          }
          _invalidatePlotCache();
        });
        _savePersistentData();
        onDone?.call();
        _showToast('Đã đổi màu toàn bộ các Lô thuộc nhóm "$groupName"');
      },
    );
  }

  void _openColorPickerForGroup(String trangThai) {
    final firstPlot = _plots.firstWhere((p) => p.trangThaiRung == trangThai, orElse: () => _plots.first);
    _openFullColorPickerDialog(
      title: 'Đổi màu trạng thái: $trangThai',
      currentColor: firstPlot.color,
      onColorSelected: (newColor) {
        setState(() {
          for (var p in _plots) {
            if (p.trangThaiRung == trangThai) {
              p.color = newColor;
            }
          }
        });
        _savePersistentData();
        _showToast('Đã đổi màu toàn bộ các Lô thuộc nhóm "$trangThai"');
      },
    );
  }

  /// Bảng nắn chỉnh tọa độ trực tiếp cho Lớp phủ Bản đồ ảnh (GeoPackage Raster Tiles)
  void _showRasterOverlayCalibrationDialog(RasterOverlay overlay, [VoidCallback? onDone]) {
    double stepMeters = 20.0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (calibCtx) => StatefulBuilder(
        builder: (context, setCalibState) {
          final dyMeters = (overlay.offsetLat * 111000).round();
          final dxMeters = (overlay.offsetLng * 111000 * 0.97).round();

          void applyShift(double deltaLatMeters, double deltaLngMeters) {
            final dLat = deltaLatMeters / 111000.0;
            final dLng = deltaLngMeters / (111000.0 * 0.97);
            setState(() {
              overlay.offsetLat += dLat;
              overlay.offsetLng += dLng;
            });
            setCalibState(() {});
            onDone?.call();
            _savePersistentData();
          }

          return Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.straighten, color: Color(0xFF2E7D32)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Nắn tọa độ: ${overlay.name}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(calibCtx),
                      ),
                    ],
                  ),
                  const Divider(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Text(
                          'Bắc/Nam: ${dyMeters >= 0 ? "+$dyMeters" : dyMeters} m',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: dyMeters != 0 ? const Color(0xFF2E7D32) : Colors.black87,
                          ),
                        ),
                        Text(
                          'Đông/Tây: ${dxMeters >= 0 ? "+$dxMeters" : dxMeters} m',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: dxMeters != 0 ? const Color(0xFF1E88E5) : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Bước dịch: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ...[5.0, 20.0, 50.0, 100.0, 500.0].map((step) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: ChoiceChip(
                              label: Text('${step.toInt()}m', style: const TextStyle(fontSize: 11)),
                              selected: stepMeters == step,
                              selectedColor: const Color(0xFF2E7D32).withValues(alpha: 0.2),
                              onSelected: (_) => setCalibState(() => stepMeters = step),
                            ),
                          )),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.arrow_drop_up, color: Color(0xFF2E7D32)),
                        onPressed: () => applyShift(stepMeters, 0),
                        tooltip: 'Dịch lên phía Bắc',
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.arrow_left, color: Color(0xFF1E88E5)),
                        onPressed: () => applyShift(0, -stepMeters),
                        tooltip: 'Dịch sang phía Tây',
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.arrow_right, color: Color(0xFF1E88E5)),
                        onPressed: () => applyShift(0, stepMeters),
                        tooltip: 'Dịch sang phía Đông',
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF2E7D32)),
                        onPressed: () => applyShift(-stepMeters, 0),
                        tooltip: 'Dịch xuống phía Nam',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.my_location, size: 16),
                        label: const Text('🎯 Khớp chuẩn KMZ Kratie (+497m)', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2E7D32),
                          side: const BorderSide(color: Color(0xFF2E7D32)),
                        ),
                        onPressed: () {
                          setState(() {
                            overlay.offsetLat = 0.004481;
                            overlay.offsetLng = 0.0;
                          });
                          setCalibState(() {});
                          onDone?.call();
                          _savePersistentData();
                          _showToast('Đã nắn khớp chuẩn xác 100% với file KMZ Kratie!');
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('↺ Đặt lại gốc (0m)', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          setState(() {
                            overlay.offsetLat = 0.0;
                            overlay.offsetLng = 0.0;
                          });
                          setCalibState(() {});
                          onDone?.call();
                          _savePersistentData();
                          _showToast('Đã khôi phục về tọa độ gốc');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------
  // SỐ HÓA & NẮN SỬA ĐỈNH LÔ
  // -------------------------------------------------------------
  void _addPointToDigitizing(LatLng point) {
    setState(() => _digitizingPoints.add(point));
  }

  void _captureGpsForDigitizing() {
    if (_currentGpsPosition == null) {
      _showToast('Chưa có vị trí GPS để ghim đỉnh');
      return;
    }
    _addPointToDigitizing(_currentGpsPosition!);
    _showToast('Đã ghim đỉnh ${_digitizingPoints.length} tại GPS thực tế');
  }

  void _openSavePlotDialog() {
    if (_digitizingPoints.length < 3) {
      _showToast('Cần tối thiểu 3 đỉnh để tạo thành Lô rừng');
      return;
    }

    final double areaHa = GisCalculator.calculateAreaInHectares(_digitizingPoints);
    final double perimeterM = GisCalculator.calculateTotalDistanceInMeters(_digitizingPoints, isClosed: true);
    final formKey = GlobalKey<FormState>();
    final tkCtrl = TextEditingController(text: 'TK 142');
    final kCtrl = TextEditingController(text: 'Khoảnh 2');
    final loCtrl = TextEditingController(text: 'Lô mới');
    final chuRungCtrl = TextEditingController(text: 'Ban QLRPH');
    final loaiCayCtrl = TextEditingController(text: 'Keo lai');
    String selectedTrangThai = 'Rừng trồng sản xuất';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.add_location_alt, color: Color(0xFF2E7D32)),
              SizedBox(width: 8),
              Text('Lưu Lô Rừng Mới', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Diện tích đo đạc:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              Text('${areaHa.toStringAsFixed(2)} ha (${(areaHa * 10000).toStringAsFixed(0)} m²)',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1B5E20), fontSize: 14)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Chu vi khép kín:', style: TextStyle(color: Colors.black87, fontSize: 12)),
                              Text('${perimeterM.toStringAsFixed(1)} m',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87, fontSize: 13)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Số đỉnh tọa độ:', style: TextStyle(color: Colors.black87, fontSize: 12)),
                              Text('${_digitizingPoints.length} điểm',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blueAccent, fontSize: 13)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Danh sách bảng tọa độ đỉnh
                    Theme(
                      data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        dense: true,
                        tilePadding: EdgeInsets.zero,
                        title: Text('Xem bảng tọa độ ${_digitizingPoints.length} đỉnh (VN-2000)',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                        children: [
                          Container(
                            constraints: const BoxConstraints(maxHeight: 160),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: _digitizingPoints.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (c, i) {
                                final p = _digitizingPoints[i];
                                final vn = Vn2000Converter.toVN2000(p);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Đỉnh #${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      Text('X: ${vn['x']?.toStringAsFixed(1) ?? ''} | Y: ${vn['y']?.toStringAsFixed(1) ?? ''}',
                                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: tkCtrl,
                            decoration: const InputDecoration(labelText: 'Tiểu khu', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: kCtrl,
                            decoration: const InputDecoration(labelText: 'Khoảnh', border: OutlineInputBorder()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: loCtrl,
                      decoration: const InputDecoration(labelText: 'Tên Lô (Ví dụ: Lô 5c)', border: OutlineInputBorder()),
                      validator: (v) => v == null || v.isEmpty ? 'Vui lòng nhập tên Lô' : null,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedTrangThai,
                      decoration: const InputDecoration(labelText: 'Trạng thái rừng', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'Rừng tự nhiên giàu', child: Text('Rừng tự nhiên giàu')),
                        DropdownMenuItem(value: 'Rừng trồng sản xuất', child: Text('Rừng trồng sản xuất')),
                        DropdownMenuItem(value: 'Rừng trồng cao su', child: Text('Rừng trồng cao su')),
                        DropdownMenuItem(value: 'Đất trống có cây tái sinh', child: Text('Đất trống tái sinh')),
                        DropdownMenuItem(value: 'Rừng phòng hộ đầu nguồn', child: Text('Rừng phòng hộ')),
                      ],
                      onChanged: (v) => selectedTrangThai = v ?? selectedTrangThai,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: chuRungCtrl,
                      decoration: const InputDecoration(labelText: 'Chủ rừng', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: loaiCayCtrl,
                      decoration: const InputDecoration(labelText: 'Loài cây chính', border: OutlineInputBorder()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white),
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  final newPlot = ForestPlot(
                    id: 'LO_${DateTime.now().millisecondsSinceEpoch}',
                    tieuKhu: tkCtrl.text.trim(),
                    khoanh: kCtrl.text.trim(),
                    lo: loCtrl.text.trim(),
                    dienTich: double.parse(areaHa.toStringAsFixed(2)),
                    chuRung: chuRungCtrl.text.trim(),
                    trangThaiRung: selectedTrangThai,
                    loaiCay: loaiCayCtrl.text.trim(),
                    boundary: List.from(_digitizingPoints),
                    color: selectedTrangThai.contains('tự nhiên') ? const Color(0xFF1B5E20) : const Color(0xFF43A047),
                    groupName: 'Số hóa thực địa',
                  );

                  setState(() {
                    _plots.add(newPlot);
                    _digitizingPoints.clear();
                    _selectedVertexIndex = null;
                    _mode = AppInteractionMode.normal;
                  });
                  _invalidatePlotCache();
                  _savePersistentData();

                  Navigator.pop(ctx);
                  _showToast('Đã lưu thành công ${newPlot.fullName} (${areaHa.toStringAsFixed(2)} ha)!');
                }
              },
              child: const Text('Lưu vào bản đồ'),
            ),
          ],
        );
      },
    );
  }

  void _startEditingPlot(ForestPlot plot) {
    if (!_checkCanPerformAction('Nắn sửa đỉnh Lô')) return;
    setState(() {
      _editingPlot = plot;
      _mode = AppInteractionMode.editVertex;
      _selectedVertexIndex = null;
      _isAddingVertexMode = false;
    });
    _showToast('Chạm vào (+) giữa 2 điểm hoặc chạm đỉnh để nắn sửa');
  }

  void _saveEditedPlot() {
    if (_editingPlot == null) return;
    final newArea = GisCalculator.calculateAreaInHectares(_editingPlot!.boundary);
    final plotName = _editingPlot!.fullName;
    setState(() {
      _editingPlot!.dienTich = double.parse(newArea.toStringAsFixed(2));
      _mode = AppInteractionMode.normal;
      _editingPlot = null;
      _selectedVertexIndex = null;
      _isAddingVertexMode = false;
    });
    _savePersistentData();
    _showToast('Đã lưu ranh giới Lô $plotName (${newArea.toStringAsFixed(2)} ha)');
  }

  void _insertVertexAtNearestEdge(LatLng point) {
    if (_editingPlot == null || _editingPlot!.boundary.isEmpty) return;
    final b = _editingPlot!.boundary;
    if (b.length < 2) {
      setState(() {
        b.add(point);
        _selectedVertexIndex = b.length - 1;
      });
      return;
    }

    int bestIndex = 0;
    double minDistance = double.infinity;

    for (int i = 0; i < b.length; i++) {
      final p1 = b[i];
      final p2 = b[(i + 1) % b.length];
      final mid = LatLng((p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);
      final dist = GisCalculator.calculateDistanceInMeters(mid, point);
      if (dist < minDistance) {
        minDistance = dist;
        bestIndex = i + 1;
      }
    }

    setState(() {
      b.insert(bestIndex, point);
      _selectedVertexIndex = bestIndex;
    });
    _showToast('Đã chèn thêm đỉnh mới số ${bestIndex + 1}');
  }

  // -------------------------------------------------------------
  // TUẦN TRA RỪNG & POI
  // -------------------------------------------------------------
  void _togglePatrol() {
    if (_activePatrol == null) {
      final track = PatrolTrack(
        id: 'PTR_${DateTime.now().millisecondsSinceEpoch}',
        officerName: 'Cán bộ tuần tra',
        startTime: DateTime.now(),
      );
      if (_currentGpsPosition != null) {
        track.points.add(_currentGpsPosition!);
      }
      setState(() => _activePatrol = track);
      _startLiveGpsStream();
      _showToast('Đã bắt đầu ghi vết lộ trình tuần tra');
    } else {
      _activePatrol!.endTime = DateTime.now();
      _activePatrol!.isActive = false;
      setState(() {
        _completedPatrols.add(_activePatrol!);
        _activePatrol = null;
      });
      _showToast('Đã kết thúc và lưu chuyến tuần tra');
    }
  }

  void _openAddPoiDialog({LatLng? position}) {
    if (!_checkCanPerformAction('Đánh dấu Điểm nóng/Vi phạm')) return;
    LatLng curPos = position ?? _currentGpsPosition ?? const LatLng(11.3420, 107.0390);
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    PoiType selectedType = PoiType.fire;
    String selectedSeverity = 'Cảnh báo';
    bool reminderEnabled = false;
    DateTime reminderTime = DateTime.now().add(const Duration(hours: 1));
    bool proximityAlert = true;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final vn2000 = Vn2000Converter.toVN2000(curPos);
          final latDms = Vn2000Converter.toDMS(curPos.latitude, true);
          final lngDms = Vn2000Converter.toDMS(curPos.longitude, false);

          return AlertDialog(
            backgroundColor: const Color(0xFFFAFAFA),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.add_alert, color: Colors.red),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Đánh Dấu Điểm Nóng / Vi Phạm',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. THẺ TỌA ĐỘ VÀ CHỌN ĐỊA ĐIỂM
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.location_on, color: Color(0xFF69F0AE), size: 16),
                                SizedBox(width: 4),
                                Text('TỌA ĐỘ VỊ TRÍ ĐÁNH DẤU',
                                    style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                            InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                setState(() => _isPickingPoiLocation = true);
                                _showToast('Chạm vào điểm trên bản đồ để chọn tọa độ');
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.amber[900],
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.touch_app, color: Colors.white, size: 12),
                                    SizedBox(width: 3),
                                    Text('Chọn trên bản đồ',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('WGS-84: X: ${curPos.latitude.toStringAsFixed(6)}; Y: ${curPos.longitude.toStringAsFixed(6)}',
                            style: const TextStyle(
                                color: Color(0xFF69F0AE),
                                fontSize: 10,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold)),
                        Text('DMS: $latDms, $lngDms',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontFamily: 'monospace')),
                        Text('VN-2000: X: ${vn2000['x']!.toStringAsFixed(1)} m; Y: ${vn2000['y']!.toStringAsFixed(1)} m',
                            style: const TextStyle(
                                color: Color(0xFF81D4FA),
                                fontSize: 10,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold)),
                        if (_currentGpsPosition != null &&
                            (curPos.latitude != _currentGpsPosition!.latitude ||
                                curPos.longitude != _currentGpsPosition!.longitude)) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: InkWell(
                              onTap: () => setDlgState(() => curPos = _currentGpsPosition!),
                              child: const Text('📍 Đặt về GPS hiện tại',
                                  style: TextStyle(
                                      color: Color(0xFF69F0AE),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      decoration: TextDecoration.underline)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 2. LOẠI SỰ VỤ
                  DropdownButtonFormField<PoiType>(
                    value: selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Loại sự vụ',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    items: const [
                      DropdownMenuItem(value: PoiType.fire, child: Text('🔥 Điểm cháy rừng')),
                      DropdownMenuItem(value: PoiType.logging, child: Text('🪓 Khai thác gỗ lậu')),
                      DropdownMenuItem(value: PoiType.encroach, child: Text('🏕️ Lấn chiếm đất rừng')),
                      DropdownMenuItem(value: PoiType.landslide, child: Text('⚠️ Sạt lở đất đá')),
                      DropdownMenuItem(value: PoiType.wildlife, child: Text('🐾 Bẫy săn / Động vật')),
                      DropdownMenuItem(value: PoiType.boundaryMark, child: Text('📍 Cột mốc ranh giới')),
                    ],
                    onChanged: (v) => setDlgState(() => selectedType = v ?? selectedType),
                  ),
                  const SizedBox(height: 10),

                  // 3. TIÊU ĐỀ NGẮN
                  TextFormField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tiêu đề ngắn',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 4. MÔ TẢ CHI TIẾT
                  TextFormField(
                    controller: descCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Mô tả chi tiết',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 5. MỨC ĐỘ
                  DropdownButtonFormField<String>(
                    value: selectedSeverity,
                    decoration: const InputDecoration(
                      labelText: 'Mức độ',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Bình thường', child: Text('Bình thường')),
                      DropdownMenuItem(value: 'Cảnh báo', child: Text('Cảnh báo')),
                      DropdownMenuItem(value: 'Khẩn cấp', child: Text('Khẩn cấp (Nguy hiểm)')),
                    ],
                    onChanged: (v) => setDlgState(() => selectedSeverity = v ?? selectedSeverity),
                  ),
                  const SizedBox(height: 12),

                  // 6. CHẾ ĐỘ NHẮC NHỞ (BÁO THỨC)
                  Container(
                    decoration: BoxDecoration(
                      color: reminderEnabled ? const Color(0xFFFFF8E1) : Colors.grey[100],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: reminderEnabled ? Colors.amber[800]! : Colors.grey[300]!,
                        width: 1.2,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.alarm,
                                  color: reminderEnabled ? Colors.amber[900] : Colors.grey[600],
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                const Text('Chế độ nhắc nhở (Báo thức)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              ],
                            ),
                            Switch(
                              value: reminderEnabled,
                              activeColor: Colors.amber[900],
                              onChanged: (val) => setDlgState(() => reminderEnabled = val),
                            ),
                          ],
                        ),
                        if (reminderEnabled) ...[
                          const Divider(height: 10),
                          Text(
                            '⏰ Báo lúc: ${reminderTime.hour.toString().padLeft(2, '0')}:${reminderTime.minute.toString().padLeft(2, '0')} - Ngày ${reminderTime.day}/${reminderTime.month}/${reminderTime.year}',
                            style: TextStyle(
                              color: Colors.amber[900],
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: [
                              ActionChip(
                                label: const Text('+15p', style: TextStyle(fontSize: 11)),
                                onPressed: () => setDlgState(() {
                                  reminderTime = DateTime.now().add(const Duration(minutes: 15));
                                }),
                              ),
                              ActionChip(
                                label: const Text('+1 giờ', style: TextStyle(fontSize: 11)),
                                onPressed: () => setDlgState(() {
                                  reminderTime = DateTime.now().add(const Duration(hours: 1));
                                }),
                              ),
                              ActionChip(
                                label: const Text('+1 ngày', style: TextStyle(fontSize: 11)),
                                onPressed: () => setDlgState(() {
                                  reminderTime = DateTime.now().add(const Duration(days: 1));
                                }),
                              ),
                              ActionChip(
                                label: const Text('Chọn giờ...', style: TextStyle(fontSize: 11)),
                                onPressed: () async {
                                  final d = await showDatePicker(
                                    context: ctx,
                                    initialDate: reminderTime,
                                    firstDate: DateTime.now(),
                                    lastDate: DateTime.now().add(const Duration(days: 365)),
                                  );
                                  if (d != null && ctx.mounted) {
                                    final t = await showTimePicker(
                                      context: ctx,
                                      initialTime: TimeOfDay.fromDateTime(reminderTime),
                                    );
                                    if (t != null) {
                                      setDlgState(() {
                                        reminderTime = DateTime(d.year, d.month, d.day, t.hour, t.minute);
                                      });
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('Cảnh báo khi tuần tra đến gần (<100m)',
                                style: TextStyle(fontSize: 12)),
                            value: proximityAlert,
                            activeColor: Colors.amber[900],
                            onChanged: (v) => setDlgState(() => proximityAlert = v ?? true),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[700],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  if (titleCtrl.text.trim().isEmpty) {
                    titleCtrl.text = '${selectedType.name.toUpperCase()} tại ${_plotUnderGps?.fullName ?? 'Hiện trường'}';
                  }
                  final poi = ForestPoi(
                    id: 'POI_${DateTime.now().millisecondsSinceEpoch}',
                    title: titleCtrl.text.trim(),
                    description: descCtrl.text.trim(),
                    position: curPos,
                    type: selectedType,
                    timestamp: DateTime.now(),
                    tieuKhu: _plotUnderGps?.tieuKhu ?? '',
                    khoanh: _plotUnderGps?.khoanh ?? '',
                    lo: _plotUnderGps?.lo ?? '',
                    severity: selectedSeverity,
                    groupName: _plotUnderGps?.groupName ?? 'Điểm ghi nhận thực địa',
                    reminderTime: reminderEnabled ? reminderTime : null,
                    reminderEnabled: reminderEnabled,
                    proximityAlert: proximityAlert,
                  );

                  setState(() => _poiList.add(poi));
                  _savePersistentData(); // Lưu bền vững vào bộ nhớ thiết bị
                  Navigator.pop(ctx);
                  _showToast('Đã lưu điểm "${poi.title}" trên bản đồ');
                  _mapController.move(curPos, 16.0);
                },
                child: const Text('Lưu điểm', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _shareData() async {
    if (_plots.isEmpty && _poiList.isEmpty) {
      _showToast('Chưa có dữ liệu Lô rừng hoặc Điểm mốc để chia sẻ.');
      return;
    }

    try {
      final geojsonMap = {
        'type': 'FeatureCollection',
        'features': [
          ..._plots.map((p) => p.toGeoJsonFeature()),
          ..._poiList.map((poi) => {
            'type': 'Feature',
            'properties': {
              'id': poi.id,
              'title': poi.title,
              'description': poi.description,
              'type': poi.type.name,
              'severity': poi.severity,
              'groupName': poi.groupName,
              'time': poi.timestamp.toIso8601String(),
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [poi.position.longitude, poi.position.latitude],
            },
          }),
        ],
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(geojsonMap);
      final tempDir = await getTemporaryDirectory();
      final fileName = 'DNKC_GIS_Export_${DateTime.now().millisecondsSinceEpoch}.geojson';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(jsonStr);

      final totalArea = _plots.fold<double>(0, (s, p) => s + p.dienTich);
      final summaryText = 'Dữ liệu GIS Lô rừng: ${_plots.length} Lô (${totalArea.toStringAsFixed(1)} ha), ${_poiList.length} Điểm mốc/sự vụ.';

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/geo+json', name: fileName)],
          text: summaryText,
          subject: 'Chia sẻ dữ liệu GIS Ranh giới Lô rừng',
        ),
      );
    } catch (e) {
      _showToast('Lỗi chia sẻ: $e');
    }
  }

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    if (_isPickingPoiLocation) {
      setState(() => _isPickingPoiLocation = false);
      _openAddPoiDialog(position: point);
      return;
    }

    if (_mode == AppInteractionMode.digitizePlot || _mode == AppInteractionMode.gpsSurveyWalk) {
      _addPointToDigitizing(point);
      return;
    }

    if (_mode == AppInteractionMode.editVertex && _editingPlot != null) {
      if (_isAddingVertexMode) {
        _insertVertexAtNearestEdge(point);
        return;
      }
      if (_selectedVertexIndex != null) {
        setState(() {
          _editingPlot!.boundary[_selectedVertexIndex!] = point;
        });
        _showToast('Đã nắn đỉnh số ${_selectedVertexIndex! + 1}');
      }
      return;
    }

    ForestPlot? clickedPlot;
    for (var plot in _visiblePlots.reversed) {
      if (plot.containsPoint(point)) {
        clickedPlot = plot;
        break;
      }
    }

    setState(() => _selectedPlot = clickedPlot);
    if (clickedPlot != null) {
      _showPlotDetailSheet(clickedPlot);
    }
  }

  // -------------------------------------------------------------
  // HỆ THỐNG ĐỊNH DẠNG & CẤU HÌNH NHÃN NÂNG CAO (ẢNH 2)
  // -------------------------------------------------------------
  String _lookupLdlr(ForestPlot plot) {
    final raw = plot.attributes['maldlr'] ??
        plot.attributes['ldlr'] ??
        plot.attributes['hien_tr'] ??
        plot.trangThaiRung;
    if (_ldlrStandard == 'TT33') {
      if (raw.contains('14') || raw.toLowerCase().contains('giau')) return 'TXG';
      if (raw.contains('15') || raw.toLowerCase().contains('tb')) return 'TXB';
      if (raw.contains('16') || raw.toLowerCase().contains('ngheo')) return 'TXN';
      if (raw.contains('17') || raw.toLowerCase().contains('phuc hoi')) return 'TXP';
      if (raw.contains('cao su') || raw.contains('CS')) return 'RTCS';
      if (raw.contains('keo')) return 'RTK';
    }
    return raw;
  }

  String _getPlotFieldValue(ForestPlot plot, String fieldKey) {
    switch (fieldKey) {
      case 'TEN_LO':
        return plot.lo;
      case 'DIEN_TIC':
        // Hiển thị chuẩn xác diện tích hồ sơ (Lô đơn) hoặc diện tích mảnh (Lô phân mảnh)
        List<ForestPlot>? siblingPlots;
        if (plot.lo.trim().isNotEmpty) {
          siblingPlots = _plots.where((p) => p.groupName == plot.groupName && p.lo == plot.lo).toList();
        }
        final displayArea = GisCalculator.getPlotPieceArea(plot, allPlotsInLot: siblingPlots);
        return '${displayArea.toStringAsFixed(2)} ha';
      case 'CHU_V':
        final perim = GisCalculator.calculateTotalDistanceInMeters(plot.boundary, isClosed: true);
        return '${perim.toStringAsFixed(0)}m';
      case 'X':
        return plot.center.longitude.toStringAsFixed(4);
      case 'Y':
        return plot.center.latitude.toStringAsFixed(4);
      case 'LDLR':
        return _lookupLdlr(plot);
      case 'TRANG_THAI':
        return plot.trangThaiRung;
      case 'LOAI_CAY':
        return plot.loaiCay;
      case 'CHU_RUNG':
        return plot.chuRung;
      case 'NTRUONG':
        return plot.attributes['ntruong'] ?? plot.attributes['nong_truong'] ?? plot.khoanh;
      case 'CTY':
        return plot.attributes['cty'] ?? plot.attributes['cong_ty'] ?? plot.chuRung;
      case 'NONE':
      case 'KHÔNG HIỆN':
        return '';
      default:
        final keyLower = fieldKey.toLowerCase();
        if (keyLower == 'dien_tic' || keyLower == 'dien_tich' || keyLower == 'dt' || keyLower == 'dientich') {
          List<ForestPlot>? siblingPlots;
          if (plot.lo.trim().isNotEmpty) {
            siblingPlots = _plots.where((p) => p.groupName == plot.groupName && p.lo == plot.lo).toList();
          }
          final displayArea = GisCalculator.getPlotPieceArea(plot, allPlotsInLot: siblingPlots);
          return '${displayArea.toStringAsFixed(2)} ha';
        }
        return plot.attributes[fieldKey] ?? plot.attributes[keyLower] ?? '';
    }
  }

  String _getPlotLabelText(ForestPlot plot) {
    final top = _getPlotFieldValue(plot, _labelNumeratorField);
    final bottom = _getPlotFieldValue(plot, _labelDenominatorField);

    if (top.isNotEmpty && bottom.isNotEmpty) {
      return '$top\n$bottom';
    } else if (top.isNotEmpty) {
      return top;
    } else {
      return bottom;
    }
  }

  void _showAdvancedLabelSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String tempNumerator = _labelNumeratorField;
        String tempDenominator = _labelDenominatorField;
        double tempFontSize = _labelFontSize;
        double tempMinZoom = _labelMinZoom;
        Color tempColor = _labelColor;
        bool tempHalo = _labelHasHalo;
        Color? tempPolygonBorderColor = _polygonBorderColor;
        double tempPolygonBorderWidth = _polygonBorderWidth;
        String tempLdlr = _ldlrStandard;
        bool tempShowPlotPolygons = _showPlotPolygons;
        bool tempShowPlotLabels = _showPlotLabels;
        bool tempShowPatrolTracks = _showPatrolTracks;
        bool tempShowPois = _showPois;
        double tempPlotOpacity = _plotOpacity;
        bool tempHighPerformance = _highPerformanceMode;

        final availableNumeratorFields = [
          'TEN_LO', 'DIEN_TIC', 'CHU_V', 'X', 'Y', 'LDLR', 'NTRUONG', 'CTY', 'KHÔNG HIỆN'
        ];
        final availableDenominatorFields = [
          'DIEN_TIC', 'TEN_LO', 'CHU_V', 'X', 'Y', 'LDLR', 'LOAI_CAY', 'KHÔNG HIỆN'
        ];

        return StatefulBuilder(builder: (ctx, setSheetState) {
          final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
              ? MediaQuery.of(ctx).viewPadding.bottom
              : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 48.0);
          final safeBottom = bottomInset + 20.0;

          // Tạo text xem trước
          String sampleTop = 'Lô 110';
          String sampleBottom = '12.47 ha';
          if (_plots.isNotEmpty) {
            sampleTop = _getPlotFieldValue(_plots.first, tempNumerator);
            sampleBottom = _getPlotFieldValue(_plots.first, tempDenominator);
          }

          return Container(
            decoration: const BoxDecoration(
              color: Color(0xFF13182C), // Giao diện nền tối sang trọng chuẩn như ảnh 2
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: EdgeInsets.fromLTRB(16, 16, 16, safeBottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.88,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Tô màu & nhãn nâng cao',
                              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Bản đồ ranh giới · ${_plots.length} vùng',
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Khung Xem Trước (Preview mini)
                    Container(
                      width: double.infinity,
                      height: 120,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E382B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('Xem trước', style: TextStyle(color: Colors.white70, fontSize: 11)),
                            ),
                          ),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.amber.withValues(alpha: tempShowPlotPolygons ? tempPlotOpacity : 0.05),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: tempShowPlotPolygons
                                      ? (tempPolygonBorderColor ?? Colors.amber)
                                      : Colors.white24,
                                  width: tempShowPlotPolygons ? 2 : 1,
                                ),
                              ),
                              child: tempShowPlotLabels
                                  ? Text(
                                      [
                                        if (sampleTop.isNotEmpty) sampleTop,
                                        if (sampleBottom.isNotEmpty) sampleBottom,
                                      ].join('\n'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: tempColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: tempFontSize.clamp(9.0, 18.0),
                                        shadows: _buildLabelShadows(tempHalo, const Color(0xFF000000)),
                                      ),
                                    )
                                  : const Text(
                                      '(Lớp nhãn đang tắt)',
                                      style: TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // BẬT / TẮT CÁC LỚP HIỂN THỊ (Đưa vào theo yêu cầu người dùng)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B223C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Bật / Tắt các lớp hiển thị:',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 4),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Lớp Đa giác Ranh giới Lô rừng', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                            value: tempShowPlotPolygons,
                            activeColor: const Color(0xFF2E7D32),
                            checkColor: Colors.white,
                            side: const BorderSide(color: Colors.white54, width: 1.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            onChanged: (val) {
                              final newVal = val ?? true;
                              setSheetState(() => tempShowPlotPolygons = newVal);
                              setState(() => _showPlotPolygons = newVal);
                            },
                          ),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Lớp Nhãn tên Lô & Diện tích (ha)', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                            value: tempShowPlotLabels,
                            activeColor: const Color(0xFF2E7D32),
                            checkColor: Colors.white,
                            side: const BorderSide(color: Colors.white54, width: 1.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            onChanged: (val) {
                              final newVal = val ?? true;
                              setSheetState(() => tempShowPlotLabels = newVal);
                              setState(() => _showPlotLabels = newVal);
                            },
                          ),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Lớp Vết lộ trình Tuần tra rừng', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                            value: tempShowPatrolTracks,
                            activeColor: const Color(0xFF2E7D32),
                            checkColor: Colors.white,
                            side: const BorderSide(color: Colors.white54, width: 1.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            onChanged: (val) {
                              final newVal = val ?? true;
                              setSheetState(() => tempShowPatrolTracks = newVal);
                              setState(() => _showPatrolTracks = newVal);
                            },
                          ),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Lớp Điểm nóng / Điểm vi phạm (POI)', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                            value: tempShowPois,
                            activeColor: const Color(0xFF2E7D32),
                            checkColor: Colors.white,
                            side: const BorderSide(color: Colors.white54, width: 1.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            onChanged: (val) {
                              final newVal = val ?? true;
                              setSheetState(() => tempShowPois = newVal);
                              setState(() => _showPois = newVal);
                            },
                          ),
                          const Divider(color: Colors.white12, height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Độ mờ Lô rừng (nhìn xuyên vệ tinh):', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                              Text('${(tempPlotOpacity * 100).toInt()}%', style: const TextStyle(color: Color(0xFF4CAF50), fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                          SliderTheme(
                            data: SliderTheme.of(ctx).copyWith(
                              activeTrackColor: const Color(0xFF2E7D32),
                              thumbColor: const Color(0xFF4CAF50),
                              inactiveTrackColor: Colors.white24,
                              trackHeight: 3,
                            ),
                            child: Slider(
                              value: tempPlotOpacity,
                              min: 0.1,
                              max: 0.9,
                              divisions: 8,
                              onChanged: (v) {
                                setSheetState(() => tempPlotOpacity = v);
                                setState(() => _plotOpacity = v);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // TỬ SỐ (DÒNG TRÊN)
                    const Text('TỬ SỐ (DÒNG TRÊN)', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: availableNumeratorFields.map((f) {
                          final isSel = tempNumerator == f;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(f, style: TextStyle(fontSize: 11, color: isSel ? Colors.white : Colors.white70)),
                              selected: isSel,
                              selectedColor: const Color(0xFF673AB7),
                              backgroundColor: const Color(0xFF1F243E),
                              onSelected: (_) => setSheetState(() => tempNumerator = f),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // MẪU SỐ (DÒNG DƯỚI)
                    const Text('MẪU SỐ (DÒNG DƯỚI)', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: availableDenominatorFields.map((f) {
                          final isSel = tempDenominator == f;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(f, style: TextStyle(fontSize: 11, color: isSel ? Colors.white : Colors.white70)),
                              selected: isSel,
                              selectedColor: const Color(0xFF673AB7),
                              backgroundColor: const Color(0xFF1F243E),
                              onSelected: (_) => setSheetState(() => tempDenominator = f),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Hệ suy LDLR
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Hệ suy LDLR', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            ChoiceChip(
                              label: const Text('TT33', style: TextStyle(fontSize: 11)),
                              selected: tempLdlr == 'TT33',
                              selectedColor: const Color(0xFF673AB7),
                              backgroundColor: const Color(0xFF1F243E),
                              onSelected: (_) => setSheetState(() => tempLdlr = 'TT33'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('TT16', style: TextStyle(fontSize: 11)),
                              selected: tempLdlr == 'TT16',
                              selectedColor: const Color(0xFF673AB7),
                              backgroundColor: const Color(0xFF1F243E),
                              onSelected: (_) => setSheetState(() => tempLdlr = 'TT16'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Text('Data chỉ có MALDLR (số) -> tự suy ký hiệu LDLR (vd 14 -> TXG).',
                        style: TextStyle(color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 14),

                    // Cỡ chữ & Hiện từ Z
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Text('Cỡ chữ', style: TextStyle(color: Colors.white, fontSize: 13)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.white70, size: 22),
                                onPressed: () {
                                  if (tempFontSize > 8) setSheetState(() => tempFontSize -= 1);
                                },
                              ),
                              Text('${tempFontSize.toInt()}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline, color: Colors.white70, size: 22),
                                onPressed: () {
                                  if (tempFontSize < 24) setSheetState(() => tempFontSize += 1);
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Row(
                            children: [
                              const Text('Hiện từ Z', style: TextStyle(color: Colors.white, fontSize: 13)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.white70, size: 22),
                                onPressed: () {
                                  if (tempMinZoom > 10) setSheetState(() => tempMinZoom -= 1);
                                },
                              ),
                              Text('${tempMinZoom.toInt()}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline, color: Colors.white70, size: 22),
                                onPressed: () {
                                  if (tempMinZoom < 18) setSheetState(() => tempMinZoom += 1);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Màu chữ (Bảng màu phong phú + Nút chọn màu 360°)
                    Row(
                      children: [
                        const Text('Màu chữ', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.palette_outlined, color: Colors.amberAccent, size: 20),
                          tooltip: 'Chọn màu chữ tùy chỉnh 360°',
                          onPressed: () {
                            _openFullColorPickerDialog(
                              title: 'Chọn màu chữ nhãn',
                              currentColor: tempColor,
                              onColorSelected: (c) => setSheetState(() => tempColor = c),
                            );
                          },
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: appRichPalette.map((c) {
                                final isSel = tempColor.toARGB32() == c.toARGB32();
                                return GestureDetector(
                                  onTap: () => setSheetState(() => tempColor = c),
                                  child: Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: c,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSel ? Colors.white : Colors.white30,
                                        width: isSel ? 3 : 1,
                                      ),
                                    ),
                                    child: isSel
                                        ? Icon(Icons.check, size: 16, color: c.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                                        : null,
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Viền chữ (chỉ để mặc định in đậm viền tương phản như cũ)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Viền chữ', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            Switch(
                              value: tempHalo,
                              activeColor: const Color(0xFF673AB7),
                              onChanged: (val) => setSheetState(() => tempHalo = val),
                            ),
                            const Text('chữ đậm viền tương phản – dễ đọc', style: TextStyle(color: Colors.white70, fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Màu viền đa giác Lô rừng (Polygon Border) - vài màu cơ bản
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Màu viền đa giác Lô rừng (Polygon Border)',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: basicBorderColors.map((item) {
                              final Color? c = item['color'] as Color?;
                              final String name = item['name'] as String;
                              final isSel = tempPolygonBorderColor?.toARGB32() == c?.toARGB32();
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  avatar: c != null
                                      ? CircleAvatar(backgroundColor: c, radius: 7)
                                      : const Icon(Icons.auto_awesome, size: 14, color: Colors.amber),
                                  label: Text(name,
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                          color: isSel ? Colors.white : Colors.white70)),
                                  selected: isSel,
                                  selectedColor: const Color(0xFF673AB7),
                                  backgroundColor: const Color(0xFF1B223C),
                                  side: BorderSide(color: isSel ? Colors.white70 : Colors.white24),
                                  onSelected: (_) => setSheetState(() => tempPolygonBorderColor = c),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Độ dày viền đa giác Lô rừng (Polygon Border Width)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Độ dày viền đa giác (Polygon Border Width)',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              {'width': 0.6, 'name': 'Siêu mảnh (0.6px)'},
                              {'width': 1.0, 'name': 'Mảnh / Nhỏ (1.0px)'},
                              {'width': 1.5, 'name': 'Vừa (1.5px)'},
                              {'width': 2.0, 'name': 'Dày (2.0px)'},
                            ].map((item) {
                              final w = item['width'] as double;
                              final name = item['name'] as String;
                              final isSel = (tempPolygonBorderWidth - w).abs() < 0.1;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  avatar: Icon(Icons.line_weight, size: 14, color: isSel ? Colors.amberAccent : Colors.white70),
                                  label: Text(name,
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                          color: isSel ? Colors.white : Colors.white70)),
                                  selected: isSel,
                                  selectedColor: const Color(0xFF673AB7),
                                  backgroundColor: const Color(0xFF1B223C),
                                  side: BorderSide(color: isSel ? Colors.white70 : Colors.white24),
                                  onSelected: (_) => setSheetState(() => tempPolygonBorderWidth = w),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Cấu hình Chế độ Siêu Mượt khi nhiều Lô (Tối ưu GPU EvenOdd & nén đỉnh)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B223C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3)),
                      ),
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Row(
                          children: [
                            Icon(Icons.bolt, color: Colors.amberAccent, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Chế độ Siêu Mượt khi nhiều Lô',
                              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        subtitle: const Text(
                          'Tối ưu GPU EvenOdd, nén đỉnh đa giác & tự động ẩn nhãn khi zoom xa để giữ 60 FPS mượt mà',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        value: tempHighPerformance,
                        activeColor: Colors.greenAccent,
                        onChanged: (val) => setSheetState(() => tempHighPerformance = val),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Nút Đặt lại & Áp dụng lên bản đồ
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              setSheetState(() {
                                tempNumerator = 'TEN_LO';
                                tempDenominator = 'DIEN_TIC';
                                tempFontSize = 10.0;
                                tempMinZoom = 15.0;
                                tempColor = const Color(0xFFFFEB3B);
                                tempHalo = true;
                                tempPolygonBorderColor = null;
                                tempPolygonBorderWidth = 1.0;
                                tempLdlr = 'TT33';
                                tempShowPlotPolygons = true;
                                tempShowPlotLabels = true;
                                tempShowPatrolTracks = true;
                                tempShowPois = true;
                                tempPlotOpacity = 0.45;
                                tempHighPerformance = true;
                              });
                              setState(() {
                                _showPlotPolygons = true;
                                _showPlotLabels = true;
                                _showPatrolTracks = true;
                                _showPois = true;
                                _plotOpacity = 0.45;
                              });
                            },
                            child: const Text('Đặt lại'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF673AB7),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              setState(() {
                                _labelNumeratorField = tempNumerator;
                                _labelDenominatorField = tempDenominator;
                                _labelFontSize = tempFontSize;
                                _labelMinZoom = tempMinZoom;
                                _labelColor = tempColor;
                                _labelHasHalo = tempHalo;
                                _labelHaloColor = const Color(0xFF000000);
                                _polygonBorderColor = tempPolygonBorderColor;
                                _polygonBorderWidth = tempPolygonBorderWidth;
                                _ldlrStandard = tempLdlr;
                                _showPlotPolygons = tempShowPlotPolygons;
                                _showPlotLabels = tempShowPlotLabels;
                                _showPatrolTracks = tempShowPatrolTracks;
                                _showPois = tempShowPois;
                                _plotOpacity = tempPlotOpacity;
                                _highPerformanceMode = tempHighPerformance;
                              });
                              _savePersistentData();
                              Navigator.pop(ctx);
                              _showToast('Đã áp dụng định dạng và lớp hiển thị mới lên bản đồ!');
                            },
                            child: const Text('Áp dụng lên bản đồ', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating),
    );
  }

  // -------------------------------------------------------------
  // GIAO DIỆN CHÍNH (FULL MÀN HÌNH - KHÔNG BỊ THANH ĐIỀU HƯỚNG CHE)
  // -------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final sysBottom = MediaQuery.of(context).viewPadding.bottom > 0
        ? MediaQuery.of(context).viewPadding.bottom
        : (MediaQuery.of(context).padding.bottom > 0 ? MediaQuery.of(context).padding.bottom : 56.0);
    final bottomOffset = sysBottom + 48.0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 1. Nếu đang ở các chế độ đo đạc / chỉnh sửa / số hóa, bấm back sẽ hủy chế độ
        if (_mode != AppInteractionMode.normal) {
          setState(() {
            _mode = AppInteractionMode.normal;
            _editingPlot = null;
            _digitizingPoints.clear();
            _selectedVertexIndex = null;
            _isAddingVertexMode = false;
          });
          _showToast('Đã thoát chế độ đo đạc / chỉnh sửa');
          return;
        }

        // 2. Nếu đang làm nổi bật Lô tìm kiếm, bấm back sẽ tắt nổi bật trước
        if (_highlightedPlotIds.isNotEmpty) {
          setState(() {
            _highlightedPlotIds.clear();
            _highlightedPlotName = null;
            _highlightedRegionCount = 0;
            _highlightedTotalArea = 0.0;
          });
          _showToast('Đã tắt chế độ nổi bật Lô');
          return;
        }

        // 3. Nếu đang chọn một Lô hoặc POI, bấm back sẽ bỏ chọn trước
        if (_selectedPlot != null) {
          setState(() => _selectedPlot = null);
          return;
        }

        // 4. Trở về màn hình đăng nhập theo yêu cầu
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1E2820),
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: Stack(
        children: [
          // 1. BẢN ĐỒ GIS TRÀN VIỀN FULL MÀN HÌNH
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(11.3420, 107.0390),
              initialZoom: 15.2,
              minZoom: 3.0,
              maxZoom: 22.0,
              initialRotation: 0.0,
              interactionOptions: InteractionOptions(
                flags: _isNorthLocked
                    ? (InteractiveFlag.all & ~InteractiveFlag.rotate)
                    : InteractiveFlag.all,
              ),
              onTap: _onMapTap,
              onPositionChanged: (camera, hasGesture) {
                if (camera.rotation != _currentMapRotation) {
                  setState(() => _currentMapRotation = camera.rotation);
                }
                if ((camera.zoom - _currentMapZoom).abs() > 0.15) {
                  setState(() => _currentMapZoom = camera.zoom);
                } else if (_plots.length > 50) {
                  final dist = (camera.center.latitude - _lastRenderedCenter.latitude).abs() +
                      (camera.center.longitude - _lastRenderedCenter.longitude).abs();
                  if (dist > 0.008) {
                    _lastRenderedCenter = camera.center;
                    setState(() {});
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _tileUrl,
                subdomains: const ['0', '1', '2', '3'],
                fallbackUrl: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.vdmgis.vn',
                minZoom: 1.0,
                maxZoom: 22.0,
                maxNativeZoom: _maxNativeZoom,
                panBuffer: 1,
                keepBuffer: 3,
                tileProvider: PersistentOfflineTileProvider(
                  baseLayerKey: _baseLayer.name,
                ),
                evictErrorTileStrategy: EvictErrorTileStrategy.none,
                reset: _tileResetController.stream,
              ),

              // Lớp Phủ Bản Đồ Ảnh Địa Lý / Sơ Đồ Quy Hoạch Nắn Tọa Độ (GeoPackage Raster Tiles)
              if (_rasterOverlays.isNotEmpty)
                OverlayImageLayer(
                  overlayImages: _rasterOverlays
                      .where((o) => o.isVisible && !_hiddenGroups.contains(o.groupName) && File(o.imagePath).existsSync())
                      .map((o) => OverlayImage(
                            bounds: o.bounds,
                            imageProvider: FileImage(File(o.imagePath)),
                            opacity: o.opacity,
                          ))
                      .toList(),
                ),

              // Vòng tròn bán kính sai số GPS (Accuracy circle)
              if (_currentGpsPosition != null && _rawPosition != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _currentGpsPosition!,
                      radius: (_rawPosition!.accuracy).clamp(8.0, 60.0),
                      useRadiusInMeter: true,
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderColor: Colors.blueAccent,
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),

              // Lớp Đa Giác Lô Rừng (Áp dụng GPU EvenOdd & Viewport Culling siêu mượt)
              if (_showPlotPolygons)
                PolygonLayer(
                  simplificationTolerance: _highPerformanceMode ? 0.6 : 0.3,
                  painterFillMethod: PolygonPainterFillMethod.evenOdd,
                  polygonCulling: true,
                  polygons: () {
                    final rendered = _renderedPlots;
                    final totalRendered = rendered.length;
                    // Tự động tinh chỉnh nhãn thông minh khi có nhiều Lô
                    final bool allowGeneralLabels = _showPlotLabels &&
                        _currentMapZoom >= _labelMinZoom &&
                        (!_highPerformanceMode || totalRendered <= 80 || _currentMapZoom >= 15.8);

                    final baseLabelStyle = TextStyle(
                      color: _labelColor,
                      fontWeight: FontWeight.bold,
                      fontSize: _labelFontSize,
                      shadows: _buildLabelShadows(_labelHasHalo, _labelHaloColor),
                    );

                    final bool isHighlightActive = _highlightedPlotIds.isNotEmpty;

                    return rendered.map((plot) {
                      final isPlotHighlighted = _highlightedPlotIds.contains(plot.id);
                      final isSelected = _selectedPlot?.id == plot.id;
                      final isGpsHere = _plotUnderGps?.id == plot.id;
                      final isEditing = _editingPlot?.id == plot.id;

                      Color fillColor;
                      Color borderColor;
                      double strokeWidth;
                      bool shouldShowLabel;

                      if (isHighlightActive) {
                        if (isPlotHighlighted) {
                          // VÙNG ĐƯỢC TÌM KIẾM: Tô màu vàng neon sáng rực rỡ, viền cam đỏ dày 4px
                          fillColor = const Color(0xFFFFD600).withValues(alpha: 0.75);
                          borderColor = const Color(0xFFFF3D00);
                          strokeWidth = 4.0;
                          shouldShowLabel = true;
                        } else {
                          // CÁC VÙNG KHÁC: Làm tối mờ để các vùng của Lô tìm kiếm nổi bật tuyệt đối
                          fillColor = Colors.black.withValues(alpha: 0.35);
                          borderColor = Colors.white.withValues(alpha: 0.15);
                          strokeWidth = 1.0;
                          shouldShowLabel = false;
                        }
                      } else {
                        fillColor = isEditing
                            ? Colors.purple.withValues(alpha: 0.4)
                            : isSelected
                                ? Colors.yellow.withValues(alpha: 0.55)
                                : isGpsHere
                                    ? Colors.greenAccent.withValues(alpha: 0.55)
                                    : plot.color.withValues(alpha: _plotOpacity);
                        borderColor = isEditing
                            ? Colors.purple
                            : isSelected
                                ? Colors.amber[900]!
                                : isGpsHere
                                    ? Colors.green[900]!
                                    : (_polygonBorderColor ?? plot.color);
                        strokeWidth = isSelected || isGpsHere || isEditing ? 3.0 : _polygonBorderWidth;
                        shouldShowLabel = allowGeneralLabels || isSelected || isGpsHere;
                      }

                      return Polygon(
                        points: plot.boundary,
                        color: fillColor,
                        borderColor: borderColor,
                        borderStrokeWidth: strokeWidth,
                        label: shouldShowLabel ? _getPlotLabelText(plot) : null,
                        labelStyle: isPlotHighlighted
                            ? TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: math.max(_labelFontSize + 3.5, 14.5),
                                height: 1.25,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 3, offset: Offset(-1.2, -1.2)),
                                  Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1.2, -1.2)),
                                  Shadow(color: Colors.black, blurRadius: 3, offset: Offset(-1.2, 1.2)),
                                  Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1.2, 1.2)),
                                  Shadow(color: Colors.black, blurRadius: 6, offset: Offset(0, 0)),
                                ],
                              )
                            : baseLabelStyle,
                      );
                    }).toList();
                  }(),
                ),

              // Lớp Đang Số Hóa Lô Mới / Đo đạc GPS / Bấm điểm (Hỗ trợ kéo thả di chuyển đỉnh)
              if ((_mode == AppInteractionMode.digitizePlot || _mode == AppInteractionMode.gpsSurveyWalk) && _digitizingPoints.isNotEmpty) ...[
                if (_digitizingPoints.length >= 3)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: _digitizingPoints,
                        color: _mode == AppInteractionMode.gpsSurveyWalk
                            ? Colors.cyanAccent.withValues(alpha: 0.35)
                            : Colors.greenAccent.withValues(alpha: 0.4),
                        borderColor: _mode == AppInteractionMode.gpsSurveyWalk
                            ? Colors.cyan[800]!
                            : Colors.green[800]!,
                        borderStrokeWidth: 3.0,
                      ),
                    ],
                  ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _digitizingPoints.length >= 3
                          ? [..._digitizingPoints, _digitizingPoints.first]
                          : _digitizingPoints,
                      color: _mode == AppInteractionMode.gpsSurveyWalk ? Colors.cyan[900]! : Colors.green[800]!,
                      strokeWidth: 3.0,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: _digitizingPoints.asMap().entries.map((e) {
                    final index = e.key;
                    final isSel = _selectedVertexIndex == index;
                    return Marker(
                      point: e.value,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() => _selectedVertexIndex = index);
                          _showToast('Đang chọn đỉnh #${index + 1}. Kéo để di chuyển hoặc bấm nút xóa');
                        },
                        onPanStart: (_) {
                          setState(() => _selectedVertexIndex = index);
                        },
                        onPanUpdate: (details) {
                          final curOffset = _mapController.camera.latLngToScreenOffset(_digitizingPoints[index]);
                          final newOffset = curOffset + details.delta;
                          final newLatLng = _mapController.camera.screenOffsetToLatLng(newOffset);
                          setState(() {
                            _digitizingPoints[index] = newLatLng;
                          });
                        },
                        onPanEnd: (_) {
                          _showToast('Đã di chuyển đỉnh #${index + 1} tới vị trí mới');
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSel
                                ? Colors.redAccent
                                : (_mode == AppInteractionMode.gpsSurveyWalk
                                    ? Colors.cyan[800]
                                    : const Color(0xFF2E7D32)),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              // Lớp Đang Nắn Sửa Đỉnh (Hỗ trợ thêm/xóa & KÉO THẢ DI CHUYỂN ĐỈNH)
              if (_mode == AppInteractionMode.editVertex && _editingPlot != null) ...[
                // Markers tại các đỉnh hiện tại (có thể chạm chọn hoặc Kéo thả trực tiếp)
                MarkerLayer(
                  markers: _editingPlot!.boundary.asMap().entries.map((e) {
                    final isSel = _selectedVertexIndex == e.key;
                    return Marker(
                      point: e.value,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() => _selectedVertexIndex = e.key);
                          _showToast('Đang chọn đỉnh số ${e.key + 1}. Bạn có thể kéo thả để di chuyển.');
                        },
                        onPanStart: (_) {
                          setState(() => _selectedVertexIndex = e.key);
                        },
                        onPanUpdate: (details) {
                          final curOffset = _mapController.camera.latLngToScreenOffset(_editingPlot!.boundary[e.key]);
                          final newOffset = curOffset + details.delta;
                          final newLatLng = _mapController.camera.screenOffsetToLatLng(newOffset);
                          setState(() {
                            _editingPlot!.boundary[e.key] = newLatLng;
                          });
                        },
                        onPanEnd: (_) {
                          _showToast('Đã di chuyển đỉnh số ${e.key + 1}');
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSel ? Colors.amber : Colors.purple[700],
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                          ),
                          child: Center(
                            child: Text('${e.key + 1}',
                                style: TextStyle(
                                    color: isSel ? Colors.black : Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                // Markers dấu (+) ở giữa các đỉnh để chèn đỉnh mới cực nhanh
                MarkerLayer(
                  markers: List.generate(_editingPlot!.boundary.length, (i) {
                    final next = (i + 1) % _editingPlot!.boundary.length;
                    final p1 = _editingPlot!.boundary[i];
                    final p2 = _editingPlot!.boundary[next];
                    final mid = LatLng((p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);

                    return Marker(
                      point: mid,
                      width: 26,
                      height: 26,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _editingPlot!.boundary.insert(i + 1, mid);
                            _selectedVertexIndex = i + 1;
                          });
                          _showToast('Đã thêm đỉnh mới số ${i + 2}. Kéo hoặc chạm điểm mới để di chuyển');
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.teal[600],
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
                          ),
                          child: const Icon(Icons.add, size: 16, color: Colors.white),
                        ),
                      ),
                    );
                  }),
                ),
              ],

              // Lớp Vết Tuần Tra
              if (_showPatrolTracks) ...[
                for (var track in _completedPatrols)
                  PolylineLayer(
                    polylines: [
                      Polyline(points: track.points, color: Colors.blueAccent.withValues(alpha: 0.7), strokeWidth: 3.5),
                    ],
                  ),
                if (_activePatrol != null && _activePatrol!.points.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(points: _activePatrol!.points, color: Colors.redAccent, strokeWidth: 4.5),
                    ],
                  ),
              ],

              // Lớp Điểm Nóng / Vi Phạm (POI)
              if (_showPois)
                MarkerLayer(
                  markers: _visiblePois.map((poi) {
                    return Marker(
                      point: poi.position,
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onTap: () => _showPoiDetailSheet(poi),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: poi.color,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2))],
                              ),
                              child: Icon(poi.icon, color: Colors.white, size: 20),
                            ),
                            if (poi.reminderEnabled)
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(2.5),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFFD54F),
                                    shape: BoxShape.circle,
                                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)],
                                  ),
                                  child: const Icon(Icons.notifications_active, color: Colors.black, size: 11),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

              // Chấm Xanh Vị Trí GPS Thật
              if (_currentGpsPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentGpsPosition!,
                      width: 48,
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.25),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.blue[700],
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // 2. HUD TRẮC ĐỊA TRÊN ĐỈNH
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _buildGpsHud(),
            ),
          ),

          // THANH CHỈ HƯỚNG (NAM/BẮC), KHÓA HƯỚNG BẮC, DI CHUYỂN THEO BẢN ĐỒ (GÓC TRÊN BÊN PHẢI)
          _buildCompassAndNavigationToolbar(),

          // BANNER HƯỚNG DẪN CHỌN VỊ TRÍ ĐÁNH DẤU TRÊN BẢN ĐỒ
          if (_isPickingPoiLocation)
            Positioned(
              top: MediaQuery.of(context).padding.top + (_isHudExpanded ? 165 : 75),
              left: 16,
              right: 68,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(10),
                color: Colors.red[900],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.touch_app, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Chạm trên bản đồ để chọn tọa độ đánh dấu',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _isPickingPoiLocation = false),
                        child: const Icon(Icons.close, color: Colors.white, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // BANNER CHẾ ĐỘ XEM THỬ (KHI DÙNG NGAY / CHƯA KÍCH HOẠT BẢN QUYỀN)
          if (_isReadOnly)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(10, 2, 10, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE65100),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_rounded, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'CHẾ ĐỘ XEM THỬ • KHÔNG ĐƯỢC THAO TÁC',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.3),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => const LoginScreen()),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'KÍCH HOẠT MÃ MÁY',
                            style: TextStyle(color: Color(0xFFE65100), fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // BIỂU TƯỢNG NHỎ PHÍA TRÊN GÓC TRÁI MÀN HÌNH (Hồ sơ cán bộ & Menu Nạp file / Quản lý lớp)
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, top: 4),
                child: Material(
                  elevation: 6,
                  shape: const CircleBorder(),
                  color: Colors.transparent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _showUserProfileMenu,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF2E7D32), Color(0xFF1B5E20)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 6,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _userProfile.initials,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: _userProfile.initials.length > 3
                              ? 10
                              : (_userProfile.initials.length == 3 ? 12 : 14),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 3. THANH CÔNG CỤ SỐ HÓA & ĐO ĐẠC
          if (_mode == AppInteractionMode.digitizePlot || _mode == AppInteractionMode.gpsSurveyWalk)
            Positioned(
              top: 130,
              left: 16,
              right: 16,
              child: _buildDigitizingToolbar(),
            ),

          if (_mode == AppInteractionMode.editVertex && _editingPlot != null)
            Positioned(
              top: 130,
              left: 16,
              right: 16,
              child: _buildVertexEditToolbar(),
            ),

          // 4. DANH SÁCH TÌM KIẾM
          if (_searchQuery.isNotEmpty)
            Positioned(
              top: 130,
              left: 16,
              right: 16,
              child: _buildSearchResults(),
            ),

          // BANNER NỔI BẬT LÔ RỪNG ĐƯỢC TÌM KIẾM (ĐA VÙNG) - DỜI XUỐNG DƯỚI ĐÁY MÀN HÌNH
          if (_highlightedPlotIds.isNotEmpty)
            Positioned(
              left: 14,
              right: 76, // Chừa khoảng trống bên phải cho hàng nút điều khiển
              bottom: bottomOffset,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(22),
                  color: const Color(0xF0181818),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0xFFFFD600), width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFD600),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Tổng Lô ${_highlightedPlotName ?? ""} • Tổng DT: ${_highlightedTotalArea.toStringAsFixed(2)} ha',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            setState(() {
                              _highlightedPlotIds.clear();
                              _highlightedPlotName = null;
                              _highlightedRegionCount = 0;
                              _highlightedTotalArea = 0.0;
                            });
                            _showToast('Đã tắt nổi bật Lô');
                          },
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 5. CÁC NÚT ĐIỀU KHIỂN BÊN PHẢI (ĐÃ ĐẨY CAO TRÁNH THANH ĐIỀU HƯỚNG HỆ THỐNG)
          Positioned(
            right: 14,
            bottom: bottomOffset, // ĐẨY LÊN CAO ĐỂ KHÔNG BỊ PHÍM ĐIỀU HƯỚNG CHE
            child: _buildControlButtons(),
          ),
        ],
      ),
    ),
  );
}

  // HUD GPS
  Widget _buildGpsHud() {
    final pos = _rawPosition;
    final vn2000 = pos != null
        ? Vn2000Converter.toVN2000(LatLng(pos.latitude, pos.longitude))
        : null;

    final latDms = pos != null ? Vn2000Converter.toDMS(pos.latitude, true) : 'Đang tìm vệ tinh...';
    final lngDms = pos != null ? Vn2000Converter.toDMS(pos.longitude, false) : '';
    final accuracy = pos?.accuracy;

    return Container(
      margin: const EdgeInsets.fromLTRB(54, 4, 12, 4),
      decoration: BoxDecoration(
        color: const Color(0xF0181818),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _isLiveGpsActive ? Colors.greenAccent : (_rawPosition != null ? Colors.blueAccent : Colors.redAccent),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: _rawPosition == null
                              ? 'ĐANG TÌM GPS '
                              : _plotUnderGps != null
                                  ? 'VỊ TRÍ: ${_plotUnderGps!.fullName.toUpperCase()} '
                                  : 'VỊ TRÍ HIỆN TẠI ',
                          style: TextStyle(
                            color: _plotUnderGps != null ? const Color(0xFF69F0AE) : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                        ),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: ValueListenableBuilder<DateTime>(
                            valueListenable: _clockNotifier,
                            builder: (_, now, __) {
                              final clockStr =
                                  '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
                              return Text(
                                '($clockStr)',
                                style: const TextStyle(
                                  color: Color(0xFF81D4FA),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _isHudExpanded = !_isHudExpanded),
                  child: Icon(
                    _isHudExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),

          if (_isHudExpanded && pos != null) ...[
            const Divider(color: Colors.white12, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('WGS-84 THỰC TẾ (DMS)',
                            style: TextStyle(color: Colors.white38, fontSize: 9.5, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text('X: $latDms\nY: $lngDms',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                        Text('X: ${pos.latitude.toStringAsFixed(6)}\nY: ${pos.longitude.toStringAsFixed(6)}',
                            style: const TextStyle(
                                color: Color(0xFF69F0AE), fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Container(width: 1, height: 68, color: Colors.white12),
                  const SizedBox(width: 6),
                  if (vn2000 != null)
                    Expanded(
                      flex: 11,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('VN-2000 (MÚI 3° KTT 107°)',
                              style: TextStyle(color: Colors.white38, fontSize: 9.5, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text('X: ${vn2000['x']!.toStringAsFixed(1)} m\nY: ${vn2000['y']!.toStringAsFixed(1)} m',
                              style: const TextStyle(
                                  color: Color(0xFF81D4FA),
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold)),
                          Text('X: $latDms\nY: $lngDms',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  Container(width: 1, height: 68, color: Colors.white12),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Cao: ${pos.altitude.toStringAsFixed(0)}m',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                          accuracy != null ? 'Sai số: ± ${accuracy.toStringAsFixed(1)}m' : 'Sai số: --',
                          style: TextStyle(
                            color: accuracy != null && accuracy <= 5 ? const Color(0xFF69F0AE) : const Color(0xFFFFB74D),
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Nhiệt độ: $_currentTemperature',
                          style: const TextStyle(
                            color: Color(0xFFFFB74D),
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // THANH CHỈ HƯỚNG (NAM/BẮC) BÊN TRÊN GÓC PHẢI MÀN HÌNH; MỞ/KHÓA BẮC, BẬT/TẮT THEO BẢN ĐỒ
  Widget _buildCompassAndNavigationToolbar() {
    final safeTop = MediaQuery.of(context).padding.top;
    final topOffset = safeTop + (_isHudExpanded ? 175.0 : 78.0);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      top: topOffset,
      right: 12,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0181818),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. KIM CHỈ HƯỚNG LA BÀN NAM/BẮC
            Tooltip(
              message: 'Căn bản đồ về hướng Bắc (0°)',
              child: InkWell(
                onTap: () {
                  _mapController.rotate(0);
                  setState(() => _currentMapRotation = 0);
                  _showToast('Đã hướng bản đồ về phương Bắc (0°)');
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white38, width: 1.2),
                          color: const Color(0xFF263238),
                        ),
                      ),
                      Transform.rotate(
                        angle: -(_currentMapRotation * (math.pi / 180)),
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CustomPaint(
                            painter: _CompassNeedlePainter(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(width: 28, height: 1, color: Colors.white12),
            const SizedBox(height: 4),

            // 2. CHẾ ĐỘ MỞ / KHÓA HƯỚNG BẮC
            Tooltip(
              message: _isNorthLocked ? 'Khóa hướng Bắc (Bật)' : 'Mở xoay bản đồ (Bật)',
              child: InkWell(
                onTap: () {
                  setState(() {
                    _isNorthLocked = !_isNorthLocked;
                    if (_isNorthLocked) {
                      _mapController.rotate(0);
                      _currentMapRotation = 0;
                      _showToast('Đã KHÓA hướng Bắc (Bản đồ cố định hướng Bắc)');
                    } else {
                      _showToast('Đã MỞ hướng Bắc (Cho phép xoay tự do)');
                    }
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _isNorthLocked
                        ? const Color(0xFFF57F17).withValues(alpha: 0.35)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: _isNorthLocked
                        ? Border.all(color: const Color(0xFFFFD54F), width: 1.2)
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isNorthLocked ? Icons.lock : Icons.lock_open,
                        color: _isNorthLocked ? const Color(0xFFFFD54F) : Colors.white70,
                        size: 18,
                      ),
                      Text(
                        _isNorthLocked ? 'Khóa B' : 'Mở B',
                        style: TextStyle(
                          color: _isNorthLocked ? const Color(0xFFFFD54F) : Colors.white60,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(width: 28, height: 1, color: Colors.white12),
            const SizedBox(height: 4),

            // 3. BẬT / TẮT DI CHUYỂN THEO BẢN ĐỒ
            Tooltip(
              message: _isFollowLocation
                  ? 'Đang di chuyển theo bản đồ (Bật)'
                  : 'Chế độ xem tự do (Bật bám GPS)',
              child: InkWell(
                onTap: () {
                  setState(() {
                    _isFollowLocation = !_isFollowLocation;
                    if (_isFollowLocation) {
                      if (_currentGpsPosition != null) {
                        _mapController.move(_currentGpsPosition!, _mapController.camera.zoom);
                      }
                      _showToast('Đã BẬT di chuyển theo bản đồ (Bám theo GPS)');
                    } else {
                      _showToast('Đã TẮT di chuyển theo bản đồ (Cuộn tự do)');
                    }
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _isFollowLocation
                        ? const Color(0xFF2E7D32).withValues(alpha: 0.45)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: _isFollowLocation
                        ? Border.all(color: const Color(0xFF69F0AE), width: 1.2)
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isFollowLocation ? Icons.navigation : Icons.pan_tool_alt,
                        color: _isFollowLocation ? const Color(0xFF69F0AE) : Colors.white70,
                        size: 18,
                      ),
                      Text(
                        _isFollowLocation ? 'Bám vị trí' : 'Tự do',
                        style: TextStyle(
                          color: _isFollowLocation ? const Color(0xFF69F0AE) : Colors.white60,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSurveyModeSelectionSheet() {
    if (!_checkCanPerformAction('Đo đạc & Số hóa')) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'CHỌN CHẾ ĐỘ ĐO ĐẠC & SỐ HÓA',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                ),
                const SizedBox(height: 12),
                ListTile(
                  tileColor: Colors.green.shade50,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF2E7D32),
                    child: Icon(Icons.directions_walk, color: Colors.white),
                  ),
                  title: const Text('1. Đo đạc theo GPS (Đi thực địa)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: const Text(
                    'Cầm ĐT đi khoảng 5m máy tự thêm 1 điểm. Bấm kết thúc sẽ tự khép Polygon + tính diện tích, chu vi & tọa độ.',
                    style: TextStyle(fontSize: 11, color: Colors.black87),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _mode = AppInteractionMode.gpsSurveyWalk;
                      _digitizingPoints.clear();
                      _selectedVertexIndex = null;
                      _gpsWalkCurrentDist = 0.0;
                      if (_currentGpsPosition != null) {
                        _digitizingPoints.add(_currentGpsPosition!);
                      }
                    });
                    _startLiveGpsStream();
                    _showToast('Đã bật đo GPS: Cầm ĐT đi ~5m máy sẽ tự động ghim 1 điểm');
                  },
                ),
                const SizedBox(height: 10),
                ListTile(
                  tileColor: Colors.amber.shade50,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const CircleAvatar(
                    backgroundColor: Colors.amber,
                    child: Icon(Icons.touch_app, color: Colors.black87),
                  ),
                  title: const Text('2. Đo diện tích bấm điểm (Ngồi 1 chỗ)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: const Text(
                    'Chạm các góc trên bản đồ để nối điểm. Cho phép chạm chọn đỉnh rồi KÉO di chuyển và buông tay để nắn.',
                    style: TextStyle(fontSize: 11, color: Colors.black87),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _mode = AppInteractionMode.digitizePlot;
                      _digitizingPoints.clear();
                      _selectedVertexIndex = null;
                    });
                    _showToast('Chạm các góc trên bản đồ để vẽ Lô. Có thể kéo di chuyển đỉnh tùy ý');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // THANH SỐ HÓA & ĐO ĐẠC
  Widget _buildDigitizingToolbar() {
    final areaHa = GisCalculator.calculateAreaInHectares(_digitizingPoints);
    final perimeterM = GisCalculator.calculateTotalDistanceInMeters(_digitizingPoints, isClosed: true);
    final isGpsWalk = _mode == AppInteractionMode.gpsSurveyWalk;

    return Card(
      color: isGpsWalk ? const Color(0xF0004D40) : const Color(0xF01B5E20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(isGpsWalk ? Icons.directions_walk : Icons.touch_app, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      isGpsWalk ? 'ĐO ĐẠC GPS THỰC ĐỊA' : 'ĐO DIỆN TÍCH BẤM ĐIỂM',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_digitizingPoints.length} đỉnh',
                    style: const TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (isGpsWalk)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Cầm ĐT đi ~5m máy tự thêm điểm (Hiện tại: ${_gpsWalkCurrentDist.toStringAsFixed(1)} / 5.0m)',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Chạm bản đồ thêm điểm · Chạm và KÉO đỉnh để di chuyển · Buông tay để đặt lại',
                  style: TextStyle(color: Colors.white70, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Diện tích: ${areaHa.toStringAsFixed(2)} ha (${(areaHa * 10000).toStringAsFixed(0)} m²)',
                      style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('Chu vi: ${perimeterM.toStringAsFixed(1)} m',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (!isGpsWalk) ...[
                  if (_selectedVertexIndex != null)
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onPressed: () {
                          setState(() {
                            if (_selectedVertexIndex! < _digitizingPoints.length) {
                              _digitizingPoints.removeAt(_selectedVertexIndex!);
                              _selectedVertexIndex = null;
                            }
                          });
                          _showToast('Đã xóa đỉnh đã chọn');
                        },
                        icon: const Icon(Icons.delete, size: 16),
                        label: Text('Xóa đỉnh #${_selectedVertexIndex! + 1}', style: const TextStyle(fontSize: 11)),
                      ),
                    )
                  else if (_digitizingPoints.isNotEmpty)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onPressed: () {
                          setState(() => _digitizingPoints.removeLast());
                          _showToast('Đã hoàn tác điểm gần nhất');
                        },
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text('Hoàn tác', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  const SizedBox(width: 6),
                ] else ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _captureGpsForDigitizing,
                      icon: const Icon(Icons.gps_fixed, size: 16),
                      label: const Text('Ghim điểm ngay', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: isGpsWalk ? const Color(0xFF004D40) : const Color(0xFF1B5E20),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onPressed: _openSavePlotDialog,
                    icon: const Icon(Icons.check_circle, size: 16, color: Color(0xFF2E7D32)),
                    label: const Text('Kết thúc & Lưu Lô', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                IconButton(
                  tooltip: 'Hủy đo đạc',
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => setState(() {
                    _digitizingPoints.clear();
                    _selectedVertexIndex = null;
                    _mode = AppInteractionMode.normal;
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // THANH SỬA ĐỈNH (HỖ TRỢ THÊM / XÓA NHIỀU ĐIỂM)
  Widget _buildVertexEditToolbar() {
    if (_editingPlot == null) return const SizedBox.shrink();
    final vertexCount = _editingPlot!.boundary.length;

    return Card(
      color: const Color(0xF0311B92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'NẮN SỬA: ${_editingPlot!.fullName}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(10)),
                  child: Text('$vertexCount đỉnh', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black)),
                ),
                const SizedBox(width: 6),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 28),
                  tooltip: 'Lưu thay đổi',
                  onPressed: _saveEditedPlot,
                ),
                const SizedBox(width: 8),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.close, color: Colors.white70, size: 24),
                  tooltip: 'Hủy sửa',
                  onPressed: () {
                    setState(() {
                      _mode = AppInteractionMode.normal;
                      _editingPlot = null;
                      _selectedVertexIndex = null;
                      _isAddingVertexMode = false;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _isAddingVertexMode
                  ? 'Chế độ THÊM ĐỈNH: Chạm vị trí bất kỳ trên bản đồ để chèn đỉnh mới.'
                  : (_selectedVertexIndex != null
                      ? 'Đang chọn đỉnh số ${_selectedVertexIndex! + 1}. Chạm điểm mới trên bản đồ để di chuyển.'
                      : 'Chạm vào dấu (+) giữa 2 điểm hoặc chạm trực tiếp vào đỉnh tròn để nắn.'),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                // Nút Chạm để thêm đỉnh
                FilterChip(
                  avatar: Icon(
                    _isAddingVertexMode ? Icons.check : Icons.add_location_alt,
                    size: 16,
                    color: _isAddingVertexMode ? Colors.white : Colors.black,
                  ),
                  label: Text(
                    _isAddingVertexMode ? 'Đang thêm đỉnh...' : 'Thêm đỉnh mới',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isAddingVertexMode ? Colors.white : Colors.black,
                    ),
                  ),
                  selected: _isAddingVertexMode,
                  selectedColor: Colors.teal[700],
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Colors.black12, width: 1),
                  onSelected: (val) {
                    setState(() => _isAddingVertexMode = val);
                    if (val) {
                      _showToast('Chạm vào bất kỳ vị trí nào trên bản đồ để chèn thêm đỉnh');
                    }
                  },
                ),
                // Nút Ghim GPS
                ActionChip(
                  avatar: const Icon(Icons.gps_fixed, size: 16, color: Colors.black),
                  label: const Text(
                    'Ghim GPS',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black),
                  ),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Colors.black12, width: 1),
                  onPressed: () {
                    if (_currentGpsPosition != null) {
                      _insertVertexAtNearestEdge(_currentGpsPosition!);
                    } else {
                      _showToast('Chưa có tín hiệu GPS');
                    }
                  },
                ),
                // Nút Xóa đỉnh đã chọn
                if (_selectedVertexIndex != null)
                  ActionChip(
                    avatar: const Icon(Icons.delete_forever, size: 16, color: Colors.white),
                    label: Text('Xóa đỉnh ${_selectedVertexIndex! + 1}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                    backgroundColor: Colors.red[800],
                    onPressed: () {
                      if (_editingPlot!.boundary.length <= 3) {
                        _showToast('Không thể xóa: Đa giác cần tối thiểu 3 đỉnh');
                        return;
                      }
                      setState(() {
                        _editingPlot!.boundary.removeAt(_selectedVertexIndex!);
                        _selectedVertexIndex = null;
                      });
                      _showToast('Đã xóa đỉnh thành công');
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // =============================================================
  // TÌM KIẾM THEO TÊN LÔ (CHỈ LỌC LỚP ĐƯỢC MỞ ĐẦU TIÊN, BỎ QUA CÁC LỚP ĐÃ ẨN)
  // =============================================================
  void _openSearchPlotDialog() {
    // 1. Xác định Lớp được mở đầu tiên (bỏ qua các lớp đã bị ẩn đi)
    final groupOrder = _getCurrentGroupOrder();
    String firstLayerName = '';
    for (final g in groupOrder) {
      if (_hiddenGroups.contains(g)) continue; // Bỏ qua các lớp đã bị ẩn đi
      if (_plots.any((p) => p.groupName == g)) {
        firstLayerName = g;
        break;
      }
    }
    if (firstLayerName.isEmpty) {
      final visiblePlots = _plots.where((p) => !_hiddenGroups.contains(p.groupName));
      if (visiblePlots.isNotEmpty) {
        firstLayerName = visiblePlots.first.groupName;
      }
    }

    // Chỉ lọc các lô thuộc lớp đang mở đầu tiên (bỏ qua lớp bị ẩn)
    final firstLayerPlots = firstLayerName.isNotEmpty
        ? _plots.where((p) => p.groupName == firstLayerName && !_hiddenGroups.contains(p.groupName)).toList()
        : <ForestPlot>[];

    // 2. Nhóm các đa giác theo Lô (Số hiệu Lô + Khoảnh + Tiểu khu) để hỗ trợ Lô có 3, 4... vùng
    final Map<String, List<ForestPlot>> groupedByPlot = {};
    for (final p in firstLayerPlots) {
      final loKey = p.lo.trim().isNotEmpty
          ? '${p.tieuKhu.trim().toLowerCase()}_${p.khoanh.trim().toLowerCase()}_${p.lo.trim().toLowerCase()}'
          : p.fullName.trim().toLowerCase();
      groupedByPlot.putIfAbsent(loKey, () => []).add(p);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (sheetCtx) {
        String query = '';
        final searchController = TextEditingController();

        return StatefulBuilder(
          builder: (dialogCtx, setSheetState) {
            final q = query.trim().toLowerCase();
            final qDigits = q.replaceAll(RegExp(r'[^0-9]'), '');

            List<List<ForestPlot>> matches = [];
            if (q.isNotEmpty) {
              matches = groupedByPlot.values.where((list) {
                final rep = list.first;
                final loLower = rep.lo.toLowerCase();
                final fullLower = rep.fullName.toLowerCase();
                final loDigits = rep.lo.replaceAll(RegExp(r'[^0-9]'), '');

                // 1. So khớp tên Lô hoặc số hiệu (ví dụ 313, 653)
                if (loLower.contains(q) || fullLower.contains(q)) return true;
                if (qDigits.isNotEmpty && loDigits.contains(qDigits)) return true;

                // 2. So khớp các thuộc tính bổ sung (TEN_LO, MALO, Name...)
                for (final p in list) {
                  for (final val in p.attributes.values) {
                    if (val.toLowerCase().contains(q)) return true;
                  }
                }

                // 3. So khớp khoảnh, tiểu khu, loại cây
                if (rep.khoanh.toLowerCase().contains(q) ||
                    rep.tieuKhu.toLowerCase().contains(q) ||
                    rep.loaiCay.toLowerCase().contains(q)) {
                  return true;
                }

                return false;
              }).toList();

              // Sắp xếp ưu tiên độ khớp chính xác
              matches.sort((a, b) {
                final aRep = a.first;
                final bRep = b.first;
                final aLo = aRep.lo.trim().toLowerCase();
                final bLo = bRep.lo.trim().toLowerCase();

                final aExact = aLo == q || aLo == 'lô $q' || aLo == 'lo $q';
                final bExact = bLo == q || bLo == 'lô $q' || bLo == 'lo $q';
                if (aExact && !bExact) return -1;
                if (!aExact && bExact) return 1;

                final aStart = aLo.startsWith(q) || aLo.startsWith('lô $q');
                final bStart = bLo.startsWith(q) || bLo.startsWith('lô $q');
                if (aStart && !bStart) return -1;
                if (!aStart && bStart) return 1;

                return aLo.compareTo(bLo);
              });
            } else {
              // Mẫu gợi ý các Lô trong Lớp 1 khi chưa nhập
              matches = groupedByPlot.values.take(20).toList();
            }

            final bottomInset = MediaQuery.of(sheetCtx).viewInsets.bottom;

            return Container(
              height: MediaQuery.of(sheetCtx).size.height * 0.78,
              padding: EdgeInsets.only(bottom: bottomInset),
              decoration: const BoxDecoration(
                color: Color(0xFFF9FBF9),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Thanh kéo handle bar
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 8),
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),

                  // Header & Search Box
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFF2E7D32), width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.green.withValues(alpha: 0.08),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: searchController,
                              autofocus: true,
                              textInputAction: TextInputAction.search,
                              onChanged: (text) {
                                setSheetState(() => query = text);
                              },
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF2E7D32), size: 22),
                                hintText: 'Nhập tên lô cần tìm (Ví dụ: 313, 653...)',
                                hintStyle: TextStyle(fontSize: 13.5, color: Colors.grey.shade400),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
                                suffixIcon: query.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded, size: 20, color: Colors.grey),
                                        onPressed: () {
                                          searchController.clear();
                                          setSheetState(() => query = '');
                                        },
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          child: const Text('Đóng', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                        ),
                      ],
                    ),
                  ),

                  // Thanh phạm vi: CHỈ TÌM TRONG LỚP 1
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2E7D32).withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.layers_rounded, size: 16, color: Color(0xFF1B5E20)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Phạm vi tìm kiếm: ${firstLayerName.isNotEmpty ? "Lớp đang mở - $firstLayerName" : "Chưa có lớp nào đang mở"} (${groupedByPlot.length} lô)',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Thanh tiêu đề gợi ý
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          query.isEmpty ? Icons.lightbulb_outline_rounded : Icons.filter_list_rounded,
                          size: 16,
                          color: const Color(0xFF2E7D32),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          query.isEmpty
                              ? 'Gợi ý danh sách Lô có sẵn (${groupedByPlot.length} lô):'
                              : 'Kết quả tìm kiếm (${matches.length} lô phù hợp):',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1, thickness: 0.8),

                  // Danh sách gợi ý
                  Expanded(
                    child: matches.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.search_off_rounded, size: 54, color: Colors.grey.shade400),
                                const SizedBox(height: 10),
                                Text(
                                  firstLayerPlots.isEmpty
                                      ? 'Không có lớp bản đồ nào đang mở (hoặc các lớp đã bị ẩn)'
                                      : 'Không tìm thấy lô nào khớp với "$query" trong lớp đang mở',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black54, fontSize: 14),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  firstLayerPlots.isEmpty
                                      ? 'Vui lòng vào Hồ sơ cán bộ -> Quản lý lớp bản đồ để bật lớp'
                                      : 'Hãy thử gõ lại số hiệu lô (ví dụ: 313 hoặc 653)',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            itemCount: matches.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 6),
                            itemBuilder: (ctx, i) {
                              final plotGroup = matches[i];
                              final rep = plotGroup.first;
                              final regionCount = GisCalculator.countDisjointRegions(plotGroup);
                              final totalArea = GisCalculator.calculateTotalLotArea(plotGroup);
                              final plotNameDisplay = rep.lo.trim().toLowerCase().startsWith('lô')
                                  ? rep.lo
                                  : (rep.lo.isNotEmpty ? 'Lô ${rep.lo}' : rep.fullName);

                              return Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade200),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.02),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                  leading: Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: rep.color.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: rep.color, width: 2),
                                    ),
                                    child: Center(
                                      child: regionCount > 1
                                          ? Text(
                                              '$regionCount',
                                              style: TextStyle(fontWeight: FontWeight.w900, color: Colors.green.shade900, fontSize: 17),
                                            )
                                          : const Icon(Icons.forest_rounded, size: 22, color: Color(0xFF1B5E20)),
                                    ),
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                plotNameDisplay,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.green.shade300),
                                        ),
                                        child: Text(
                                          '${totalArea.toStringAsFixed(2)} ha',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5, color: Color(0xFF1B5E20)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Khoảnh: ${rep.khoanh.isNotEmpty ? rep.khoanh : "---"} • TK: ${rep.tieuKhu.isNotEmpty ? rep.tieuKhu : "---"} • ${rep.loaiCay.isNotEmpty ? rep.loaiCay : rep.trangThaiRung}',
                                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                        ),
                                        if (rep.groupName.isNotEmpty && rep.groupName != 'Dữ liệu mặc định')
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2),
                                            child: Text(
                                              '📁 ${rep.groupName}',
                                              style: TextStyle(fontSize: 10.5, color: Colors.blueGrey.shade600),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  trailing: const Icon(Icons.near_me_rounded, color: Color(0xFF2E7D32), size: 22),
                                  onTap: () {
                                    Navigator.pop(sheetCtx);

                                    // Nếu nhóm đang bị ẩn -> Tự động bật nhóm lên
                                    if (_hiddenGroups.contains(rep.groupName)) {
                                      setState(() {
                                        _hiddenGroups.remove(rep.groupName);
                                      });
                                    }

                                    // TÍNH TOÀN BỘ BOUNDS CỦA TẤT CẢ CÁC VÙNG CỦA LÔ NÀY (HỖ TRỢ 3, 4... VÙNG)
                                    double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
                                    bool hasCoords = false;
                                    for (final p in plotGroup) {
                                      for (final pt in p.boundary) {
                                        hasCoords = true;
                                        if (pt.latitude < minLat) minLat = pt.latitude;
                                        if (pt.latitude > maxLat) maxLat = pt.latitude;
                                        if (pt.longitude < minLng) minLng = pt.longitude;
                                        if (pt.longitude > maxLng) maxLng = pt.longitude;
                                      }
                                    }

                                    // Tự động căn chỉnh Camera bao trọn toàn bộ các vùng của Lô
                                    if (hasCoords) {
                                      if ((maxLat - minLat).abs() < 0.00005 && (maxLng - minLng).abs() < 0.00005) {
                                        _mapController.move(LatLng(minLat, minLng), 17.0);
                                      } else {
                                        final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
                                        _mapController.fitCamera(
                                          CameraFit.bounds(
                                            bounds: bounds,
                                            padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 90),
                                            maxZoom: 17.5,
                                          ),
                                        );
                                      }
                                    }

                                    final regionCount = GisCalculator.countDisjointRegions(plotGroup);
                                    final totalArea = GisCalculator.calculateTotalLotArea(plotGroup);

                                    // Chọn và làm nổi bật toàn bộ các vùng của Lô
                                    setState(() {
                                      _highlightedPlotIds.clear();
                                      _highlightedPlotIds.addAll(plotGroup.map((p) => p.id));
                                      _highlightedPlotName = rep.lo.trim().isNotEmpty ? rep.lo : rep.fullName;
                                      _highlightedRegionCount = regionCount;
                                      _highlightedTotalArea = totalArea;
                                      _selectedPlot = rep;
                                    });

                                    // Mở thông tin chi tiết lô
                                    _showPlotDetailSheet(rep);

                                    _showToast('Đã bay đến $plotNameDisplay (${totalArea.toStringAsFixed(2)} ha)!');
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // TÌM KIẾM
  Widget _buildSearchResults() {
    final filtered = _plots.where((p) =>
        p.fullName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        p.loaiCay.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        p.trangThaiRung.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Card(
      elevation: 8,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: filtered.length,
          itemBuilder: (ctx, i) {
            final p = filtered[i];
            return ListTile(
              leading: CircleAvatar(backgroundColor: p.color, radius: 10),
              title: Text(p.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${p.trangThaiRung} • ${p.dienTich} ha'),
              onTap: () {
                setState(() => _searchQuery = '');
                _mapController.move(p.center, 16.5);
                _showPlotDetailSheet(p);
              },
            );
          },
        ),
      ),
    );
  }

  // CÁC NÚT ĐIỀU KHIỂN (ĐƯỢC ĐẶT CAO ĐỂ KHÔNG BỊ PHÍM HỆ THỐNG CHE)
  Widget _buildControlButtons() {
    final isPatrolling = _activePatrol != null && _activePatrol!.isActive;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Nút Tìm kiếm Lô rừng (Tìm kiếm thông minh & Gợi ý)
        FloatingActionButton.small(
          heroTag: 'search_plot_btn',
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1B5E20),
          tooltip: 'Tìm kiếm theo tên Lô (Ví dụ: 313, 653...)',
          onPressed: _openSearchPlotDialog,
          child: const Icon(Icons.search_rounded, size: 22),
        ),
        const SizedBox(height: 8),

        // Nút Tuần tra
        FloatingActionButton.small(
          heroTag: 'patrol_btn',
          backgroundColor: isPatrolling ? Colors.redAccent : Colors.white,
          foregroundColor: isPatrolling ? Colors.white : Colors.black87,
          tooltip: isPatrolling ? 'Dừng tuần tra' : 'Bắt đầu tuần tra rừng',
          onPressed: _togglePatrol,
          child: Icon(isPatrolling ? Icons.stop : Icons.directions_walk),
        ),
        const SizedBox(height: 8),

        // Nút Đánh dấu vi phạm (POI)
        FloatingActionButton.small(
          heroTag: 'poi_btn',
          backgroundColor: Colors.white,
          foregroundColor: Colors.red[800],
          tooltip: 'Đánh dấu điểm nóng vi phạm',
          onPressed: () => _openAddPoiDialog(),
          child: const Icon(Icons.add_alert),
        ),
        const SizedBox(height: 8),

        // Nút Đo đạc & Tạo Lô (Đo GPS thực địa hoặc Bấm điểm)
        FloatingActionButton.small(
          heroTag: 'add_plot_btn',
          backgroundColor: _mode == AppInteractionMode.gpsSurveyWalk
              ? Colors.cyanAccent
              : _mode == AppInteractionMode.digitizePlot
                  ? Colors.amber
                  : Colors.white,
          foregroundColor: Colors.black87,
          tooltip: _mode != AppInteractionMode.normal ? 'Đang đo đạc (Bấm để hủy)' : 'Đo đạc & Tạo Lô',
          onPressed: () {
            if (_mode == AppInteractionMode.gpsSurveyWalk || _mode == AppInteractionMode.digitizePlot) {
              setState(() {
                _mode = AppInteractionMode.normal;
                _digitizingPoints.clear();
                _selectedVertexIndex = null;
              });
              _showToast('Đã dừng chế độ đo đạc');
            } else {
              _showSurveyModeSelectionSheet();
            }
          },
          child: Icon(_mode == AppInteractionMode.gpsSurveyWalk
              ? Icons.directions_walk
              : _mode == AppInteractionMode.digitizePlot
                  ? Icons.touch_app
                  : Icons.straighten),
        ),
        const SizedBox(height: 8),

        // Nút Chia sẻ dữ liệu
        FloatingActionButton.small(
          heroTag: 'export_btn',
          backgroundColor: Colors.white,
          foregroundColor: Colors.teal[800],
          tooltip: 'Chia sẻ qua Zalo, Messenger, Bluetooth...',
          onPressed: _shareData,
          child: const Icon(Icons.share),
        ),
        const SizedBox(height: 8),

        // Nút GPS Trắc địa (Đặt trên cùng, to rõ, không bị che)
        FloatingActionButton(
          heroTag: 'gps_live_btn',
          backgroundColor: _isLiveGpsActive ? Colors.green[800] : const Color(0xFF2E7D32),
          foregroundColor: Colors.white,
          tooltip: 'Vị trí GPS Thực tế',
          onPressed: _isLocatingGps ? null : () async {
            await _requestAndGetRealLocation();
            _toggleLiveGps();
          },
          child: _isLocatingGps
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Icon(_isLiveGpsActive ? Icons.gps_fixed : Icons.my_location),
        ),
      ],
    );
  }

  // -------------------------------------------------------------
  // BẢNG QUẢN LÝ LỚP & TÔ MÀU VÙNG/NHÓM
  // -------------------------------------------------------------
  void _showLayerManagerSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
              ? MediaQuery.of(ctx).viewPadding.bottom
              : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 48.0);
          final safeBottom = bottomInset + 24.0;

          // Tổng hợp tất cả các nhóm từ cả _plots và _poiList theo thứ tự lớp đã lưu
          final List<String> allGroupNames = _getCurrentGroupOrder();

          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom),
            child: SafeArea(
              top: false,
              bottom: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                      const SizedBox(height: 14),
                      const Row(
                        children: [
                          Icon(Icons.layers, color: Color(0xFF1B5E20), size: 22),
                          SizedBox(width: 8),
                          Text('QUẢN LÝ LỚP & NHÓM DỮ LIỆU',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 1. NHÓM DỮ LIỆU ĐÃ NHẬP (BẬT / TẮT TỪNG NHÓM, ĐỔI MÀU NHÓM, TRÁNH NẰM CHỒNG LÊN NHAU)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'NHÓM DỮ LIỆU ĐÃ NHẬP (${allGroupNames.length})',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1B5E20)),
                                    ),
                                    const SizedBox(height: 2),
                                    const Text(
                                      'Lớp #1 nằm trên cùng, các lớp sau nằm dưới',
                                      style: TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: Colors.black54),
                                    ),
                                  ],
                                ),
                                if (allGroupNames.isNotEmpty)
                                  Row(
                                    children: [
                                      TextButton(
                                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                        onPressed: () {
                                          setState(() {
                                            _hiddenGroups.clear();
                                            _invalidatePlotCache();
                                          });
                                          _savePersistentData();
                                          setSheetState(() {});
                                          _showToast('Đã hiện tất cả các nhóm dữ liệu');
                                        },
                                        child: const Text('Hiện tất cả', style: TextStyle(fontSize: 11)),
                                      ),
                                      const SizedBox(width: 6),
                                      TextButton(
                                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                        onPressed: () {
                                          setState(() {
                                            _hiddenGroups.addAll(allGroupNames);
                                            _invalidatePlotCache();
                                          });
                                          _savePersistentData();
                                          setSheetState(() {});
                                          _showToast('Đã ẩn tất cả các nhóm dữ liệu');
                                        },
                                        child: const Text('Ẩn tất cả', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                            const Divider(height: 12),
                            if (allGroupNames.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('Chưa có nhóm dữ liệu nào được nạp', style: TextStyle(fontSize: 12, color: Colors.grey)),
                              )
                            else
                              ...allGroupNames.asMap().entries.map((entry) {
                                final index = entry.key;
                                final gName = entry.value;
                                final plotsInGroup = _plots.where((p) => p.groupName == gName).toList();
                                final poisInGroup = _poiList.where((p) => p.groupName == gName).toList();
                                final isHidden = _hiddenGroups.contains(gName);
                                final totalHa = plotsInGroup.fold<double>(0.0, (acc, p) => acc + p.dienTich);
                                final sampleColor = plotsInGroup.isNotEmpty
                                    ? plotsInGroup.first.color
                                    : (poisInGroup.isNotEmpty ? poisInGroup.first.color : const Color(0xFF2E7D32));

                                final overlaysInGroup = _rasterOverlays.where((o) => o.groupName == gName).toList();
                                String groupSub = '';
                                if (overlaysInGroup.isNotEmpty) {
                                  groupSub = 'Bản đồ ảnh nắn tọa độ • ${overlaysInGroup.length} lớp ảnh';
                                } else if (plotsInGroup.isNotEmpty && poisInGroup.isNotEmpty) {
                                  groupSub = '${plotsInGroup.length} Lô • ${totalHa.toStringAsFixed(1)} ha • ${poisInGroup.length} Mốc';
                                } else if (plotsInGroup.isNotEmpty) {
                                  groupSub = '${plotsInGroup.length} Lô • ${totalHa.toStringAsFixed(1)} ha';
                                } else {
                                  groupSub = '${poisInGroup.length} Điểm mốc ranh giới';
                                }

                                return Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isHidden ? Colors.grey.shade100 : Colors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: isHidden ? Colors.grey.shade300 : sampleColor.withValues(alpha: 0.5)),
                                    boxShadow: isHidden ? [] : [
                                      BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 2)),
                                    ],
                                  ),
                                  child: Row(
                                    children: [
                                      // Cụm di chuyển thứ tự Lớp (Lên / Xuống)
                                      Container(
                                        margin: const EdgeInsets.only(right: 4),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: index > 0
                                                  ? () {
                                                      final item = _datasetGroupOrder.removeAt(index);
                                                      _datasetGroupOrder.insert(index - 1, item);
                                                      _savePersistentData();
                                                      setState(() {});
                                                      setSheetState(() {});
                                                      _showToast('Đã di chuyển "$gName" lên vị trí #$index');
                                                    }
                                                  : null,
                                              child: Padding(
                                                padding: const EdgeInsets.all(2.0),
                                                child: Icon(
                                                  Icons.arrow_drop_up,
                                                  size: 24,
                                                  color: index > 0 ? const Color(0xFF2E7D32) : Colors.grey.shade300,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: index == 0
                                                    ? const Color(0xFF2E7D32)
                                                    : const Color(0xFF2E7D32).withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                '#${index + 1}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: index == 0 ? Colors.white : const Color(0xFF2E7D32),
                                                ),
                                              ),
                                            ),
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: index < allGroupNames.length - 1
                                                  ? () {
                                                      final item = _datasetGroupOrder.removeAt(index);
                                                      _datasetGroupOrder.insert(index + 1, item);
                                                      _savePersistentData();
                                                      setState(() {});
                                                      setSheetState(() {});
                                                      _showToast('Đã di chuyển "$gName" xuống vị trí #${index + 2}');
                                                    }
                                                  : null,
                                              child: Padding(
                                                padding: const EdgeInsets.all(2.0),
                                                child: Icon(
                                                  Icons.arrow_drop_down,
                                                  size: 24,
                                                  color: index < allGroupNames.length - 1 ? const Color(0xFF2E7D32) : Colors.grey.shade300,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Cụm di chuyển thứ tự Lớp (Lên / Xuống)
                                      Container(
                                        margin: const EdgeInsets.only(right: 4),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: index > 0
                                                  ? () {
                                                      final item = _datasetGroupOrder.removeAt(index);
                                                      _datasetGroupOrder.insert(index - 1, item);
                                                      _savePersistentData();
                                                      setState(() {});
                                                      setSheetState(() {});
                                                      _showToast('Đã di chuyển "$gName" lên vị trí #$index');
                                                    }
                                                  : null,
                                              child: Padding(
                                                padding: const EdgeInsets.all(2.0),
                                                child: Icon(
                                                  Icons.arrow_drop_up,
                                                  size: 24,
                                                  color: index > 0 ? const Color(0xFF2E7D32) : Colors.grey.shade300,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: index == 0
                                                    ? const Color(0xFF2E7D32)
                                                    : const Color(0xFF2E7D32).withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                '#${index + 1}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: index == 0 ? Colors.white : const Color(0xFF2E7D32),
                                                ),
                                              ),
                                            ),
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: index < allGroupNames.length - 1
                                                  ? () {
                                                      final item = _datasetGroupOrder.removeAt(index);
                                                      _datasetGroupOrder.insert(index + 1, item);
                                                      _savePersistentData();
                                                      setState(() {});
                                                      setSheetState(() {});
                                                      _showToast('Đã di chuyển "$gName" xuống vị trí #${index + 2}');
                                                    }
                                                  : null,
                                              child: Padding(
                                                padding: const EdgeInsets.all(2.0),
                                                child: Icon(
                                                  Icons.arrow_drop_down,
                                                  size: 24,
                                                  color: index < allGroupNames.length - 1 ? const Color(0xFF2E7D32) : Colors.grey.shade300,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Nút Bật / Tắt nhóm (Eye icon)
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                        icon: Icon(
                                          isHidden ? Icons.visibility_off : Icons.visibility,
                                          color: isHidden ? Colors.grey : const Color(0xFF2E7D32),
                                          size: 22,
                                        ),
                                        tooltip: isHidden ? 'Bấm để hiện nhóm này' : 'Bấm để ẩn nhóm này (tránh đè nhau)',
                                        onPressed: () {
                                          setState(() {
                                            if (isHidden) {
                                              _hiddenGroups.remove(gName);
                                            } else {
                                              _hiddenGroups.add(gName);
                                            }
                                            _invalidatePlotCache();
                                          });
                                          _savePersistentData();
                                          setSheetState(() {});
                                          _showToast(isHidden ? 'Đã hiển thị nhóm "$gName"' : 'Đã ẩn nhóm "$gName" khỏi bản đồ');
                                        },
                                      ),
                                      const SizedBox(width: 4),

                                      // Thông tin nhóm
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              gName,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                                color: isHidden ? Colors.grey.shade600 : Colors.black87,
                                                decoration: isHidden ? TextDecoration.lineThrough : null,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              groupSub,
                                              style: TextStyle(fontSize: 11, color: isHidden ? Colors.grey : Colors.grey.shade600),
                                            ),
                                            if (overlaysInGroup.isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(Icons.opacity, size: 13, color: Colors.blueGrey),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    '${(overlaysInGroup.first.opacity * 100).toInt()}%',
                                                    style: const TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold),
                                                  ),
                                                  Expanded(
                                                    child: SliderTheme(
                                                      data: SliderTheme.of(context).copyWith(
                                                        trackHeight: 2,
                                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                                      ),
                                                      child: Slider(
                                                        value: overlaysInGroup.first.opacity,
                                                        min: 0.1,
                                                        max: 1.0,
                                                        activeColor: const Color(0xFF2E7D32),
                                                        onChanged: (val) {
                                                          setState(() {
                                                            for (var o in overlaysInGroup) {
                                                              o.opacity = val;
                                                            }
                                                          });
                                                          setSheetState(() {});
                                                          _savePersistentData();
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                  IconButton(
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                                    icon: const Icon(Icons.tune, size: 16, color: Color(0xFF2E7D32)),
                                                    tooltip: 'Nắn chỉnh tọa độ lớp ảnh',
                                                    onPressed: () {
                                                      _showRasterOverlayCalibrationDialog(overlaysInGroup.first, () {
                                                        setSheetState(() {});
                                                      });
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),

                                      // Nút đổi màu nhóm
                                      GestureDetector(
                                        onTap: () {
                                          _openColorPickerForDataset(gName, () {
                                            setSheetState(() {});
                                          });
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: sampleColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: sampleColor, width: 1.5),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              CircleAvatar(backgroundColor: sampleColor, radius: 6),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.palette, size: 14, color: Colors.grey),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),

                                      // Nút zoom tới nhóm
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                        icon: const Icon(Icons.center_focus_strong, size: 20, color: Color(0xFF1E88E5)),
                                        tooltip: 'Đưa bản đồ tới nhóm này',
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          final overlaysInGroup = _rasterOverlays.where((o) => o.groupName == gName).toList();
                                          if (overlaysInGroup.isNotEmpty) {
                                            if (isHidden) {
                                              setState(() {
                                                _hiddenGroups.remove(gName);
                                                _invalidatePlotCache();
                                              });
                                              _savePersistentData();
                                            }
                                            _mapController.move(overlaysInGroup.first.center, 13.0);
                                            _showToast('Đã di chuyển tới Bản đồ ảnh "$gName"');
                                          } else if (plotsInGroup.isNotEmpty) {
                                            if (isHidden) {
                                              setState(() {
                                                _hiddenGroups.remove(gName);
                                                _invalidatePlotCache();
                                              });
                                              _savePersistentData();
                                            }
                                            _mapController.move(plotsInGroup.first.center, 15.0);
                                            _showToast('Đã di chuyển tới nhóm "$gName"');
                                          } else if (poisInGroup.isNotEmpty) {
                                            if (isHidden) {
                                              setState(() {
                                                _hiddenGroups.remove(gName);
                                                _invalidatePlotCache();
                                              });
                                              _savePersistentData();
                                            }
                                            _mapController.move(poisInGroup.first.position, 15.0);
                                            _showToast('Đã di chuyển tới nhóm "$gName"');
                                          }
                                        },
                                      ),

                                      // Nút xóa nhóm
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                        tooltip: 'Xóa nhóm dữ liệu này',
                                        onPressed: () {
                                          final itemCount = plotsInGroup.isNotEmpty
                                              ? '${plotsInGroup.length} Lô'
                                              : '${poisInGroup.length} Mốc';
                                          showDialog(
                                            context: context,
                                            builder: (delCtx) => AlertDialog(
                                              title: const Text('Xác nhận xóa nhóm dữ liệu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                              content: Text('Bạn có chắc chắn muốn xóa toàn bộ $itemCount thuộc nhóm "$gName"?'),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text('Hủy')),
                                                ElevatedButton(
                                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                                  onPressed: () {
                                                    setState(() {
                                                      _plots.removeWhere((p) => p.groupName == gName);
                                                      _poiList.removeWhere((p) => p.groupName == gName);
                                                      _rasterOverlays.removeWhere((o) => o.groupName == gName);
                                                      _hiddenGroups.remove(gName);
                                                      _datasetGroupOrder.remove(gName);
                                                      _invalidatePlotCache();
                                                    });
                                                    _savePersistentData();
                                                    Navigator.pop(delCtx);
                                                    setSheetState(() {});
                                                    _showToast('Đã xóa nhóm "$gName" khỏi ứng dụng');
                                                  },
                                                  child: const Text('Xóa'),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              }),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Mục cấu hình Tô màu & Nhãn nâng cao
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAdvancedLabelSheet();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6A1B9A).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF6A1B9A).withValues(alpha: 0.4), width: 1.5),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.style, color: Color(0xFF6A1B9A), size: 24),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('TÔ MÀU & NHÃN NÂNG CAO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF6A1B9A))),
                                    Text('Cấu hình Tử số / Mẫu số, cỡ chữ, viền chữ, hiện từ Z', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, color: Color(0xFF6A1B9A)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Mục Đồng bộ Đám mây (Firebase)
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showCloudSyncDialog();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1976D2).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF1976D2).withValues(alpha: 0.4), width: 1.5),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.cloud_sync, color: Color(0xFF1976D2), size: 24),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('ĐỒNG BỘ ĐÁM MÂY (FIREBASE)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1976D2))),
                                    Text('Tự đẩy lên server, lưu cache máy khi mất mạng', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, color: Color(0xFF1976D2)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Mục Tải dữ liệu từ Cloud (Firebase)
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showFirebaseCloudDownloadDialog();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D47A1).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF0D47A1).withValues(alpha: 0.4), width: 1.5),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.cloud_download, color: Color(0xFF0D47A1), size: 24),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('TẢI DỮ LIỆU TỪ CLOUD (FIREBASE)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0D47A1))),
                                    Text('Chọn file/nhóm dữ liệu đã đồng bộ trước đó để nạp về máy', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, color: Color(0xFF0D47A1)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Bản đồ nền
                      const Text('Bản đồ nền:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          ChoiceChip(
                            label: const Text('Google Hybrid (Vệ tinh)'),
                            selected: _baseLayer == MapBaseLayer.googleHybrid,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.googleHybrid);
                              setSheetState(() {});
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Google Vệ tinh thuần'),
                            selected: _baseLayer == MapBaseLayer.googleSatellite,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.googleSatellite);
                              setSheetState(() {});
                            },
                          ),
                          ChoiceChip(
                            label: const Text('ESRI Vệ tinh'),
                            selected: _baseLayer == MapBaseLayer.esriSatellite,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.esriSatellite);
                              setSheetState(() {});
                            },
                          ),
                          ChoiceChip(
                            label: const Text('ESRI Clarity (Sắc nét)'),
                            selected: _baseLayer == MapBaseLayer.esriClarity,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.esriClarity);
                              setSheetState(() {});
                            },
                          ),
                          ChoiceChip(
                            label: const Text('OpenTopo Địa hình'),
                            selected: _baseLayer == MapBaseLayer.openTopo,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.openTopo);
                              setSheetState(() {});
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Đường phố OSM'),
                            selected: _baseLayer == MapBaseLayer.openStreetMap,
                            onSelected: (val) {
                              setState(() => _baseLayer = MapBaseLayer.openStreetMap);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1B5E20),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 11),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text(
                                'Làm mới gạch',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              onPressed: () {
                                _refreshSatelliteTiles();
                                Navigator.pop(ctx);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00796B),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 11),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.download_for_offline_rounded, size: 18),
                              label: const Text(
                                'Tải Offline',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showDownloadOfflineMapDialog();
                              },
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),

                      // Đổi màu theo nhóm trạng thái
                      const Text('Tô màu / Đổi màu theo trạng thái rừng:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ActionChip(
                            avatar: const CircleAvatar(backgroundColor: Color(0xFF1B5E20), radius: 8),
                            label: const Text('Rừng tự nhiên'),
                            onPressed: () => _openColorPickerForGroup('Rừng tự nhiên giàu'),
                          ),
                          ActionChip(
                            avatar: const CircleAvatar(backgroundColor: Color(0xFF43A047), radius: 8),
                            label: const Text('Rừng trồng Keo'),
                            onPressed: () => _openColorPickerForGroup('Rừng trồng sản xuất'),
                          ),
                          ActionChip(
                            avatar: const CircleAvatar(backgroundColor: Color(0xFFFB8C00), radius: 8),
                            label: const Text('Rừng Cao su'),
                            onPressed: () => _openColorPickerForGroup('Rừng trồng cao su'),
                          ),
                          ActionChip(
                            avatar: const CircleAvatar(backgroundColor: Color(0xFF8D6E63), radius: 8),
                            label: const Text('Đất trống tái sinh'),
                            onPressed: () => _openColorPickerForGroup('Đất trống có cây tái sinh'),
                          ),
                          ActionChip(
                            avatar: const CircleAvatar(backgroundColor: Color(0xFF00897B), radius: 8),
                            label: const Text('Rừng phòng hộ'),
                            onPressed: () => _openColorPickerForGroup('Rừng phòng hộ đầu nguồn'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  String _formatAttributeKey(String key) {
    final clean = key.toLowerCase().trim();
    switch (clean) {
      case 'id_lo':
      case 'idlo':
        return 'Mã định danh Lô';
      case 'id_lo_2_cap':
      case 'idlo2cap':
        return 'Mã Lô (2 cấp)';
      case 'cty':
      case 'cong_ty':
        return 'Công ty quản lý';
      case 'ntruong':
      case 'nong_truong':
        return 'Nông trường';
      case 'ten_doi':
        return 'Tên Đội sản xuất';
      case 'don_vi':
        return 'Đơn vị / Đội';
      case 'du_an':
        return 'Dự án';
      case 'tenlo':
      case 'ten_lo':
      case 'so_lo':
        return 'Số hiệu Lô';
      case 'hdat':
      case 'hang_dat':
        return 'Hạng đất';
      case 'cao_trinh':
        return 'Cao trình (m)';
      case 'pp_trồng':
      case 'pp_trong':
      case 'phuong_phap_trong':
        return 'Phương pháp trồng';
      case 'khoảng_c':
      case 'khoang_c':
      case 'khoang_cach_trong':
        return 'Khoảng cách cây';
      case 'giong':
      case 'giong_cay':
        return 'Giống cây';
      case 'năm_cạo':
      case 'nam_cao':
      case 'nam_mo_cao':
        return 'Năm mở cạo';
      case 'chế_đ':
      case 'che_d':
        return 'Chế độ cạo';
      case 'namtrong':
      case 'nam_trong':
        return 'Năm trồng';
      case 'ct_tb':
        return 'Vòng thân TB (cm)';
      case 'mật_đ':
      case 'mat_d':
      case 'mật_đ_1':
      case 'mat_d_1':
      case 'mat_do':
        return 'Mật độ (cây/ha)';
      case 'mat_do_cay_cao':
        return 'Mật độ cây cạo (cây/ha)';
      case 'cay_cao_hh':
        return 'Cây cạo hiện hữu';
      case 'tuoi_cao_2025':
        return 'Tuổi cạo';
      case 'tt_mat_cao_2025':
        return 'TT mặt cạo';
      case 'nang_suat_2025':
        return 'Năng suất';
      case 'xep_hang_2025':
        return 'Xếp hạng';
      case 'hiện_tr':
      case 'hien_tr':
      case 'hien_trang':
        return 'Hiện trạng';
      case 'phân_lo':
      case 'phan_lo':
        return 'Phân loại hạng';
      case 'ht_vườn':
      case 'ht_vuon':
        return 'Hiện trạng vườn';
      case 'dien_tich1':
      case 'dien_tich':
      case 'dien_tic_1':
      case 'dt':
        return 'Diện tích hồ sơ (ha)';
      case 'fid':
        return 'Mã FID';
      case 'ghi_chu':
      case 'note':
        return 'Ghi chú';
      case 'shape_area':
      case 'shape__are':
        return 'Diện tích (m²)';
      case 'shape_leng':
      case 'shape__len':
        return 'Chu vi (m)';
      default:
        return key;
    }
  }

  /// Thứ tự ưu tiên sắp xếp thuộc tính hồ sơ chuẩn lâm nghiệp / cao su từ trên xuống dưới (chuẩn theo Hình 1)
  int _getAttributeRank(String rawKey) {
    final k = rawKey.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
    if (k == 'idlo' || k == 'idlo2cap' || k == 'malo') return 10;
    if (k == 'cty' || k == 'congty' || k == 'duan') return 20;
    if (k == 'ntruong' || k == 'nongtruong' || k == 'tendoi' || k == 'donvi' || k == 'doi' || k == 'khoanh') return 30;
    if (k == 'tenlo' || k == 'solo' || k == 'lo') return 40;
    if (k == 'hdat' || k == 'hangdat') return 50;
    if (k == 'pptrồng' || k == 'pptrong' || k == 'phuongphaptrong') return 60;
    if (k == 'khoảngc' || k == 'khoangc' || k == 'khoangcachtrong') return 70;
    if (k == 'giong' || k == 'giongcay' || k == 'loaicay') return 80;
    if (k == 'chếđ' || k == 'ched' || k == 'chedocao') return 90;
    if (k == 'namtrong') return 100;
    if (k == 'cttb' || k == 'caotrinh' || k == 'vongthan') return 110;
    if (k == 'mậtđ' || k == 'matd' || k == 'matdo') return 120;
    if (k == 'dientich_') return 130;
    if (k == 'hiệntr' || k == 'hientr' || k == 'ttmatcao2025' || k == 'ttmatcao' || k == 'hientrang' || k == 'trangthai') return 140;
    if (k == 'phânlo' || k == 'phanlo' || k == 'xephang2025' || k == 'xephang') return 150;
    if (k == 'nămcạo' || k == 'namcao' || k == 'nămmở' || k == 'nammo' || k == 'nammo_' || k == 'nammocao') return 160;
    if (k == 'tuoicao2025' || k == 'tuoicao') return 170;
    if (k == 'mậtđ1' || k == 'matd1' || k == 'matdocaycao') return 180;
    if (k == 'caycaohh' || k == 'caycao') return 190;
    if (k == 'nangsuat2025' || k == 'nangsuat') return 200;
    if (k == 'htvườn' || k == 'htvuon') return 210;
    if (k == 'namchuyen') return 220;
    if (k == 'chuvi' || k == 'shapeleng' || k == 'shapelen') return 230;
    if (k == 'dientich1' || k == 'dt' || k == 'dientich') return 240;
    if (k == 'fid') return 250;
    if (k == 'ghichu' || k == 'note') return 260;
    return 300;
  }

  // BẢNG CHI TIẾT LÔ RỪNG
  void _showPlotDetailSheet(ForestPlot plot) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
            ? MediaQuery.of(ctx).viewPadding.bottom
            : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 48.0);
        final safeBottom = bottomInset + 24.0;
        final cleanTrangThai = plot.trangThaiRung.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
        final cleanNote = plot.note.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();

        // 1. Lấy danh sách thuộc tính (từ attributes hoặc trích xuất tự động từ note nếu trước đó note bị dồn chuỗi phẳng)
        Map<String, String> effectiveAttributes = Map<String, String>.from(plot.attributes);
        if (effectiveAttributes.isEmpty && cleanNote.isNotEmpty) {
          effectiveAttributes = KmlParser.extractAttributesFromRawNote(cleanNote);
        }

        // 2. Sắp xếp thuộc tính BẮT BUỘC theo đúng thứ tự logic từ trên xuống dưới như Hình 1
        final sortedEntries = effectiveAttributes.entries.toList()
          ..sort((a, b) {
            final rankA = _getAttributeRank(a.key);
            final rankB = _getAttributeRank(b.key);
            if (rankA != rankB) return rankA.compareTo(rankB);
            return a.key.compareTo(b.key);
          });

        // 3. Suy luận thông minh các trường hiển thị tiêu đề nếu trước đó đang ở giá trị mặc định
        String displayTitle = plot.fullName;
        final candidateTenLo = effectiveAttributes['TEN_LO'] ?? effectiveAttributes['tenlo'];
        final candidateDonVi = effectiveAttributes['DON_VI'] ?? effectiveAttributes['ntruong'] ?? effectiveAttributes['TEN_DOI'];
        final candidateCTy = effectiveAttributes['cTy'] ?? (effectiveAttributes.containsKey('ID_LO_2_CAP') ? '08Đồng Nai Kratie' : null);

        if (candidateTenLo != null && (plot.fullName.startsWith('KMZ -') || plot.fullName.startsWith('Lô '))) {
          if (candidateCTy != null && candidateDonVi != null) {
            displayTitle = '$candidateCTy - $candidateDonVi - $candidateTenLo';
          } else if (candidateDonVi != null) {
            displayTitle = '$candidateDonVi - $candidateTenLo';
          } else {
            displayTitle = 'Lô $candidateTenLo';
          }
        }

        String displayChuRung = plot.chuRung;
        if (displayChuRung == 'Nhập từ KMZ/KML' && candidateCTy != null) {
          displayChuRung = candidateCTy;
        }

        String displayTrangThai = cleanTrangThai;
        final rawHt = effectiveAttributes['Hiện_tr'] ?? effectiveAttributes['TT_MAT_CAO_2025'];
        if (displayTrangThai.isEmpty || displayTrangThai == 'Rừng quy hoạch KMZ' || displayTrangThai == 'Rừng quy hoạch') {
          if (rawHt != null) {
            displayTrangThai = (rawHt == 'CS.KD' || rawHt.startsWith('BO-'))
                ? 'Cao su kinh doanh ($rawHt)'
                : rawHt;
          }
        }

        String displayLoaiCay = plot.loaiCay;
        final rawGiong = effectiveAttributes['GIONG'] ?? effectiveAttributes['giong'];
        if (displayLoaiCay == 'Theo hồ sơ KMZ' && rawGiong != null) {
          displayLoaiCay = rawGiong.toLowerCase().startsWith('cao su') ? rawGiong : 'Cao su giống $rawGiong';
        }

        int? displayNamTrong = plot.namTrong;
        final rawNamTrong = effectiveAttributes['NAM_TRONG'] ?? effectiveAttributes['namtrong'];
        if (displayNamTrong == null && rawNamTrong != null) {
          displayNamTrong = double.tryParse(rawNamTrong)?.toInt();
        }

        // Kiểm tra xem cleanNote có phải chỉ là chuỗi thuộc tính thô hay không
        final isRawDumpNote = effectiveAttributes.isNotEmpty &&
            (cleanNote.startsWith('fid ') || cleanNote.contains('TEN_LO') || cleanNote.contains('ID_LO'));

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom),
          child: SafeArea(
            top: false,
            bottom: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(displayTitle,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _openColorPickerForPlot(plot);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: plot.color.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: plot.color, width: 1.5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(backgroundColor: plot.color, radius: 6),
                                const SizedBox(width: 6),
                                Text(
                                  () {
                                    final siblingPlots = plot.lo.trim().isNotEmpty
                                        ? _plots.where((p) => p.groupName == plot.groupName && p.lo == plot.lo).toList()
                                        : null;
                                    final displayPieceArea = GisCalculator.getPlotPieceArea(plot, allPlotsInLot: siblingPlots);
                                    return '${displayPieceArea.toStringAsFixed(2)} ha';
                                  }(),
                                  style: TextStyle(fontWeight: FontWeight.bold, color: plot.color, fontSize: 15),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.color_lens, size: 14, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildDetailItem(Icons.folder_shared, 'Nhóm dữ liệu:', plot.groupName),
                    _buildDetailItem(Icons.square_foot_rounded, 'Diện tích mảnh này:', () {
                      final siblingPlots = plot.lo.trim().isNotEmpty
                          ? _plots.where((p) => p.groupName == plot.groupName && p.lo == plot.lo).toList()
                          : null;
                      final displayPieceArea = GisCalculator.getPlotPieceArea(plot, allPlotsInLot: siblingPlots);
                      return '${displayPieceArea.toStringAsFixed(2)} ha (${(displayPieceArea * 10000).toStringAsFixed(0)} m²)';
                    }()),
                    () {
                      final siblingPlots = _plots.where((p) => p.groupName == plot.groupName && p.lo == plot.lo && p.lo.isNotEmpty).toList();
                      if (siblingPlots.length > 1) {
                        final totalLotArea = GisCalculator.calculateTotalLotArea(siblingPlots);
                        return _buildDetailItem(Icons.layers_rounded, 'Tổng cả Lô:', '${totalLotArea.toStringAsFixed(2)} ha');
                      }
                      return const SizedBox.shrink();
                    }(),
                    _buildDetailItem(Icons.nature_people, 'Chủ rừng:', displayChuRung),
                    _buildDetailItem(Icons.forest, 'Trạng thái:', displayTrangThai.isNotEmpty ? displayTrangThai : 'Rừng quy hoạch'),
                    _buildDetailItem(Icons.eco, 'Loài cây / Giống:', displayLoaiCay),
                    if (displayNamTrong != null)
                      _buildDetailItem(Icons.calendar_today, 'Năm trồng:', '$displayNamTrong'),
                    if (plot.truLuong != null)
                      _buildDetailItem(Icons.stacked_bar_chart, 'Trữ lượng:', '${plot.truLuong} m³/ha'),

                    // Hiển thị thuộc tính trích xuất từ KML/KMZ sắp xếp chuẩn xác như Hình 1
                    if (sortedEntries.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey[200]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.list_alt, size: 16, color: Color(0xFF2E7D32)),
                                const SizedBox(width: 6),
                                Text(
                                  'Thông tin thuộc tính hồ sơ (${sortedEntries.length})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF2E7D32)),
                                ),
                              ],
                            ),
                            const Divider(height: 16),
                            ...sortedEntries.map((entry) {
                              final label = _formatAttributeKey(entry.key);
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2.5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 140,
                                    child: Text(
                                      label,
                                      style: TextStyle(fontSize: 12, color: Colors.grey[700], fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      entry.value.isEmpty ? '—' : entry.value,
                                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                  if (!isRawDumpNote && cleanNote.isNotEmpty) ...[
                    _buildDetailItem(Icons.note_alt_outlined, 'Ghi chú:', cleanNote),
                  ],

                    const SizedBox(height: 24),
                    // HÀNG NÚT BẤM (ĐƯỢC ĐẨY CAO TRÁNH THANH ĐIỀU HƯỚNG ẢNH HƯỞNG)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purple[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _startEditingPlot(plot);
                            },
                            icon: const Icon(Icons.edit, size: 18),
                            label: const Text('Nắn sửa ranh giới'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber[800],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openColorPickerForPlot(plot);
                          },
                          icon: const Icon(Icons.palette, size: 18),
                          label: const Text('Đổi màu Lô'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showPoiDetailSheet(ForestPoi poi) {
    final vn2000 = Vn2000Converter.toVN2000(poi.position);
    final latDms = Vn2000Converter.toDMS(poi.position.latitude, true);
    final lngDms = Vn2000Converter.toDMS(poi.position.longitude, false);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewPadding.bottom > 0
            ? MediaQuery.of(ctx).viewPadding.bottom
            : (MediaQuery.of(ctx).padding.bottom > 0 ? MediaQuery.of(ctx).padding.bottom : 48.0);
        final safeBottom = bottomInset + 24.0;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom),
          child: SafeArea(
            top: false,
            bottom: true,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: poi.color.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(poi.icon, color: poi.color, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(poi.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 2),
                            Text('${poi.typeName} • Mức độ: ${poi.severity}',
                                style: TextStyle(color: poi.color, fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Tọa độ chi tiết WGS-84 và VN-2000
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('TỌA ĐỘ VỊ TRÍ ĐÃ LƯU',
                            style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('WGS-84: X: ${poi.position.latitude.toStringAsFixed(6)}; Y: ${poi.position.longitude.toStringAsFixed(6)}',
                            style: const TextStyle(
                                color: Color(0xFF69F0AE),
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold)),
                        Text('DMS: $latDms, $lngDms',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
                        Text('VN-2000: X: ${vn2000['x']!.toStringAsFixed(1)} m; Y: ${vn2000['y']!.toStringAsFixed(1)} m',
                            style: const TextStyle(
                                color: Color(0xFF81D4FA),
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (poi.description.isNotEmpty)
                    _buildDetailItem(Icons.description, 'Mô tả:', poi.description),
                  _buildDetailItem(
                    Icons.access_time,
                    'Thời gian ghi nhận:',
                    '${poi.timestamp.hour.toString().padLeft(2, '0')}:${poi.timestamp.minute.toString().padLeft(2, '0')} - Ngày ${poi.timestamp.day}/${poi.timestamp.month}/${poi.timestamp.year}',
                  ),

                  // Trạng thái nhắc nhở / Báo thức
                  _buildDetailItem(
                    Icons.alarm,
                    'Báo thức / Nhắc nhở:',
                    poi.reminderEnabled
                        ? (poi.reminderTime != null
                            ? 'Bật (Báo lúc ${poi.reminderTime!.hour.toString().padLeft(2, '0')}:${poi.reminderTime!.minute.toString().padLeft(2, '0')} ngày ${poi.reminderTime!.day}/${poi.reminderTime!.month})'
                            : 'Đang bật')
                        : 'Đang tắt',
                  ),
                  if (poi.reminderEnabled && poi.proximityAlert)
                    _buildDetailItem(Icons.near_me, 'Cảnh báo cự ly:', 'Bật cảnh báo khi tuần tra đến gần (<100m)'),

                  const SizedBox(height: 18),
                  Row(
                    children: [
                      // Nút Xóa điểm
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red[700],
                          side: BorderSide(color: Colors.red[300]!),
                        ),
                        onPressed: () {
                          showDialog(
                            context: ctx,
                            builder: (dCtx) => AlertDialog(
                              title: const Text('Xác nhận xóa điểm'),
                              content: Text('Bạn có chắc chắn muốn xóa điểm "${poi.title}" khỏi bản đồ không?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Hủy')),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                  onPressed: () {
                                    setState(() => _poiList.removeWhere((p) => p.id == poi.id));
                                    _savePersistentData();
                                    Navigator.pop(dCtx);
                                    Navigator.pop(ctx);
                                    _showToast('Đã xóa điểm "${poi.title}"');
                                  },
                                  child: const Text('Xóa'),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete, size: 16),
                        label: const Text('Xóa điểm'),
                      ),
                      const Spacer(),
                      // Nút Dẫn đường tới vị trí
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _mapController.move(poi.position, 16.5);
                          _showToast('Đang đưa bản đồ tới vị trí "${poi.title}"');
                        },
                        icon: const Icon(Icons.location_searching, size: 16),
                        label: const Text('Đến vị trí'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailItem(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 6),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, color: Colors.black87))),
        ],
      ),
    );
  }

  /// DIALOG CHỌN FILE VÀ TẢI DỮ LIỆU TỪ FIREBASE SERVER VỀ MÁY
  void _showFirebaseCloudDownloadDialog() async {
    final syncService = FirebaseSyncService();
    await syncService.loadConfig();

    if (syncService.config.url.trim().isEmpty) {
      _showToast('Chưa cấu hình URL Firebase. Vui lòng mở mục Đồng bộ để nhập URL!');
      _showCloudSyncDialog();
      return;
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bCtx) {
        bool isLoading = true;
        bool isDownloading = false;
        String statusText = 'Đang kết nối server và lấy danh sách file...';
        List<FirebaseDatasetItem> datasets = [];
        final Set<String> selectedKeys = {};
        bool replaceExisting = true;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void loadDatasets() async {
              setSheetState(() {
                isLoading = true;
                statusText = 'Đang kết nối Firebase và tìm kiếm các file...';
              });
              final items = await syncService.fetchDetailedDatasets();
              if (ctx.mounted) {
                setSheetState(() {
                  isLoading = false;
                  datasets = items;
                  if (datasets.isNotEmpty && selectedKeys.isEmpty) {
                    selectedKeys.add(datasets.first.key);
                  }
                });
              }
            }

            if (isLoading && datasets.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) => loadDatasets());
            }

            String formatDateTime(DateTime? dt) {
              if (dt == null) return 'Chưa rõ';
              final h = dt.hour.toString().padLeft(2, '0');
              final m = dt.minute.toString().padLeft(2, '0');
              final d = dt.day.toString().padLeft(2, '0');
              final mo = dt.month.toString().padLeft(2, '0');
              final y = dt.year;
              return '$h:$m $d/$mo/$y';
            }

            Future<void> executeDownload(List<FirebaseDatasetItem> targets) async {
              if (targets.isEmpty) {
                _showToast('Vui lòng chọn ít nhất 1 file để tải về!');
                return;
              }

              setSheetState(() {
                isDownloading = true;
                statusText = 'Đang tải dữ liệu từ Firebase về máy...';
              });

              int totalDownloadedPlots = 0;
              int totalDownloadedPois = 0;
              final List<ForestPlot> allNewPlots = [];
              final List<ForestPoi> allNewPois = [];
              final Set<String> groupsUpdated = {};

              for (var item in targets) {
                setSheetState(() {
                  statusText = 'Đang tải file "${item.displayName}"...';
                });

                final data = await syncService.pullDataset(item.key, customPath: item.path);
                if (data != null) {
                  final rawPlots = data['plots'] as List<dynamic>? ?? [];
                  final rawPois = data['pois'] as List<dynamic>? ?? [];
                  final gName = (data['groupName'] as String?)?.trim().isNotEmpty == true
                      ? (data['groupName'] as String).trim()
                      : item.displayName;

                  final dlPlots = rawPlots.map((e) => ForestPlot.fromMap(e as Map<String, dynamic>)).toList();
                  final dlPois = rawPois.map((e) => ForestPoi.fromMap(e as Map<String, dynamic>)).toList();

                  allNewPlots.addAll(dlPlots);
                  allNewPois.addAll(dlPois);
                  groupsUpdated.add(gName);
                  totalDownloadedPlots += dlPlots.length;
                  totalDownloadedPois += dlPois.length;
                }
              }

              if (mounted) {
                setState(() {
                  if (replaceExisting) {
                    for (var g in groupsUpdated) {
                      _plots.removeWhere((p) => p.groupName == g);
                      _poiList.removeWhere((p) => p.groupName == g);
                      _hiddenGroups.remove(g);
                    }
                  }
                  _plots.addAll(allNewPlots);
                  _poiList.addAll(allNewPois);
                  for (var g in groupsUpdated) {
                    _hiddenGroups.remove(g);
                  }
                });

                await _savePersistentData();

                if (allNewPlots.isNotEmpty) {
                  _mapController.move(allNewPlots.first.center, 15.0);
                }
              }

              if (bCtx.mounted) {
                Navigator.pop(bCtx);
              }

              _showToast(
                'Tải thành công $totalDownloadedPlots Lô, $totalDownloadedPois Mốc từ ${targets.length} file về bản đồ!',
              );
            }

            final safeBottom = MediaQuery.of(ctx).padding.bottom + 16.0;

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.fromLTRB(16, 14, 16, safeBottom),
              child: SafeArea(
                top: false,
                bottom: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.88,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const CircleAvatar(
                            backgroundColor: Color(0xFFE3F2FD),
                            radius: 18,
                            child: Icon(Icons.cloud_download, color: Color(0xFF1976D2), size: 22),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'TẢI DỮ LIỆU TỪ FIREBASE',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1976D2),
                                  ),
                                ),
                                Text(
                                  'Chọn file / nhóm dữ liệu đã đồng bộ để nạp lên bản đồ',
                                  style: TextStyle(fontSize: 11.5, color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh, color: Color(0xFF1976D2)),
                            tooltip: 'Làm mới danh sách',
                            onPressed: isLoading || isDownloading ? null : loadDatasets,
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.grey),
                            onPressed: isDownloading ? null : () => Navigator.pop(bCtx),
                          ),
                        ],
                      ),
                      const Divider(height: 16),

                      if (isLoading)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(color: Color(0xFF1976D2)),
                                const SizedBox(height: 16),
                                Text(statusText, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                              ],
                            ),
                          ),
                        )
                      else if (datasets.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.cloud_off, size: 54, color: Colors.grey),
                                const SizedBox(height: 12),
                                const Text(
                                  'Chưa tìm thấy file nào trên Firebase Server',
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Vui lòng kiểm tra lại URL Firebase hoặc đẩy dữ liệu từ app lên trước.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1976D2),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: loadDatasets,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Thử lại'),
                                ),
                              ],
                            ),
                          ),
                        )
                      else ...[
                        // Thanh công cụ chọn tất cả
                        Row(
                          children: [
                            Text(
                              'Tìm thấy ${datasets.length} file dữ liệu trên server:',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () {
                                setSheetState(() {
                                  if (selectedKeys.length == datasets.length) {
                                    selectedKeys.clear();
                                  } else {
                                    selectedKeys.addAll(datasets.map((d) => d.key));
                                  }
                                });
                              },
                              icon: Icon(
                                selectedKeys.length == datasets.length ? Icons.check_box : Icons.select_all,
                                size: 16,
                                color: const Color(0xFF1976D2),
                              ),
                              label: Text(
                                selectedKeys.length == datasets.length ? 'Bỏ chọn' : 'Chọn tất cả',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF1976D2), fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),

                        // Danh sách file
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: datasets.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (ctx, idx) {
                              final item = datasets[idx];
                              final isSelected = selectedKeys.contains(item.key);

                              return Container(
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFFE3F2FD) : Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? const Color(0xFF1976D2) : Colors.grey.shade300,
                                    width: isSelected ? 1.5 : 1.0,
                                  ),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    setSheetState(() {
                                      if (isSelected) {
                                        selectedKeys.remove(item.key);
                                      } else {
                                        selectedKeys.add(item.key);
                                      }
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          value: isSelected,
                                          activeColor: const Color(0xFF1976D2),
                                          onChanged: (val) {
                                            setSheetState(() {
                                              if (val == true) {
                                                selectedKeys.add(item.key);
                                              } else {
                                                selectedKeys.remove(item.key);
                                              }
                                            });
                                          },
                                        ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.displayName,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 6),
                                              Wrap(
                                                spacing: 6,
                                                runSpacing: 4,
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: Colors.green.shade50,
                                                      borderRadius: BorderRadius.circular(4),
                                                      border: Border.all(color: Colors.green.shade300),
                                                    ),
                                                    child: Text(
                                                      '🌳 ${item.plotCount} Lô',
                                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green.shade800),
                                                    ),
                                                  ),
                                                  if (item.poiCount > 0)
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: Colors.orange.shade50,
                                                        borderRadius: BorderRadius.circular(4),
                                                        border: Border.all(color: Colors.orange.shade300),
                                                      ),
                                                      child: Text(
                                                        '📍 ${item.poiCount} Mốc',
                                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange.shade800),
                                                      ),
                                                    ),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: Colors.grey.shade100,
                                                      borderRadius: BorderRadius.circular(4),
                                                      border: Border.all(color: Colors.grey.shade300),
                                                    ),
                                                    child: Text(
                                                      '🕒 ${formatDateTime(item.updatedAt)}',
                                                      style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700),
                                                    ),
                                                  ),
                                                  if (item.deviceTag.isNotEmpty)
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: Colors.blue.shade50,
                                                        borderRadius: BorderRadius.circular(4),
                                                        border: Border.all(color: Colors.blue.shade200),
                                                      ),
                                                      child: Text(
                                                        '📱 ${item.deviceTag}',
                                                        style: TextStyle(fontSize: 10.5, color: Colors.blue.shade800),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.download_for_offline, color: Color(0xFF1976D2), size: 26),
                                          tooltip: 'Tải ngay file này',
                                          onPressed: isDownloading ? null : () => executeDownload([item]),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 12),
                        // Hộp kiểm tùy chọn thay thế
                        Row(
                          children: [
                            Checkbox(
                              value: replaceExisting,
                              activeColor: const Color(0xFF1976D2),
                              onChanged: (val) => setSheetState(() => replaceExisting = val ?? true),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setSheetState(() => replaceExisting = !replaceExisting),
                                child: const Text(
                                  'Ghi đè/cập nhật lại nhóm dữ liệu nếu đã có trên máy',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),
                        // Nút Tải các file đã chọn
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1976D2),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 3,
                            ),
                            icon: isDownloading
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                : const Icon(Icons.cloud_download),
                            label: Text(
                              isDownloading
                                  ? statusText
                                  : 'TẢI ${selectedKeys.length} FILE ĐÃ CHỌN VỀ BẢN ĐỒ',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            onPressed: isDownloading || selectedKeys.isEmpty
                                ? null
                                : () {
                                    final targets = datasets.where((d) => selectedKeys.contains(d.key)).toList();
                                    executeDownload(targets);
                                  },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCloudSyncDialog() async {
    if (!_checkCanPerformAction('Đồng bộ đám mây Firebase')) return;
    final syncService = FirebaseSyncService();
    await syncService.loadConfig();
    final config = syncService.config;

    final urlCtrl = TextEditingController(text: config.url);
    final secretCtrl = TextEditingController(text: config.secret);
    final deviceTagCtrl = TextEditingController(text: config.deviceTag);
    bool rememberUrl = config.rememberUrl;
    bool isSyncing = false;
    int pendingQueueCount = await syncService.getPendingQueueCount();

    // Lấy danh sách tên các nhóm hiện có
    final Set<String> groupNames = {};
    for (var p in _plots) {
      groupNames.add(p.groupName);
    }
    for (var p in _poiList) {
      groupNames.add(p.groupName);
    }
    String selectedGroup = 'Tất cả các nhóm';

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bCtx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
            final safeBottom = MediaQuery.of(context).padding.bottom + 16.0;

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom + bottomPadding),
              child: SafeArea(
                top: false,
                bottom: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.88,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Icon(Icons.cloud_sync, color: Color(0xFF1976D2), size: 24),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'ĐỒNG BỘ ĐÁM MÂY (FIREBASE)',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1976D2),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.grey),
                              onPressed: () => Navigator.pop(bCtx),
                            ),
                          ],
                        ),
                        const Text(
                          'Dữ liệu được lưu cache máy an toàn khi mất mạng. Khi có mạng sẽ tự động đẩy lên server Firebase.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 16),

                        // Ô nhập URL
                        const Text('Firebase Database URL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: urlCtrl,
                          decoration: InputDecoration(
                            hintText: 'https://du-an-default-rtdb.firebaseio.com',
                            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                            prefixIcon: const Icon(Icons.link, size: 20, color: Color(0xFF1976D2)),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 6),

                        // Checkbox lưu URL
                        Row(
                          children: [
                            Checkbox(
                              value: rememberUrl,
                              activeColor: const Color(0xFF1976D2),
                              onChanged: (val) {
                                setSheetState(() {
                                  rememberUrl = val ?? true;
                                });
                              },
                            ),
                            GestureDetector(
                              onTap: () {
                                setSheetState(() {
                                  rememberUrl = !rememberUrl;
                                });
                              },
                              child: const Text(
                                'Lưu URL này (lần sau mở app không cần nhập lại)',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),

                        // Mã Secret / Token (Tùy chọn)
                        const SizedBox(height: 8),
                        const Text('Secret Key / Auth Token (Tùy chọn):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: secretCtrl,
                          obscureText: true,
                          decoration: InputDecoration(
                            hintText: 'Để trống nếu Database ở chế độ kiểm thử (test)',
                            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                            prefixIcon: const Icon(Icons.lock_outline, size: 20, color: Colors.grey),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),

                        // Tên thiết bị / Đội
                        const SizedBox(height: 12),
                        const Text('Tên thiết bị / Đội tuần tra:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: deviceTagCtrl,
                          decoration: InputDecoration(
                            hintText: 'Ví dụ: Đội Tuần Tra 1',
                            prefixIcon: const Icon(Icons.devices, size: 20, color: Colors.grey),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),

                        // Chọn nhóm cần đẩy
                        const SizedBox(height: 12),
                        const Text('Nhóm dữ liệu cần đồng bộ:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: selectedGroup,
                              items: [
                                const DropdownMenuItem(
                                  value: 'Tất cả các nhóm',
                                  child: Text('Tất cả các nhóm dữ liệu hiện có', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                ),
                                ...groupNames.map(
                                  (g) => DropdownMenuItem(
                                    value: g,
                                    child: Text('Nhóm: $g', style: const TextStyle(fontSize: 13)),
                                  ),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setSheetState(() => selectedGroup = val);
                                }
                              },
                            ),
                          ),
                        ),

                        // Hàng đợi ngoại tuyến (Offline Queue)
                        if (pendingQueueCount > 0) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.shade400),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.offline_pin, color: Colors.amber, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Đang có $pendingQueueCount mục lưu tạm trong cache máy (chờ có mạng để tự đẩy lên).',
                                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // Trạng thái lần cuối đồng bộ
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.history, size: 16, color: Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              config.lastSyncTime != null
                                  ? 'Đồng bộ lần cuối: ${config.lastSyncTime!.hour.toString().padLeft(2, '0')}:${config.lastSyncTime!.minute.toString().padLeft(2, '0')} ngày ${config.lastSyncTime!.day}/${config.lastSyncTime!.month}/${config.lastSyncTime!.year}'
                                  : 'Chưa từng đồng bộ',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // 2 Nút chính
                        Row(
                          children: [
                            // Nút Đẩy lên Firebase
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1976D2),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSyncing
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                    : const Icon(Icons.cloud_upload),
                                label: Text(isSyncing ? 'Đang đẩy...' : 'ĐẨY LÊN SERVER', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                onPressed: isSyncing ? null : () async {
                                  final rawUrl = urlCtrl.text.trim();
                                  if (rawUrl.isEmpty) {
                                    _showToast('Vui lòng nhập URL Firebase!');
                                    return;
                                  }

                                  setSheetState(() => isSyncing = true);

                                  // Lưu config
                                  config.url = rawUrl;
                                  config.rememberUrl = rememberUrl;
                                  config.secret = secretCtrl.text.trim();
                                  config.deviceTag = deviceTagCtrl.text.trim();
                                  await syncService.saveConfig(config);

                                  int successGroups = 0;
                                  int totalPlots = 0;
                                  int totalPois = 0;
                                  bool anyOffline = false;

                                  if (selectedGroup == 'Tất cả các nhóm') {
                                    // Xóa nhánh gộp cũ 'Toan_Bo_Du_Lieu' nếu có để Firebase hiển thị từng nhóm rõ ràng
                                    syncService.deleteDataset('Toan_Bo_Du_Lieu');

                                    // Lấy tất cả các nhóm dữ liệu riêng biệt để đẩy thành từng nhánh riêng
                                    final Set<String> groupsToSync = {};
                                    for (var p in _plots) {
                                      if (p.groupName.trim().isNotEmpty) {
                                        groupsToSync.add(p.groupName.trim());
                                      }
                                    }
                                    for (var p in _poiList) {
                                      if (p.groupName.trim().isNotEmpty) {
                                        groupsToSync.add(p.groupName.trim());
                                      }
                                    }
                                    if (groupsToSync.isEmpty) {
                                      groupsToSync.add('Du_Lieu_Mac_Dinh');
                                    }

                                    for (var gName in groupsToSync) {
                                      final plotsInGroup = _plots.where((p) => p.groupName == gName).toList();
                                      final poisInGroup = _poiList.where((p) => p.groupName == gName).toList();
                                      final res = await syncService.pushDataset(
                                        groupName: gName,
                                        plots: plotsInGroup,
                                        pois: poisInGroup,
                                      );
                                      if (res.isOfflineQueued) anyOffline = true;
                                      if (res.success) successGroups++;
                                      totalPlots += plotsInGroup.length;
                                      totalPois += poisInGroup.length;
                                    }
                                  } else {
                                    final plotsToSync = _plots.where((p) => p.groupName == selectedGroup).toList();
                                    final poisToSync = _poiList.where((p) => p.groupName == selectedGroup).toList();
                                    final res = await syncService.pushDataset(
                                      groupName: selectedGroup,
                                      plots: plotsToSync,
                                      pois: poisToSync,
                                    );
                                    if (res.isOfflineQueued) anyOffline = true;
                                    if (res.success) successGroups = 1;
                                    totalPlots = plotsToSync.length;
                                    totalPois = poisToSync.length;
                                  }

                                  pendingQueueCount = await syncService.getPendingQueueCount();
                                  setSheetState(() => isSyncing = false);

                                  if (anyOffline) {
                                    _showToast('Không có mạng. Đã lưu $totalPlots Lô vào bộ nhớ cache máy!\nSẽ tự động đẩy lên server khi có mạng.');
                                  } else {
                                    _showToast('Đã đồng bộ thành công $successGroups nhóm riêng biệt lên Firebase!\n(Tổng cộng $totalPlots Lô, $totalPois Mốc)');
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 10),

                            // Nút Tải từ Firebase về máy
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1976D2),
                                  side: const BorderSide(color: Color(0xFF1976D2), width: 1.5),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.cloud_download),
                                label: const Text('TẢI VỀ MÁY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                onPressed: isSyncing ? null : () async {
                                  final rawUrl = urlCtrl.text.trim();
                                  if (rawUrl.isEmpty) {
                                    _showToast('Vui lòng nhập URL Firebase!');
                                    return;
                                  }

                                  config.url = rawUrl;
                                  config.rememberUrl = rememberUrl;
                                  config.secret = secretCtrl.text.trim();
                                  config.deviceTag = deviceTagCtrl.text.trim();
                                  await syncService.saveConfig(config);

                                  if (bCtx.mounted) {
                                    Navigator.pop(bCtx);
                                  }
                                  _showFirebaseCloudDownloadDialog();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CompassNeedlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Nửa chỉ hướng Bắc (Màu đỏ tươi)
    final northPaint = Paint()
      ..color = const Color(0xFFE53935)
      ..style = PaintingStyle.fill;
    final northPath = ui.Path()
      ..moveTo(cx, 2)
      ..lineTo(cx + 4.5, cy)
      ..lineTo(cx - 4.5, cy)
      ..close();
    canvas.drawPath(northPath, northPaint);

    // Nửa chỉ hướng Nam (Màu bạc/trắng)
    final southPaint = Paint()
      ..color = const Color(0xFFCFD8DC)
      ..style = PaintingStyle.fill;
    final southPath = ui.Path()
      ..moveTo(cx, size.height - 2)
      ..lineTo(cx + 4.5, cy)
      ..lineTo(cx - 4.5, cy)
      ..close();
    canvas.drawPath(southPath, southPaint);

    // Chốt trục kim ở giữa
    final pivotPaint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 2.5, pivotPaint);

    // Chữ 'B' (Bắc) ở đỉnh kim
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'B',
        style: TextStyle(
          color: Color(0xFFFFCDD2),
          fontSize: 7.5,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(cx - textPainter.width / 2, 3));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
