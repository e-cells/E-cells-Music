import 'package:flutter/services.dart';

/// Android「自定义下载路径」的公共目录写权限桥
/// （原生 MainActivity 的 `shiyin_music/storage_access` channel）。
///
/// 权限口径（与 manifest 声明对应）：
/// - API ≤ 29（Android 8-10）：`WRITE_EXTERNAL_STORAGE` 运行时权限弹窗，
///   Android 10 叠加 manifest 的 `requestLegacyExternalStorage` 才能裸写路径；
/// - API 30+（Android 11+）：分区存储下裸写公共目录必 EACCES，须由用户在
///   系统设置授予 `MANAGE_EXTERNAL_STORAGE`（「所有文件访问」，含 SD/USB 盘）。
///
/// 本应用经 GitHub 直发 APK、不上架 Play，All-Files-Access 无政策审核问题；
/// 未自定义下载位置时不触碰任何权限（默认下载仍落 App 专属目录）。
class StorageAccessService {
  const StorageAccessService._();

  static const MethodChannel _channel = MethodChannel(
    'shiyin_music/storage_access',
  );

  /// 是否已具备公共目录写权限（只在 Android 调用）。
  ///
  /// 插件未注册（非 Android 平台/异常环境）按「无权限」处理，
  /// 由 UI 侧负责不在此场景展示入口。
  static Future<bool> hasWritePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasWritePermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 请求公共目录写权限。
  ///
  /// 返回值三态：
  /// - `true`：已授权（含原本就已授权），可继续选目录；
  /// - `false`：API ≤ 29 的运行时弹窗被拒绝；
  /// - `null`：API 30+ 已跳转系统「所有文件访问」设置页，用户返回后
  ///   由调用方经 [hasWritePermission] 重查（授权状态系统不回推）。
  static Future<bool?> requestWritePermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestWritePermission');
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 用系统文件管理器打开共享存储目录（已下载-打开文件夹）。
  ///
  /// 原生侧以 ACTION_VIEW + `vnd.android.document/directory` 拉起声明
  /// 可处理目录 content URI 的文件管理器（DocumentsUI「文件」、Files by
  /// Google、各家 OEM 与第三方管理器普遍按此口径声明）。必须走原生：
  /// url_launcher 发 Intent 不能携带 MIME 类型——file:// 目录 URI 现代
  /// 系统无人响应且 targetSdk 24+ 还有 FileUriExposed 风险，无 MIME 的
  /// content URI 同样无人认领。
  ///
  /// 返回值（null = channel 不可用，非 Android 环境按调用方兜底）：
  /// - `opened`：已拉起文件管理器；
  /// - `app_private`：目录在 `Android/data|obb` 下且 API 30+，分区存储
  ///   禁止其他应用（含文件管理器）访问，未尝试，由调用方引导改用
  ///   公共下载目录；
  /// - `no_handler`：本机没有声明能打开目录的文件管理器（或被系统拒绝）。
  static Future<String?> openDirectory({
    required String path,
    required String docId,
  }) async {
    try {
      return await _channel.invokeMethod<String>('openDirectory', {
        'path': path,
        'docId': docId,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
