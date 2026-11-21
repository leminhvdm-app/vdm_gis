import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/forest_plot.dart';

class SampleForestData {
  static List<ForestPlot> getPlots() {
    return [
      // Lô 1: Rừng tự nhiên lá rộng thường xanh
      ForestPlot(
        id: 'LO_01',
        tieuKhu: 'TK 142',
        khoanh: 'Khoảnh 2',
        lo: 'Lô 1a',
        dienTich: 18.5,
        chuRung: 'Ban Quản Lý RPH Trị An',
        trangThaiRung: 'Rừng tự nhiên giàu',
        loaiCay: 'Dầu, Sao đen, Cẩm lai, Bằng lăng',
        truLuong: 185.0,
        color: const Color(0xFF1B5E20), // Xanh đậm
        note: 'Khu vực bảo tồn nguyên sinh, độ che phủ > 80%',
        groupName: 'Dữ liệu mẫu ban đầu',
        boundary: const [
          LatLng(11.3400, 107.0300),
          LatLng(11.3440, 107.0320),
          LatLng(11.3450, 107.0380),
          LatLng(11.3410, 107.0370),
          LatLng(11.3390, 107.0330),
        ],
      ),

      // Lô 2: Rừng trồng Keo lai 4 năm tuổi
      ForestPlot(
        id: 'LO_02',
        tieuKhu: 'TK 142',
        khoanh: 'Khoảnh 2',
        lo: 'Lô 2b',
        dienTich: 12.8,
        chuRung: 'Hộ ông Nguyễn Văn Tuấn (Nhận khoán)',
        trangThaiRung: 'Rừng trồng sản xuất',
        loaiCay: 'Keo lai (Acacia hybrid)',
        namTrong: 2022,
        truLuong: 75.0,
        color: const Color(0xFF43A047), // Xanh lá cây
        note: 'Đang sinh trưởng tốt, chuẩn bị tỉa thưa đợt 1',
        groupName: 'Dữ liệu mẫu ban đầu',
        boundary: const [
          LatLng(11.3450, 107.0380),
          LatLng(11.3480, 107.0420),
          LatLng(11.3440, 107.0450),
          LatLng(11.3410, 107.0400),
          LatLng(11.3410, 107.0370),
        ],
      ),

      // Lô 3: Rừng Cao su khai thác mủ
      ForestPlot(
        id: 'LO_03',
        tieuKhu: 'TK 142',
        khoanh: 'Khoảnh 3',
        lo: 'Lô 3c',
        dienTich: 15.2,
        chuRung: 'Công ty Lâm nghiệp Đồng Nai',
        trangThaiRung: 'Rừng trồng cao su',
        loaiCay: 'Cao su PB 260',
        namTrong: 2017,
        truLuong: 110.0,
        color: const Color(0xFFFB8C00), // Cam đất
        note: 'Năm khai thác mủ thứ 3, năng suất ổn định',
        groupName: 'Dữ liệu mẫu ban đầu',
        boundary: const [
          LatLng(11.3390, 107.0330),
          LatLng(11.3410, 107.0370),
          LatLng(11.3410, 107.0400),
          LatLng(11.3360, 107.0390),
          LatLng(11.3350, 107.0340),
        ],
      ),

      // Lô 4: Đất trống đồi trọc, cây bụi phục hồi tự nhiên
      ForestPlot(
        id: 'LO_04',
        tieuKhu: 'TK 142',
        khoanh: 'Khoảnh 3',
        lo: 'Lô 4a',
        dienTich: 8.4,
        chuRung: 'Ủy ban Nhân dân Xã quản lý',
        trangThaiRung: 'Đất trống có cây tái sinh',
        loaiCay: 'Cây bụi, chổi sim, lau lách',
        color: const Color(0xFF8D6E63), // Nâu nhạt
        note: 'Quy hoạch trồng bổ sung Lim xẹt năm 2027',
        groupName: 'Dữ liệu mẫu ban đầu',
        boundary: const [
          LatLng(11.3360, 107.0390),
          LatLng(11.3410, 107.0400),
          LatLng(11.3440, 107.0450),
          LatLng(11.3380, 107.0460),
          LatLng(11.3350, 107.0410),
        ],
      ),

      // Lô 5: Rừng phòng hộ đầu nguồn sông Đồng Nai
      ForestPlot(
        id: 'LO_05',
        tieuKhu: 'TK 143',
        khoanh: 'Khoảnh 1',
        lo: 'Lô 1c',
        dienTich: 22.1,
        chuRung: 'Hạt Kiểm lâm Vườn Quốc gia',
        trangThaiRung: 'Rừng phòng hộ đầu nguồn',
        loaiCay: 'Hỗn loài bản địa',
        truLuong: 210.0,
        color: const Color(0xFF00897B), // Xanh lam ngọc
        note: 'Nghiêm cấm khai thác, có trạm tuần tra chốt chặn số 4',
        groupName: 'Dữ liệu mẫu ban đầu',
        boundary: const [
          LatLng(11.3440, 107.0450),
          LatLng(11.3490, 107.0480),
          LatLng(11.3460, 107.0540),
          LatLng(11.3400, 107.0510),
          LatLng(11.3380, 107.0460),
        ],
      ),
    ];
  }
}
