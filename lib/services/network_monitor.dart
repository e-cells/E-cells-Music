import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// 网络状态监听。
///
/// 车机会在 WiFi / 蜂窝数据 / 离线之间频繁切换，App 此前对切换完全无感知：
/// 断网瞬间的请求直接失败，恢复后也不会自动重试。这里统一监听网络变化，
/// 在"从无网恢复到有网"时通过 [onConnectivityRestored] 通知上层恢复播放。
class NetworkMonitor {
  NetworkMonitor._();

  static final NetworkMonitor instance = NetworkMonitor._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// 网络从不可用恢复到可用时触发（车机切网 / 重新连接）。
  final _restored = StreamController<void>.broadcast();
  Stream<void> get onConnectivityRestored => _restored.stream;

  bool _hasNetwork = false;
  bool get hasNetwork => _hasNetwork;

  /// 最近一次系统上报的连接类型（connectivity_plus 原值）。
  /// 用于区分 WiFi/有线与按流量计费的蜂窝网络，驱动预缓存等
  /// 后台下载门控。默认为空（未知），未知时按“非蜂窝”放行，
  /// 避免单测/桌面无 NetworkManager 环境误杀后台任务。
  List<ConnectivityResult> _results = const [];
  List<ConnectivityResult> get results => List.unmodifiable(_results);

  /// 是否为按流量计费的蜂窝网络。
  ///
  /// 判定：包含 mobile 且不包含 wifi/ethernet。
  /// 多传输并存（如 wifi+vpn）按 WiFi 对待；未知/空按非蜂窝处理。
  ///
  /// 未知按放行是安全的：唯一消费者是后台音频缓存门控，而预缓存
  /// 要求播放 ≥15s 才会触发，远晚于 start() 的一次 checkConnectivity
  /// （毫秒级）；真正查不到的桌面无 NM 环境本就没有蜂窝。
  bool get isCellular {
    if (_results.isEmpty) return false;
    if (_results.contains(ConnectivityResult.wifi) ||
        _results.contains(ConnectivityResult.ethernet)) {
      return false;
    }
    return _results.contains(ConnectivityResult.mobile);
  }

  /// 是否为 WiFi/有线等非计费网络。
  bool get isUnmetered =>
      _results.contains(ConnectivityResult.wifi) ||
      _results.contains(ConnectivityResult.ethernet);

  /// 是否已订阅系统网络变化。
  bool get isListening => _sub != null;

  Future<void> start() async {
    // 先同步占住订阅位再 await checkConnectivity：否则并发 start() 都能
    // 通过 null 检查，产生双重订阅（_sub 只留最后一条，前一条泄漏且
    // _onChanged 每事件被调多次）。
    if (_sub != null) return;
    _sub = _connectivity.onConnectivityChanged.listen(
      _onChanged,
      // 个别 Linux 桌面/极简环境没有 NetworkManager，connectivity_plus
      // 的事件流会持续报错（Unhandled Exception）。这里吞掉错误保持降级：
      // 仅损失断网恢复自动重播事件，不影响其余功能。
      onError: (Object error) {
        debugPrint('NetworkMonitor: 连接状态流错误（已降级忽略）: $error');
      },
    );
    try {
      final results = await _connectivity.checkConnectivity();
      _results = results;
      _hasNetwork = results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      _results = const [];
      _hasNetwork = false;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onChanged(List<ConnectivityResult> results) {
    _results = results;
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    final wasOffline = !_hasNetwork;
    _hasNetwork = hasNetwork;
    if (hasNetwork && wasOffline && !_restored.isClosed) {
      _restored.add(null);
    }
  }

  /// 仅供测试：模拟"网络从断开恢复到可用"事件，驱动 UI 层的自动刷新。
  @visibleForTesting
  void debugSimulateRestored() {
    if (!_restored.isClosed) _restored.add(null);
  }

  /// 主动探测互联网可达性。
  ///
  /// 为什么需要它：车机进隧道时，蜂窝/WiFi 链路往往并未断开（手机热点
  /// 还连着、调制解调器仍附着），connectivity_plus 全程报告 mobile/wifi，
  /// [onConnectivityRestored] 的"断→通"跃迁根本不会发生——出隧道后无人
  /// 通知播放器恢复。这里对酷狗网关发一个极轻量的 HEAD（与 Rust 侧
  /// DEFAULT_GATEWAY 同源），拿到任意 HTTP 响应（状态码 ≥ 200，含
  /// 4xx/5xx——它们同样证明了能完成外网往返）即认为外网可达。
  ///
  /// 连接复用单例 client；证书宽松放行——探测只关心"能不能完成 HTTP
  /// 往返"，误判（如门户页）后续真实请求失败会自然回到失败路径，自愈。
  Future<bool> probeInternet({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final override = probeOverride;
    if (override != null) return override(timeout);
    final client = _probeClient;
    try {
      final request = await client
          .headUrl(Uri.parse('https://gateway.kugou.com'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      return response.statusCode >= 200;
    } catch (_) {
      return false;
    }
  }

  static final HttpClient _probeClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..badCertificateCallback = (_, _, _) => true;

  /// 测试注入：非空时 [probeInternet] 直接返回其结果，不发真实请求。
  @visibleForTesting
  static Future<bool> Function(Duration timeout)? probeOverride;

  /// 仅供测试：直接注入连接类型，驱动预缓存等流量门控单测。
  @visibleForTesting
  void debugSetResults(List<ConnectivityResult> results) {
    _results = List.unmodifiable(results);
    _hasNetwork = results.any((r) => r != ConnectivityResult.none);
  }

  void dispose() {
    _restored.close();
  }
}
