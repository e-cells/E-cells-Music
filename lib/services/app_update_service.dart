import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_version.dart';

/// 应用更新检查服务（数据源：GitHub Releases，无需后端）。
///
/// CI 打 `v*` tag 时会在 GitHub 发布带附件的 Release，本服务判断是否有新版本：
/// - Android：跳浏览器下载 APK；
/// - Windows 便携版：跳浏览器下载 zip，用户自行解压覆盖；
/// - Windows 安装版：应用内下载 setup.exe（进度 + 取消，sha256 校验通过后
///   才允许安装），退出并拉起安装向导；
/// - Linux：跳浏览器下载 `.deb`（回退便携 tar.gz），用户用包管理器安装。
///
/// 完整性：CI 为每个 Release 附件生成 sidecar `<附件名>.sha256`；
/// 应用内下载路径（Windows 安装版）下载完成后拉取 sidecar 比对 sha256，
/// 不一致即删包报错，杜绝截断/损坏/被替换的安装包落地执行。
/// 跳浏览器下载的形态由用户自行核对，不在应用内校验。
///
/// 版本查询多级容灾（对齐 handwrite-sim 的 updater 策略，规避 api.github.com
/// 未鉴权 60 次/时/IP 的 403 风控）：
/// 1. GitHub REST API（信息最全）
/// 2. github.com 的 Releases Atom 订阅源 + expanded_assets 资产页（无 API 频控）
/// 3. github.com 的 /releases/latest 网页 302 重定向探测最新 tag（无频控）
///
/// 平台相关性过滤（v3.0.2 起，规范见 docs/release-process.md 的「版本适用
/// 平台标记」）：Release notes 首部「适用平台」标记行声明该版本影响的平台，
/// L1/L2 只对"影响本平台的版本"返回更新（跨版本累积判断，一次提示升到
/// 最新版）。省略标记的历史 Release 视为全平台；老客户端不解析标记也不受
/// 影响——每个 Release 永远带全平台附件，照常更新。保守边界：最近 30 个
/// （L1）/10 个（L2）版本全与本平台无关且未见版本边界时仍保守提示最新版
/// （宁多提示不漏提示）；L3 拿不到正文，不做平台过滤，维持 semver 兜底。
class AppUpdateService {
  AppUpdateService();

  /// 应用内下载安装包用 HTTP 客户端（GitHub 下载会 302 到 CDN，dio 自动跟随）。
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  /// 记录上一次"自动检查"成功请求的时间戳（毫秒），用于节流。
  static const _lastAutoCheckKey = 'update.last_auto_check_ms';

  /// 抓取 github.com 网页端点（Atom / expanded_assets）时使用的浏览器 UA。
  static const _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 是否支持检查更新（非 Web 的 Android / Windows / Linux）。
  static bool get isSupportedPlatform {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  /// Windows 分发形态：exe 同目录存在 Inno 安装时写入的
  /// `installed_by_inno.flag` 即安装版，否则便携版。首次访问时判定一次并缓存。
  static final bool isWindowsInstalledBuild = detectWindowsInstalledBuild(
    Platform.resolvedExecutable,
  );

  /// 判定 [exePath] 所在目录是否为 Inno Setup 安装形态（供测试注入路径）。
  @visibleForTesting
  static bool detectWindowsInstalledBuild(String exePath) {
    try {
      final dir = File(exePath).parent;
      return File(
        '${dir.path}${Platform.pathSeparator}installed_by_inno.flag',
      ).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 当前构建在附件选择时使用的平台参数。
  String get _rendererForAsset => _isAndroid ? AppConfig.renderer : '';

  /// 当前构建的目标 ABI（非 Android 返回 ''；ARM32 车机必须选
  /// `-arm32` APK，拿到 arm64 包无法安装）。
  String get _abiForAsset => _isAndroid ? AppConfig.abi : '';

  /// 当前构建的 Windows 形态附件参数（非 Windows 返回 ''）。
  String get _windowsAssetKind {
    if (!_isWindows) {
      return '';
    }
    return isWindowsInstalledBuild ? kWindowsAssetSetup : kWindowsAssetPortable;
  }

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 平台相关性判断用的本平台词，与 parseApplicablePlatforms 的词表同口径
  /// （'android'/'windows'/'linux'）。
  String get _myPlatformToken {
    if (_isWindows) return 'windows';
    if (_isLinux) return 'linux';
    return 'android';
  }

  /// 判断某条 Release 正文是否影响本平台（「适用平台」标记机制，见类头）。
  /// L1/L2 的 platformAffected 回调共用。
  ///
  /// 两个解析函数标了 @visibleForTesting 是为了测试直接覆盖；生产链路此
  /// 处是唯一调用点，属预期用法，ignore 掉 analyzer 的误伤。
  bool _releaseAffectsMyPlatform(String body) =>
      // ignore: invalid_use_of_visible_for_testing_member
      releaseAffectsPlatform(parseApplicablePlatforms(body), _myPlatformToken);

  /// 检查更新。
  ///
  /// - [manual] 为 true（About 页手动点击）时每次都真正请求，且错误向上抛由 UI 提示；
  /// - [manual] 为 false（启动自动检查）时受 [AppConfig.updateAutoCheckInterval] 节流，
  ///   且仅返回"是否有更新"，错误由调用方静默处理。
  ///
  /// 返回非 null 表示存在比当前版本更新的 Release。
  Future<AppVersionInfo?> checkForUpdate({bool manual = false}) async {
    if (!isSupportedPlatform) {
      return null;
    }

    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastAutoCheckKey) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsed < AppConfig.updateAutoCheckInterval.inMilliseconds) {
        return null;
      }
    }

    // 抛出的异常：手动检查由 UI 捕获并提示；自动检查由调用方静默吞掉。
    final latest = await _fetchLatestFromGitHub();

    // 仅在成功请求后记录节流时间戳（失败不记录，下次启动可重试）。
    // null = 容灾链路明确判定无更新（含"新版本均与本平台无关"），同样是
    // 成功结果，照常记录，避免每次启动都重复拉取判断。
    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _lastAutoCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    if (latest == null) {
      return null;
    }
    // L3（302 探测）拿不到平台标记与 changelog，semver 兜底比较仍需保留。
    if (compareSemver(latest.versionName, AppConfig.appVersion) <= 0) {
      return null;
    }
    return latest;
  }

  /// 多级容灾获取最新 Release：API → Atom 订阅源 → 网页重定向。
  ///
  /// 三级依次尝试，只有异常才降级；任何一级正常返回（含 null=确定无更新，
  /// 如空仓库、"新版本均与本平台无关"）即终止，不再降级。全部失败时聚合
  /// 报错（限流时给出友好文案）。
  Future<AppVersionInfo?> _fetchLatestFromGitHub() async {
    final errors = <String>[];
    var sawRateLimit = false;

    try {
      return await _fetchViaApi();
    } on StateError catch (error) {
      if (error.message.contains('限流')) sawRateLimit = true;
      errors.add(error.message);
    } catch (error) {
      errors.add('$error');
    }

    try {
      return await _fetchViaAtomFeed();
    } catch (error) {
      errors.add('$error');
    }

    try {
      return await _fetchViaRedirect();
    } catch (error) {
      errors.add('$error');
    }

    if (sawRateLimit) {
      throw StateError('检查频繁触发 GitHub 限流，请稍后再试');
    }
    throw StateError('请求 GitHub 失败（${errors.join('；')}）');
  }

  /// L1：GitHub REST API 列表接口（信息最全，但受 60 次/时/IP 限制）。
  ///
  /// 取最近 30 个 Release（含预发布）做平台相关性选版：全部新版本均不
  /// 影响本平台时返回 null（确定无更新），见 selectRelevantUpdate。
  Future<AppVersionInfo?> _fetchViaApi() async {
    final response = await http
        .get(
          Uri.parse(AppConfig.githubReleasesListUrl),
          headers: const {
            'User-Agent': AppConfig.githubUpdateUserAgent,
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 403 || response.statusCode == 429) {
      throw StateError('GitHub 接口限流（${response.statusCode}）');
    }
    if (response.statusCode != 200) {
      throw StateError('请求 GitHub 失败（${response.statusCode}）');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw StateError('GitHub 返回数据格式异常');
    }
    if (decoded.isEmpty) {
      // 空仓库（从未发过 Release）→ 确定无更新，不再降级重试其它通道。
      return null;
    }

    final releases = <Map<String, dynamic>>[];
    final summaries = <ReleaseEntrySummary>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final tag = item['tag_name']?.toString() ?? '';
      // 跳过预发布 tag：列表接口含预发布，而 compareSemver 会把
      // `v3.1.0-beta` 当 3.1.0 比较——不过滤会把 beta 当正式版提示，
      // 与 L2（parseEntriesFromAtom）/L3（/releases/latest 天然排除）语义分叉。
      if (tag.isEmpty || !isStableVersionTag(tag)) continue;
      final body = item['body'];
      releases.add(item);
      summaries.add(
        ReleaseEntrySummary(tag: tag, body: body is String ? body : ''),
      );
    }
    if (summaries.isEmpty) {
      return null;
    }

    final selection = selectRelevantUpdate(
      summaries,
      currentVersion: AppConfig.appVersion,
      platformAffected: _releaseAffectsMyPlatform,
    );
    if (selection == null) {
      return null;
    }

    // 选版摘要只带 tag/body，附件与元数据回到 newest 对应的原始 JSON 取。
    final newestJson = releases.firstWhere(
      (release) =>
          (release['tag_name']?.toString() ?? '') == selection.newest.tag,
      orElse: () => const <String, dynamic>{},
    );
    return AppVersionInfo.fromGitHubRelease(
      newestJson,
      renderer: _rendererForAsset,
      abi: _abiForAsset,
      windowsAssetKind: _windowsAssetKind,
      linuxAsset: _isLinux,
    ).copyWith(updateContent: _joinReleaseNotes(selection));
  }

  /// L2：Releases Atom 订阅源取版本与正文，expanded_assets 补附件直链
  /// （都在 github.com 域，不占 API 频次）。与 L1 同样做平台相关性选版，
  /// 只是 feed 只有约 10 条、正文需从 HTML 转 Markdown。
  Future<AppVersionInfo?> _fetchViaAtomFeed() async {
    final xml = await _getText(Uri.parse(AppConfig.githubReleasesAtomUrl));
    final entries = parseEntriesFromAtom(xml);
    if (entries.isEmpty) {
      // 仓库从未发布过 Release 时 Atom 为空 feed，语义与 L1 空列表一致。
      return null;
    }
    final summaries = [
      for (final (tag, _, contentHtml) in entries)
        ReleaseEntrySummary(
          tag: tag,
          body: htmlReleaseBodyToMarkdown(unescapeHtml(contentHtml)),
        ),
    ];
    final selection = selectRelevantUpdate(
      summaries,
      currentVersion: AppConfig.appVersion,
      platformAffected: _releaseAffectsMyPlatform,
    );
    if (selection == null) {
      return null;
    }
    // newest 的 release 页链接优先用 Atom 条目自带链接（避免再拼 URL）。
    final newestEntry = entries.firstWhere(
      (entry) => entry.$1 == selection.newest.tag,
      orElse: () => entries.first,
    );
    return _assembleFromTag(
      tag: newestEntry.$1,
      releasePageOverride: newestEntry.$2,
      updateContent: _joinReleaseNotes(selection),
    );
  }

  /// L3：/releases/latest 网页 302 重定向探测最新 tag，再走 expanded_assets
  /// 补附件直链（此路径拿不到正文，提示用户前往发布页查看）。
  ///
  /// 返回类型与 L1/L2 统一为 nullable（正常结果永远非 null；此通道拿不到
  /// notes 正文，不做平台过滤，旧不旧交给 checkForUpdate 的 semver 兜底）。
  Future<AppVersionInfo?> _fetchViaRedirect() async {
    final request = http.Request(
      'GET',
      Uri.parse(AppConfig.githubReleasesLatestPageUrl),
    )..followRedirects = false;

    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 404) {
        throw StateError('暂无发布版本');
      }
      final tag = extractTagFromLocation(response.headers['location'] ?? '');
      if (tag == null) {
        throw StateError('重定向探测失败（${response.statusCode}）');
      }
      // /releases/latest 只指向最新正式版：探测到预发布 tag（仓库最新
      // Release 是 beta 时）对齐 L1 语义视为"暂无正式版本"，不推 beta。
      if (!isStableVersionTag(tag)) {
        throw StateError('暂无正式发布版本');
      }
      return await _assembleFromTag(
          tag: tag, updateContent: '更新说明获取失败，请前往发布页查看。');
    } finally {
      client.close();
    }
  }

  /// 由 tag 组装 [AppVersionInfo]（L2/L3 共用），附件直链尽力从
  /// expanded_assets 资产页补全。
  Future<AppVersionInfo> _assembleFromTag({
    required String tag,
    required String updateContent,
    String releasePageOverride = '',
  }) async {
    final versionName = stripVersionTagPrefix(tag);
    final releasePage = releasePageOverride.isNotEmpty
        ? releasePageOverride
        : '${AppConfig.githubRepoUrl}/releases/tag/$tag';
    final assets = await _tryFetchExpandedAssets(tag);
    final picked = pickUpdateAssetUrl(
      assets,
      renderer: _rendererForAsset,
      abi: _abiForAsset,
      windowsAssetKind: _windowsAssetKind,
      linuxAsset: _isLinux,
    );

    return AppVersionInfo(
      platform: _isWindows
          ? AppUpdatePlatform.windows.apiValue
          : _isLinux
          ? AppUpdatePlatform.linux.apiValue
          : AppUpdatePlatform.android.apiValue,
      versionName: versionName.isEmpty ? tag : versionName,
      versionCode: semverToCode(versionName),
      updateContent: updateContent,
      downloadUrl: picked.isNotEmpty ? picked : releasePage,
      forceUpdate: false,
    );
  }

  /// 把选版结果中影响本平台的条目（旧→新）拼成一段 changelog 正文：
  /// 用户可能一次跨过多个无关版本，提示里要能看到期间与本平台相关的变更。
  String _joinReleaseNotes(RelevantUpdateSelection selection) {
    return selection.relevant
        .map(
          (entry) =>
              '## ${entry.tag}\n\n${stripReleaseDownloadSection(entry.body.trim())}',
        )
        .join('\n\n');
  }

  /// 请求 github.com 网页端点（浏览器 UA，非 API 域）。
  Future<String> _getText(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await http
        .get(uri, headers: const {'User-Agent': _browserUserAgent})
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('请求 GitHub 失败（${response.statusCode}）');
    }
    return response.body;
  }

  /// 抓取 expanded_assets 资产页解析附件直链；失败不影响版本判断（尽力而为）。
  Future<List<(String, String)>> _tryFetchExpandedAssets(String tag) async {
    try {
      final html = await _getText(
        Uri.parse(
          '${AppConfig.githubRepoUrl}/releases/expanded_assets/'
          '${Uri.encodeComponent(tag)}',
        ),
      );
      return parseExpandedAssetLinks(html);
    } catch (_) {
      return const [];
    }
  }

  /// 在外部浏览器打开更新包链接（直链附件，或回退的 Release 页面）。
  ///
  /// Android / Windows 便携版的主路径，也是 Windows 安装版"浏览器下载"入口。
  Future<void> downloadAndInstall(AppVersionInfo version) async {
    if (!version.hasDownloadUrl) {
      throw StateError('更新包下载地址为空');
    }

    final uri = Uri.tryParse(version.downloadUrl);
    if (uri == null) {
      throw StateError('更新包下载地址无效');
    }

    final success = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!success) {
      throw StateError('无法在浏览器中打开下载链接');
    }
  }

  /// 应用内下载 Windows 安装包到系统"下载"目录，返回本地文件路径。
  ///
  /// 进度经 [onProgress]（累计已收 / 总字节）回调；[cancelToken] 取消后
  /// 残留的部分文件会被清理。完成后依次校验：文件大小大于 0、
  /// sha256 与 Release 的 sidecar（`<附件名>.sha256`，见类注释）一致。
  /// sidecar 不存在（2026-09 之前的老 Release）时仅记录日志跳过校验，
  /// 保持向后兼容；sidecar 存在但不一致/不可解析一律视为损坏，删包报错。
  Future<String> downloadWindowsSetup(
    AppVersionInfo version, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = version.downloadUrl;
    final uri = Uri.tryParse(url);
    if (uri == null || !url.toLowerCase().endsWith('.exe')) {
      throw StateError('安装包下载地址无效（未找到 setup.exe 附件）');
    }

    final downloadsDir =
        await getDownloadsDirectory() ?? await getTemporaryDirectory();
    // versionName 可能来自 L2 的 Atom 标题回退/自由文本，清洗非法字符
    // 并截长，避免 destPath 成为非法 Windows 路径（下载必失败且报错
    // 是底层 FileSystemException 文案）。
    final safeVersion = version.versionName
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final destPath =
        '${downloadsDir.path}${Platform.pathSeparator}'
        'ShiYinMusic-Setup-v${safeVersion.isEmpty ? 'unknown' : safeVersion}.exe';

    try {
      await _dio.download(
        uri.toString(),
        destPath,
        cancelToken: cancelToken,
        options: Options(
          headers: const {'User-Agent': AppConfig.githubUpdateUserAgent},
        ),
        onReceiveProgress: onProgress,
      );
    } catch (error) {
      // 取消/中断时清掉写了一半的文件，避免下次误装损坏包。
      final file = File(destPath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (deleteError) {
          // 文件被占用（如杀软扫描）时删除失败：坏包残留下载目录，
          // 用户可能手动误双击，必须留日志。
          debugPrint('[AppUpdate] 清理半成品安装包失败: $deleteError');
        }
      }
      if (error is DioException && error.type == DioExceptionType.cancel) {
        throw StateError('已取消下载');
      }
      rethrow;
    }

    final file = File(destPath);
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('安装包下载不完整');
    }

    // 完整性校验：sha256 sidecar（缺失时跳过，见方法注释）。
    try {
      await _verifySha256Sidecar(uri, file);
    } on StateError {
      rethrow;
    } catch (error) {
      debugPrint('[AppUpdate] sha256 sidecar 校验异常（按损坏处理）: $error');
      try {
        await file.delete();
      } catch (deleteError) {
        debugPrint('[AppUpdate] 删除校验失败的安装包失败: $deleteError');
      }
      throw StateError('安装包完整性校验失败');
    }
    return destPath;
  }

  /// 拉取 `<asset>.sha256` sidecar 并与本地文件比对。
  ///
  /// - sidecar 404/不存在：仅日志，视为通过（老 Release 兼容）；
  /// - sidecar 内容无法解析出 64 位 hex：视为校验失败（损坏/被篡改的
  ///   sidecar 本身就是异常信号）；
  /// - hex 不一致：删包并抛错（截断、CDN 损坏或被替换）。
  Future<void> _verifySha256Sidecar(Uri assetUri, File file) async {
    final sidecarUrl = '${assetUri.toString()}.sha256';
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse(sidecarUrl),
            headers: const {'User-Agent': _browserUserAgent},
          )
          .timeout(const Duration(seconds: 15));
    } on Exception catch (error) {
      // 拉取失败（网络抖动等）不拦截安装：本地文件已完整下载，
      // 风险与老 Release 相同。宁可放过不可误杀。
      debugPrint('[AppUpdate] sha256 sidecar 拉取失败（跳过校验）: $error');
      return;
    }
    if (response.statusCode == HttpStatus.notFound) {
      debugPrint('[AppUpdate] Release 无 sha256 sidecar（老版本），跳过校验');
      return;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('校验文件下载失败（${response.statusCode}）');
    }

    // sha256sum 输出格式：`<hex>  <filename>`（二进制模式带 `*` 前缀）。
    final hexMatch = RegExp(
      r'^([0-9a-fA-F]{64})',
      multiLine: true,
    ).firstMatch(response.body);
    if (hexMatch == null) {
      throw StateError('校验文件格式异常');
    }
    final expected = hexMatch.group(1)!.toLowerCase();

    final digest = await sha256.bind(file.openRead()).first;
    final actual = digest.toString();
    if (actual != expected) {
      try {
        await file.delete();
      } catch (deleteError) {
        debugPrint('[AppUpdate] 删除校验不一致的安装包失败: $deleteError');
      }
      throw StateError('安装包校验不一致（本地 $actual ≠ 发布 $expected），已删除，请重试');
    }
    debugPrint('[AppUpdate] sha256 校验通过: $actual');
  }

  /// 拉起安装向导（Windows 安装版"退出并安装"第一步）。
  ///
  /// detached 启动使向导独立于本进程存活；本应用进程的退出由调用方
  /// 走 [DesktopWindow.quitGracefully]（落盘几何 + 刷写播放队列等退出前
  /// 钩子后硬终止）——此前这里直接 exit(0)，既绕过退出前刷写（更新后
  /// 播放队列回退一首、窗口几何不保存），也会在 IME/UIA 环境下因 DLL
  /// 静态析构触发 flutter_windows.dll 的 use-after-free 崩溃（见
  /// DesktopWindow.quitGracefully 注释的实测记录）。硬终止同样释放
  /// 音频设备、悬浮歌词窗与下载句柄，不存在文件占用问题（Inno 侧
  /// CloseApplications=yes 再兜底其他残留副本）。
  Future<void> launchWindowsInstaller(String setupPath) async {
    final file = File(setupPath);
    if (!await file.exists()) {
      throw StateError('安装包不存在：$setupPath');
    }
    await Process.start(setupPath, [], mode: ProcessStartMode.detached);
  }
}

/// 一个 Release 的选版摘要（tag、版本名、可读正文）。
@visibleForTesting
class ReleaseEntrySummary {
  final String tag;
  final String body;
  const ReleaseEntrySummary({required this.tag, required this.body});

  /// 版本名 = tag 去掉 `v` 前缀，与 AppVersionInfo 的口径一致。
  String get versionName => stripVersionTagPrefix(tag);
}

/// 平台相关性选版结果。
@visibleForTesting
class RelevantUpdateSelection {
  /// 应提示与下载的条目（最新版，一步到位）。
  final ReleaseEntrySummary newest;

  /// 影响本平台且 >当前 的条目（旧→新，拼 changelog）。
  final List<ReleaseEntrySummary> relevant;

  /// true=翻页窗口内未见"≤当前"边界，无法确定无关，保守提示最新版。
  final bool conservativeFallback;

  const RelevantUpdateSelection({
    required this.newest,
    required this.relevant,
    required this.conservativeFallback,
  });
}

/// 选版：给定最近若干 Release（任意顺序）+ 当前版本 + 平台影响判定。
///
/// - 全部条目 ≤ 当前 → null（无任何新版本）；
/// - 存在 >当前 且影响本平台的条目 → 返回（newest=全部条目中最新的那个，
///   relevant=影响本平台且>当前的条目按版本升序）；
/// - >当前 的条目均不影响本平台：
///   - 页内可见"≤当前"条目（边界）→ null（确定与本平台无关）；
///   - 页内全部 >当前（边界在更早的翻页外）→ 保守返回（newest 提示，
///     relevant=[newest]）——连续 30 个（API）/10 个（Atom）无关版本才触发，
///     宁可多提示不漏提示。
@visibleForTesting
RelevantUpdateSelection? selectRelevantUpdate(
  List<ReleaseEntrySummary> entries, {
  required String currentVersion,
  required bool Function(String body) platformAffected,
}) {
  // 空列表（调用方已提前判空）视为无任何新版本，保持纯函数自洽。
  if (entries.isEmpty) {
    return null;
  }
  // newest 用 semver 取全部条目最大者（不依赖列表顺序，乱序输入也正确）。
  var newest = entries.first;
  for (final entry in entries) {
    if (compareSemver(entry.versionName, newest.versionName) > 0) {
      newest = entry;
    }
  }
  // 边界判定：页内存在 ≤当前 的条目，说明翻页窗口覆盖了"当前版本之前"，
  // 页内无关的新版本即可断定与本平台无关。
  final sawCurrentOrOlder = entries.any(
    (entry) => compareSemver(entry.versionName, currentVersion) <= 0,
  );
  final newer = entries
      .where((entry) => compareSemver(entry.versionName, currentVersion) > 0)
      .toList();
  if (newer.isEmpty) {
    return null;
  }

  final relevantNewer =
      newer.where((entry) => platformAffected(entry.body)).toList()
        ..sort((a, b) => compareSemver(a.versionName, b.versionName));
  if (relevantNewer.isNotEmpty) {
    return RelevantUpdateSelection(
      newest: newest,
      relevant: relevantNewer,
      conservativeFallback: false,
    );
  }
  if (sawCurrentOrOlder) {
    return null;
  }
  // 页内全部 >当前 且均与本平台无关：边界可能在更早的翻页外（历史上有过
  // 30+ 个连续无关版本），无法排除"更早处有影响本平台的未装版本"，保守提示。
  return RelevantUpdateSelection(
    newest: newest,
    relevant: [newest],
    conservativeFallback: true,
  );
}

/// 解析 Atom 订阅源全部条目（feed 顺序即最新在前，约 10 条），返回
/// `(tag, release 页链接, 转义状态的正文 HTML)` 列表。逐条跳过非正式版
/// tag（保持 isStableVersionTag 语义与 title 回退逻辑，只是不再只取
/// 第一个而是收集全部）。空 feed 返回空列表。
@visibleForTesting
List<(String, String, String)> parseEntriesFromAtom(String feedXml) {
  final entries = <(String, String, String)>[];
  var cursor = 0;
  while (true) {
    final entryStart = feedXml.indexOf('<entry>', cursor);
    if (entryStart < 0) {
      return entries;
    }
    final entryEndRel = feedXml.indexOf('</entry>', entryStart);
    final entryEnd = entryEndRel < 0 ? feedXml.length : entryEndRel;
    final entry = feedXml.substring(entryStart, entryEnd);
    cursor = entryEnd;

    var tag = '';
    var link = '';
    final linkMatch = RegExp(
      r'href="([^"]+/releases/tag/([^"]+))"',
    ).firstMatch(entry);
    if (linkMatch != null) {
      tag = unescapeHtml(linkMatch.group(2) ?? '');
      link = unescapeHtml(linkMatch.group(1) ?? '');
    }
    if (tag.isEmpty) {
      final titleMatch = RegExp('<title>([^<]+)</title>').firstMatch(entry);
      if (titleMatch == null) {
        continue;
      }
      final title = (titleMatch.group(1)?.trim() ?? '');
      // 标题回退仅在它本身就是合法正式版 tag 时采用，杜绝把发版者
      // 自由填写的 Release 标题当版本号（非法字符进文件名/版本比较）。
      if (!isStableVersionTag(title)) {
        continue;
      }
      tag = title;
    }
    if (tag.isEmpty || !isStableVersionTag(tag)) {
      continue;
    }

    final contentMatch = RegExp(
      r'<content[^>]*>([\s\S]*?)</content>',
    ).firstMatch(entry);
    final content = contentMatch?.group(1) ?? '';

    entries.add((tag, link, content));
  }
}

/// 反转义常见 HTML 实体（`&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&nbsp;`
/// 及十/十六进制数字实体）；未知实体原样保留。
@visibleForTesting
String unescapeHtml(String input) {
  return input.replaceAllMapped(
    RegExp(r'&(#[xX]?[0-9A-Fa-f]+|[a-zA-Z][a-zA-Z0-9]*);'),
    (match) {
      final entity = match.group(1)!;
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      if (entity.startsWith('#')) {
        final hex = entity.startsWith('#x') || entity.startsWith('#X');
        final code = int.tryParse(
          entity.substring(hex ? 2 : 1),
          radix: hex ? 16 : 10,
        );
        if (code != null) {
          return String.fromCharCode(code);
        }
      }
      // 未知实体原样保留。
      return match.group(0)!;
    },
  );
}

/// 把 Atom `<content>` 中转义后的 Release 正文 HTML 转为可读的伪 Markdown：
/// h2/h3/h4 映射为 `##` 标题、li 映射为 `- `、code 映射为反引号、
/// strong/b 映射为 `**`，其余标签剥离并按块级元素换行。
@visibleForTesting
String htmlReleaseBodyToMarkdown(String html) {
  String replacementFor(String name, bool isClose) {
    // 开标签专属映射（标题/列表只看开标签，配对闭标签输出空串）。
    if (!isClose) {
      switch (name) {
        case 'h2':
          return '\n\n## ';
        case 'h3':
          return '\n\n### ';
        case 'h4':
          return '\n\n#### ';
        case 'li':
          return '\n- ';
      }
    }
    // 开闭标签同形的映射。
    return switch (name) {
      'strong' || 'b' => '**',
      'code' => '`',
      'br' => '\n',
      'p' ||
      'div' ||
      'ul' ||
      'ol' ||
      'table' ||
      'tr' ||
      'blockquote' ||
      'pre' ||
      'section' => '\n',
      _ => '',
    };
  }

  final out = StringBuffer();
  final tagPattern = RegExp(r'<(/?)([a-zA-Z0-9]+)[^>]*>');
  var rest = html;
  while (true) {
    final match = tagPattern.firstMatch(rest);
    if (match == null) {
      out.write(rest);
      break;
    }
    out.write(rest.substring(0, match.start));
    out.write(
      replacementFor(
        (match.group(2) ?? '').toLowerCase(),
        match.group(1) == '/',
      ),
    );
    rest = rest.substring(match.end);
  }

  var text = out.toString();
  // GitHub 会把 <li> 内容包进 <p>，标签转换后 "- " 标记与内容被换行拆开，
  // 先把悬空标记行与其后内容（含多个空行）合并，再压缩连续空行。
  text = text.replaceAll(RegExp(r'\n[ \t]*-[ \t]*\n+'), '\n- ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 解析 expanded_assets 资产页 HTML，提取附件 `(文件名, 直链)` 列表：
/// 取 `href="/<owner>/<repo>/releases/download/<tag>/<文件名>"` 形式的链接，
/// 忽略源码包（/archive/）与重复项。
@visibleForTesting
List<(String, String)> parseExpandedAssetLinks(String html) {
  final assets = <(String, String)>[];
  final pattern = RegExp(r'href="(/[^"]+/releases/download/[^"]+)"');
  for (final match in pattern.allMatches(html)) {
    final path = match.group(1)!;
    if (path.contains('/archive/')) {
      continue;
    }
    final name = path.substring(path.lastIndexOf('/') + 1);
    if (name.isEmpty) {
      continue;
    }
    final lower = name.toLowerCase();
    const accepted = ['.zip', '.exe', '.apk', '.deb', '.tar.gz'];
    if (!accepted.any(lower.endsWith)) {
      continue;
    }
    if (assets.any((asset) => asset.$1 == name)) {
      continue;
    }
    assets.add((name, 'https://github.com$path'));
  }
  return assets;
}

/// 从 /releases/latest 的 302 Location（`…/releases/tag/vX.Y.Z…`）提取 tag。
@visibleForTesting
String? extractTagFromLocation(String location) {
  final marker = '/releases/tag/';
  final index = location.indexOf(marker);
  if (index < 0) {
    return null;
  }
  final tail = location.substring(index + marker.length);
  final tag = tail.split(RegExp(r'[/?#]')).first;
  return tag.isEmpty ? null : tag;
}
