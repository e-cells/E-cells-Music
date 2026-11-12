import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/download_service.dart';
import '../../services/storage_access_service.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 「下载位置」：file_picker 选目录写入
/// [DownloadService.downloadDirOverrideKey]，[DownloadService.downloadDir]
/// 优先使用；设置后只影响新下载，已有下载的索引是绝对路径仍有效
/// （桌面端下次对账按「以文件为准」搬入新目录，Android 保持原位置）。
///
/// 入口两处：桌面形态在「桌面」分节（desktop_settings_section），
/// Android 在「缓存」分节（cache_settings_section）。独立小组件自管
/// 状态，避免整页改 Stateful。设了自定义位置时追加「恢复默认」一行。
///
/// Android 权限前置（[StorageAccessService]）：选公共目录（含 SD/USB 盘）
/// 须先取得写权限——API 30+ 会跳系统「所有文件访问」设置页，用户返回
/// 应用后经 [WidgetsBindingObserver.didChangeAppLifecycleState] 自动续走
/// 选目录，不用再点一次。
class DownloadLocationSettings extends StatefulWidget {
  const DownloadLocationSettings({super.key});

  /// 宿主（Windows/Mac/Linux）单测强制走 Android 流程（权限前置 +
  /// 生命周期续走）的测试钩子；生产恒由平台判定。测试结束须复位。
  @visibleForTesting
  static bool debugForceAndroidFlow = false;

  @override
  State<DownloadLocationSettings> createState() =>
      _DownloadLocationSettingsState();
}

class _DownloadLocationSettingsState extends State<DownloadLocationSettings>
    with WidgetsBindingObserver {
  /// null = 未设置自定义（跟随平台默认）。
  String? _custom;

  /// 当前实际生效的下载目录（解析失败时为 null，配合 [_loaded] 区分
  /// 「还在读」与「读不到」）。
  String? _effectivePath;
  bool _loaded = false;
  bool _picking = false;

  /// Android：已跳「所有文件访问」系统设置页，等用户返回后续走选目录。
  bool _awaitingAllFilesAccess = false;

  bool get _androidFlow =>
      DownloadLocationSettings.debugForceAndroidFlow || Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 用户从系统「所有文件访问」设置页返回：已授权则自动续走选目录，
  /// 未授权提示稍后再试（跳转 flag 只消费一次）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_awaitingAllFilesAccess || _picking) return;
    _awaitingAllFilesAccess = false;
    unawaited(_resumeFromAllFilesAccess());
  }

  Future<void> _resumeFromAllFilesAccess() async {
    final granted = await StorageAccessService.hasWritePermission();
    if (!mounted) return;
    if (granted) {
      await _pick();
    } else {
      Toast.info('还未开启「所有文件访问」权限，可稍后再点「下载位置」继续');
    }
  }

  Future<void> _load() async {
    final custom = await DownloadService.customDownloadDirOverride();
    String? effective = custom;
    try {
      effective = (await DownloadService().downloadDir()).path;
    } catch (e) {
      // 目录解析失败（自定义位置所在卷未挂载、U 盘拔出等）：显示不可用态，
      // 用户仍可在此改选或恢复默认。
      debugPrint('[设置] 解析下载位置失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _custom = custom;
      _effectivePath = effective;
      _loaded = true;
    });
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      if (_androidFlow) {
        // 权限前置：公共目录（含 SD/USB 盘）未授权时选回的路径必写不进
        // （ensureWritableDir 探测 EACCES），先把权限拿全再开选择器。
        final granted = await StorageAccessService.requestWritePermission();
        if (granted == null) {
          // API 30+：已跳系统「所有文件访问」设置页，返回后续走。
          _awaitingAllFilesAccess = true;
          Toast.info('已跳转系统设置，开启「所有文件访问」后返回应用');
          return;
        }
        if (!granted) {
          // API ≤ 29：运行时弹窗被拒。
          Toast.error('需要存储权限才能自定义下载位置');
          return;
        }
      }
      await _pickAndSave();
    } catch (e) {
      debugPrint('[设置] 设置下载位置失败: $e');
      Toast.error('设置下载位置失败：$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 选目录 → 探测可写 → 保存（权限流程已由调用方保证）。
  Future<void> _pickAndSave() async {
    Toast.info('请选择下载文件夹...');
    String? directory;
    try {
      // initialDirectory 仅桌面生效（Android 的 SAF 选择器不支持定位，
      // 传了被忽略）。
      directory = await FilePicker.getDirectoryPath(
        dialogTitle: '选择下载位置',
        initialDirectory: _effectivePath,
        lockParentWindow: true,
      );
    } catch (e) {
      if (_androidFlow) rethrow;
      // file_picker 的 Windows COM 弹窗偶发 WindowsException（上游
      // 长期存在的线程/初始化类 issue，无稳定复现路径）：降级到
      // PowerShell 的 WinForms FolderBrowserDialog——弹窗机制完全
      // 独立，不受影响；取消返回 null 与主路径语义一致。
      debugPrint('[设置] 文件夹选择器异常，降级 WinForms 弹窗: $e');
      directory = await _pickDirectoryFallback(_effectivePath);
    }
    if (directory == null) return;
    // 先探测可写再保存：选到不可写目录（权限不足/只读介质）时当场报错，
    // 而不是存下来等下载时才失败。
    try {
      await DownloadService.ensureWritableDir(directory);
    } catch (e) {
      debugPrint('[设置] 下载位置不可写: $e');
      Toast.error('$e');
      return;
    }
    await DownloadService.setCustomDownloadDir(directory);
    Toast.success('下载位置已更新，之后下载的歌曲将保存到该文件夹');
    await _load();
  }

  /// file_picker 失败时的兜底：PowerShell 跑 WinForms FolderBrowserDialog，
  /// stdout 回传所选路径；用户取消返回 null，PowerShell 异常原样抛出。
  Future<String?> _pickDirectoryFallback(String? initialDirectory) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-EncodedCommand',
      encodePowerShellScript(buildFolderBrowserScript(initialDirectory)),
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'PowerShell exit ${result.exitCode}: '
        '${(result.stderr as String).trim()}',
      );
    }
    final picked = (result.stdout as String).trim();
    return picked.isEmpty ? null : picked;
  }

  Future<void> _reset() async {
    await DownloadService.setCustomDownloadDir(null);
    Toast.success(_androidFlow ? '已恢复默认下载位置（App 专属目录）' : '已恢复默认下载位置（系统下载目录）');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final effective = _effectivePath;
    final String subtitle;
    if (!_loaded) {
      subtitle = '正在读取当前下载位置...';
    } else if (effective == null) {
      subtitle = '当前下载位置不可用';
    } else if (_androidFlow) {
      // Android 默认是 App 专属目录，完整路径冗长且对用户无意义，
      // 只在自定义时展示所选路径。
      subtitle = _custom == null ? '默认 · App 专属目录' : '自定义 · $effective';
    } else {
      subtitle = '${_custom == null ? '默认' : '自定义'} · $effective';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          icon: Icons.folder_rounded,
          iconColor: const Color(0xFF00897B),
          title: '下载位置',
          subtitle: subtitle,
          loading: _picking,
          onTap: _pick,
        ),
        if (_custom != null) ...[
          SettingsDivider(),
          SettingsTile(
            icon: Icons.restart_alt_rounded,
            iconColor: const Color(0xFF8D6E63),
            title: '恢复默认下载位置',
            subtitle: _androidFlow ? '回到 App 专属目录（卸载时自动清理）' : '回到系统下载目录',
            onTap: _reset,
          ),
        ],
      ],
    );
  }
}

/// 兜底弹窗的 PowerShell 脚本（WinForms FolderBrowserDialog）。
///
/// [initialDirectory] 里的 `'` 转义为 `''`（PS 单引号字符串规则）。
@visibleForTesting
String buildFolderBrowserScript(String? initialDirectory) {
  final setInitial = initialDirectory == null
      ? ''
      : "\$dlg.SelectedPath = '${initialDirectory.replaceAll("'", "''")}'\n";
  return '''
Add-Type -AssemblyName System.Windows.Forms
\$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
\$dlg.Description = '选择下载位置'
\$dlg.ShowNewFolderButton = \$true
${setInitial}if (\$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output \$dlg.SelectedPath
}
''';
}

/// 编码 PowerShell 脚本为 `-EncodedCommand` 要求的 Base64(UTF-16LE)。
///
/// 用 Base64 传脚本的动机与 explorer /select 修复相同：Dart Process 的
/// argv 重组与 powershell.exe 的命令行解析对引号/反斜杠的规则不一致，
/// 编码后参数是纯 Base64 字符，从根上绕开全部转义问题。
@visibleForTesting
String encodePowerShellScript(String script) {
  final utf16le = Uint8List.fromList(
    script.codeUnits.expand((u) => [u & 0xFF, (u >> 8) & 0xFF]).toList(),
  );
  return base64Encode(utf16le);
}
