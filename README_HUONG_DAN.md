# ForestGIS - Ứng Dụng Bản Đồ GIS Quản Lý Lô Rừng (Android & iOS)

Ứng dụng bản đồ GIS di động chuyên biệt cho công tác **đi rừng, tuần tra hiện trường và quản lý tiểu khu - khoảnh - lô rừng** tại Việt Nam, phát triển trên nền tảng **Flutter + flutter_map**.

---

## 🌲 1. Các Tính Năng Đã Triển Khai Hoàn Chỉnh

1. **Bản đồ đa lớp & Hỗ trợ Ngoại tuyến (Offline Cache)**:
   - **Ảnh vệ tinh (Satellite)**: Tích hợp ảnh ESRI World Imagery độ phân giải cao.
   - **Bản đồ địa hình (Topo/Terrain)**: Tích hợp OpenTopoMap hiển thị đường bình độ, độ dốc, đỉnh núi.
   - **Bản đồ giao thông**: Đường sá, lối mòn theo OpenStreetMap.
   - Nút chuyển nhanh 3 lớp bản đồ ngay góc phải màn hình.

2. **Quản lý Tiểu khu - Khoảnh - Lô rừng**:
   - Tự động hiển thị các lô rừng với ranh giới đa giác chuẩn xác và nhãn tên lô + diện tích trực tiếp trên bản đồ.
   - Phân loại màu sắc trực quan theo trạng thái rừng:
     - 🟢 *Xanh lá đậm*: Rừng tự nhiên nguyên sinh / phục hồi giàu.
     - 🌿 *Xanh lá non*: Rừng trồng Keo, Bạch đàn sản xuất.
     - 🟠 *Cam đất*: Rừng cây công nghiệp / Cao su.
     - 🟤 *Nâu nhạt*: Đất trống đồi trọc, cây bụi tái sinh.
     - 🔷 *Xanh ngọc*: Rừng phòng hộ đầu nguồn.
   - **Chạm vào lô**: Hiển thị bảng thuộc tính đầy đủ: *Tiểu khu, Khoảnh, Lô, Diện tích (ha), Chủ rừng, Trạng thái, Loài cây, Năm trồng, Cấp tuổi, Ghi chú hiện trường*.

3. **Định vị GPS thực địa & Thuật toán nhận diện Lô**:
   - Chạm nút GPS để lấy tọa độ định vị vệ tinh của thiết bị.
   - Tự động chạy thuật toán hình học **Ray-Casting**: Xác định tức thì **"Bạn đang đứng trong Lô số mấy, Khoảnh nào, Tiểu khu nào?"** và bật cảnh báo nếu bước ra khỏi ranh giới lô.

4. **Bộ công cụ đo đạc thực địa**:
   - **Đo khoảng cách**: Chạm các điểm trên thực địa để đo tổng chiều dài theo mét hoặc km.
   - **Đo diện tích lô mới**: Chạm các điểm ranh giới để tính diện tích đa giác theo **Hecta (ha)** và $m^2$ theo thuật toán trắc địa mặt cầu WGS-84.

5. **Nạp dữ liệu ngoài (Import GeoJSON)**:
   - Hỗ trợ nút nạp nhanh các file `.geojson` được xuất từ QGIS, ArcGIS hoặc máy tính để hiển thị ngay trên điện thoại.

---

## 📁 2. Cấu Trúc Mã Nguồn Dễ Chỉnh Sửa

```text
forest_gis/
├── lib/
│   ├── main.dart                  # Khởi chạy ứng dụng & cấu hình theme
│   ├── models/
│   │   └── forest_plot.dart       # Model dữ liệu Lô rừng & parser GeoJSON
│   ├── utils/
│   │   └── gis_calculator.dart    # Thuật toán Ray-Casting & tính diện tích Hecta
│   ├── data/
│   │   └── sample_forest_data.dart# Dữ liệu lô rừng mẫu thực tế tại Việt Nam
│   └── screens/
│       └── map_screen.dart        # Màn hình bản đồ tương tác chính
├── android/                       # Mã nguồn native Android (đã cấu hình quyền GPS)
├── ios/                           # Mã nguồn native iOS (đã cấu hình Info.plist)
└── pubspec.yaml                   # Cấu hình gói thư viện GIS
```

---

## 🚀 3. Hướng Dẫn Chạy & Đóng Gói Ứng Dụng

Mở PowerShell tại thư mục `forest_gis` và sử dụng đường dẫn Flutter có sẵn trên máy:

### Chạy thử nghiệm trên máy tính (Chrome Web):
```powershell
& 'C:\flutter\bin\flutter.bat' run -d chrome
```

### Chạy trên thiết bị di động (khi cắm cáp USB điện thoại Android):
```powershell
& 'C:\flutter\bin\flutter.bat' run
```

### Xuất file APK để cài trực tiếp vào điện thoại Android:
```powershell
& 'C:\flutter\bin\flutter.bat' build apk --release
```
*File cài đặt sẽ được tạo tại:* `build/app/outputs/flutter-apk/app-release.apk` (Copy file này vào điện thoại để cài đặt và đi rừng).

---

## 🗺️ 4. Cách đưa bản đồ rừng của riêng bạn vào App
1. Trên máy tính, mở **QGIS** với lớp bản đồ ranh giới rừng của đơn vị bạn.
2. Nhấp chuột phải vào lớp rừng -> **Export** -> **Save Features As...**
3. Chọn Format là **GeoJSON**, CRS là **EPSG:4326 - WGS 84**.
4. Chép file `.geojson` vào điện thoại, mở app **ForestGIS** và bấm biểu tượng **Nạp file (Upload)** trên thanh tìm kiếm!
