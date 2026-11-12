import 'dart:convert';
import 'dart:io';

import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/ui/settings/download_location_settings.dart';

/// 「下载位置」设置项：
/// 1. file_picker 失败时的 PowerShell WinForms 兜底：脚本构造与
///    -EncodedCommand 编码的确定性（桌面）；
/// 2. Android 流程（宿主单测经 debugForceAndroidFlow 强制）：
///    权限前置（拒绝不开选择器 / 通过后选目录保存 / API30+ 跳设置页
///    返回后续走）、写探测失败不落库。
void main() {
  group('buildFolderBrowserScript', () {
    test('含初始目录时设置 SelectedPath，路径原样保留', () {
      final script = buildFolderBrowserScript(
        r'D:\SyncUp\Downloads\shiyin_downloads',
      );
      expect(
        script,
        contains(r"$dlg.SelectedPath = 'D:\SyncUp\Downloads\shiyin_downloads'"),
      );
      expect(script, contains('FolderBrowserDialog'));
      // 取消时不输出：stdout 为空即 null。
      expect(script, contains('DialogResult]::OK'));
    });

    test('无初始目录时不设置 SelectedPath', () {
      final script = buildFolderBrowserScript(null);
      expect(script, isNot(contains('SelectedPath =')));
    });

    test("路径含单引号时转义为 '' 防止 PS 字符串提前闭合", () {
      final script = buildFolderBrowserScript(r"D:\Hank's Music");
      expect(script, contains(r"$dlg.SelectedPath = 'D:\Hank''s Music'"));
    });
  });

  group('encodePowerShellScript', () {
    test('输出为 Base64 的 UTF-16LE，可无损还原', () {
      const script = "Write-Output '/select,\"D:\\a b\\周杰伦.mp3\"'";
      final encoded = encodePowerShellScript(script);

      // Base64 还原出 UTF-16LE 字节，再按 UTF-16LE 解回原字符串。
      final bytes = base64Decode(encoded);
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      expect(String.fromCharCodes(units), script);
    });
  });

  // ===== Android 流程（debugForceAndroidFlow 强制，宿主可跑） =====

  group('Android 下载位置流程', () {
    const storageChannel = MethodChannel('shiyin_music/storage_access');

    /// 权限桥应答队列：requestWritePermission / hasWritePermission 依次
    /// 出队；队列空时返回默认值（has→false / request→false）。
    late List<bool?> requestAnswers;
    late List<bool> hasAnswers;
    late _FakeDirectoryPicker picker;
    late FilePickerPlatform originalPicker;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      DownloadLocationSettings.debugForceAndroidFlow = true;
      requestAnswers = [];
      hasAnswers = [];
      picker = _FakeDirectoryPicker();
      originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            switch (call.method) {
              case 'requestWritePermission':
                return requestAnswers.isEmpty
                    ? false
                    : requestAnswers.removeAt(0);
              case 'hasWritePermission':
                return hasAnswers.isEmpty ? false : hasAnswers.removeAt(0);
            }
            return null;
          });
    });

    tearDown(() async {
      DownloadLocationSettings.debugForceAndroidFlow = false;
      FilePickerPlatform.instance = originalPicker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    Future<void> pumpTile(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DownloadLocationSettings())),
      );
      // _load() 异步完成后副标题才就位。
      await tester.pumpAndSettle();
    }

    /// tap 后让组件内部链路（权限 mock → 选择器桩 → ensureWritableDir 的
    /// 真实异步文件 IO → prefs 保存 → _load）跑完。
    ///
    /// testWidgets 的测试 zone 是 fakeAsync：真实文件 IO（create/
    /// writeAsString 等）的完成事件落在真实事件循环，而 await 它们的
    /// 续体排在 fake 微任务队列——两边都不自己动（本组首版四个用例
    /// 全数 10 分钟超时的根因）。必须「乒乓」推进：runAsync 段让真实
    /// 事件循环转一步（IO 完成），pump 段排空 fake 微任务（链路推进
    /// 到下一个 IO）。组件链路共 3-4 个串行 IO 跳，留足 12 轮余量。
    Future<void> tapAndDrain(WidgetTester tester) async {
      await tester.tap(find.text('下载位置'));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }

    testWidgets('权限被拒：不开选择器、不写 override', (tester) async {
      requestAnswers.add(false);
      await pumpTile(tester);

      await tapAndDrain(tester);

      expect(picker.callCount, 0, reason: '权限被拒不应打开目录选择器');
      expect(await DownloadService.customDownloadDirOverride(), isNull);
    });

    testWidgets('权限通过：选目录→写探测→保存 override', (tester) async {
      // 同步建/删临时目录：裸 await 的异步 IO 在 testWidgets zone 挂死。
      final tmp = Directory.systemTemp.createTempSync('shiyin_dl_android_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      requestAnswers.add(true);
      picker.nextPath = '${tmp.path}${Platform.pathSeparator}我的车机音乐';
      await pumpTile(tester);

      await tapAndDrain(tester);

      expect(picker.callCount, 1);
      expect(
        await DownloadService.customDownloadDirOverride(),
        picker.nextPath,
      );
      // 副标题切到自定义态，并出现「恢复默认」入口。
      expect(find.textContaining('自定义 · '), findsOneWidget);
      expect(find.text('恢复默认下载位置'), findsOneWidget);
    });

    testWidgets('所选位置不可写（探测失败）：不落库', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('shiyin_dl_probe_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      // 选到的“目录”其实是个文件：ensureWritableDir 必抛错。
      final file = File('${tmp.path}${Platform.pathSeparator}occupied');
      file.writeAsStringSync('x');
      requestAnswers.add(true);
      picker.nextPath = file.path;
      await pumpTile(tester);

      await tapAndDrain(tester);

      expect(picker.callCount, 1);
      expect(
        await DownloadService.customDownloadDirOverride(),
        isNull,
        reason: '写探测失败时不得把不可写路径存成下载位置',
      );
    });

    testWidgets('API30+ 跳「所有文件访问」设置：返回并授权后自动续走选目录', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('shiyin_dl_resume_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      // 第一次 request：null（已跳系统设置页）；resume 重查 has=true，
      // _pick 重走 request：true（已授权直接放行）。
      requestAnswers.addAll([null, true]);
      hasAnswers.add(true);
      picker.nextPath = tmp.path;
      await pumpTile(tester);

      await tester.tap(find.text('下载位置'));
      await tester.pumpAndSettle();
      expect(picker.callCount, 0, reason: '跳权限设置页期间不应打开选择器');
      expect(await DownloadService.customDownloadDirOverride(), isNull);

      // 用户从系统设置返回：生命周期 observer 自动续走（链路含真实
      // 文件 IO，须按 tapAndDrain 注释的「乒乓」推进）。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(picker.callCount, 1);
      expect(await DownloadService.customDownloadDirOverride(), tmp.path);
    });

    testWidgets('恢复默认：清除 override，副标题回到默认态', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('shiyin_dl_reset_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await DownloadService.setCustomDownloadDir(tmp.path);
      await pumpTile(tester);
      expect(find.text('恢复默认下载位置'), findsOneWidget);

      await tester.tap(find.text('恢复默认下载位置'));
      await tester.pumpAndSettle();

      expect(await DownloadService.customDownloadDirOverride(), isNull);
      expect(find.text('恢复默认下载位置'), findsNothing);
      // 宿主无 path_provider，恢复默认后副标题为「不可用」而非「默认 · …」，
      // 具体文案不在此断言（真机上必然解析成功）。
    });
  });
}

/// 只实现 getDirectoryPath 的 file_picker 平台桩：记录调用次数并可
/// 注入返回路径（null 模拟用户取消）。
class _FakeDirectoryPicker extends FilePickerPlatform {
  int callCount = 0;
  String? nextPath;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    callCount++;
    return nextPath;
  }
}
