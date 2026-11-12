import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/download_service.dart';
import 'package:shiyin_music/ui/pages/downloaded_songs_page.dart';

/// PC 下载体验两件事的回归：
/// 1. explorer /select 命令构造——路径含空格时直接 Process.run 会被
///    Dart argv 重组包引号（`"/select,D:\a b.mp3"`），explorer 解析不了
///    就退回打开默认位置（文档文件夹）；必须经 PowerShell 原样传递。
/// 2. 自定义下载目录（设置-下载位置：桌面「桌面」分节 / Android「缓存」
///    分节）的持久化与 downloadDir 优先级（override 分支平台无关）。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('buildExplorerSelectCommand', () {
    test('保持 /select,"路径" 官方形态（引号在逗号后包住路径）', () {
      expect(
        buildExplorerSelectCommand(
          'D:\\SyncUp\\Downloads\\shiyin_downloads\\周杰伦-晴天 (Live).mp3',
        ),
        'Start-Process explorer.exe -ArgumentList '
            '\'/select,"D:\\SyncUp\\Downloads\\shiyin_downloads\\周杰伦-晴天 (Live).mp3"\'',
      );
    });

    test("路径含单引号时转义为 ''，防止 PowerShell 字符串提前闭合", () {
      expect(
        buildExplorerSelectCommand("D:\\music\\Don't Stop.mp3"),
        "Start-Process explorer.exe -ArgumentList "
            "'/select,\"D:\\music\\Don''t Stop.mp3\"'",
      );
    });
  });


  group('自定义下载目录 override', () {
    test('未设置时 customDownloadDirOverride 返回 null', () async {
      expect(await DownloadService.customDownloadDirOverride(), isNull);
    });

    test('写入后可读回；空白视为未设置；清除后恢复 null', () async {
      await DownloadService.setCustomDownloadDir('D:\\MyMusic');
      expect(await DownloadService.customDownloadDirOverride(), 'D:\\MyMusic');

      // 空白字符串与 null 同义（防止脏值让下载目录解析到空路径）。
      await DownloadService.setCustomDownloadDir('   ');
      expect(await DownloadService.customDownloadDirOverride(), isNull);

      await DownloadService.setCustomDownloadDir('D:\\MyMusic');
      await DownloadService.setCustomDownloadDir(null);
      expect(await DownloadService.customDownloadDirOverride(), isNull);
    });

    test('换目录时旧自定义目录记入历史，供对账找回旧文件', () async {
      await DownloadService.setCustomDownloadDir('D:\\MusicA');
      expect(await DownloadService.customDownloadDirHistory(), isEmpty,
          reason: '首次设置无被替换值，不记历史');
      await DownloadService.setCustomDownloadDir('D:\\MusicB');
      expect(await DownloadService.customDownloadDirHistory(), ['D:\\MusicA']);
      // 同值重设不重复记录；恢复默认时当前值同样入历史。
      await DownloadService.setCustomDownloadDir('D:\\MusicB');
      expect(await DownloadService.customDownloadDirHistory(), ['D:\\MusicA']);
      await DownloadService.setCustomDownloadDir(null);
      expect(await DownloadService.customDownloadDirHistory(),
          ['D:\\MusicB', 'D:\\MusicA']);
    });

    test('ensureWritableDir：可写目录通过，文件路径/非法路径抛错', () async {
      final tmp = await Directory.systemTemp.createTemp('shiyin_dl_probe_');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dir = await DownloadService.ensureWritableDir(
        '${tmp.path}${Platform.pathSeparator}sub',
      );
      expect(dir.existsSync(), isTrue);

      // 路径指向一个已存在的文件：当目录用必失败。
      final file = File('${tmp.path}${Platform.pathSeparator}afile');
      await file.writeAsString('x');
      expect(
        () => DownloadService.ensureWritableDir(file.path),
        throwsStateError,
      );
    });

    test('downloadDir 优先使用自定义目录并确保其存在（Android/桌面共用分支）', () async {
      final tmp = await Directory.systemTemp.createTemp('shiyin_dl_override_');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final target = '${tmp.path}${Platform.pathSeparator}我的下载';
      await DownloadService.setCustomDownloadDir(target);

      final dir = await DownloadService().downloadDir();

      expect(dir.path, target);
      expect(dir.existsSync(), isTrue,
          reason: '自定义目录不存在时需自动创建，否则首个下载必失败');

      // 清除 override，不影响已创建目录；后续 downloadDir 回系统默认。
      await DownloadService.setCustomDownloadDir(null);
      expect(await DownloadService.customDownloadDirOverride(), isNull);
    });
  });
}
