import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        defaultTargetPlatform,
        visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../../services/storage_access_service.dart';
import '../form_factor.dart';
import '../widgets/app_song_row.dart';
import '../widgets/app_dialog.dart';
import '../widgets/artwork.dart';
import '../widgets/desktop_song_table_row.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import '../player/song_tap_handler.dart';
import 'artist_detail_page.dart';

/// 已下载歌曲与播放缓存管理页。
class DownloadedSongsPage extends StatefulWidget {
  const DownloadedSongsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    this.activationRevision,
    this.isActive,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  /// 桌面保活栈（LazyIndexedStack）专用：分区切换的修订号通知。
  /// 未被 LRU 淘汰时本页 [State] 常驻，切回靠本通知在"重新成为当前分区"
  /// 时再触发对账；若已被淘汰则重建走 [State.initState] 的打开对账，
  /// 两条路径互补。移动端按路由 push 每次全新构建，两个参数为 null，
  /// 行为与之前完全一致。
  final ValueListenable<int>? activationRevision;

  /// 配合 [activationRevision]：修订号变化时本回调返回 true 表示本页
  /// 正成为当前分区。由宿主（desktop_shell）以 contentIndex 判定。
  final bool Function()? isActive;

  @override
  State<DownloadedSongsPage> createState() => _DownloadedSongsPageState();
}

class _DownloadedSongsPageState extends State<DownloadedSongsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _reconciling = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // 打开即对账：运行期间在文件管理器里删除/移动的文件，进入本页时
    // 同步移除条目并提示（启动时 initialize 已静默对账过一次，此处
    // 覆盖会话期间的变动；无变动时零感知）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcileOnOpen());
    // 桌面保活栈：切回本分区时再次对账（见 widget.activationRevision 注释）
    widget.activationRevision?.addListener(_onActivationRevision);
  }

  @override
  void dispose() {
    widget.activationRevision?.removeListener(_onActivationRevision);
    _tabController.dispose();
    super.dispose();
  }

  void _onActivationRevision() {
    if (widget.isActive?.call() ?? false) {
      _reconcileOnOpen();
    }
  }

  Future<void> _reconcileOnOpen() async {
    if (_reconciling) return; // 快速反复切换分区时跳过重叠对账
    _reconciling = true;
    try {
      final removed = await widget.downloads.reconcileDownloads();
      if (removed > 0 && mounted) {
        Toast.show('检测到 $removed 首下载文件已被移动或删除，已从下载列表移除');
      }
    } finally {
      _reconciling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已下载'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '已下载'),
            Tab(text: '播放缓存'),
          ],
        ),
      ),
      body: AdaptiveContentPadding(
        // 悬浮迷你播放条：桌面形态由 MiniPlayerSlot 内部收敛为 shrink，
        // 移动端/车机有播放时浮在列表底部（歌单/历史页同款挂法）。
        child: Stack(
          children: [
            TabBarView(
              controller: _tabController,
              children: [
                _DownloadedList(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                  downloads: widget.downloads,
                ),
                _PlayCacheList(downloads: widget.downloads),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 10,
              child: MiniPlayerSlot(
                player: widget.player,
                auth: widget.auth,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已下载列表。
class _DownloadedList extends StatelessWidget {
  const _DownloadedList({
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 同时监听下载列表与播放器，保证当前播放歌曲高亮随播放状态刷新
      animation: Listenable.merge([downloads, player]),
      builder: (context, _) {
        final entries = downloads.downloadEntries;
        final completed = entries
            .where((e) => e.status == DownloadStatus.downloaded)
            .toList();
        final downloading = entries
            .where((e) => e.status == DownloadStatus.downloading)
            .toList();
        final failed = entries
            .where((e) => e.status == DownloadStatus.failed)
            .toList();

        if (entries.isEmpty) {
          return _emptyState(context, '还没有已下载歌曲', '下载歌曲后可离线播放');
        }

        // PC 桌面端：已完成列表表格化（歌曲/歌手/专辑/时长），
        // 删除/打开文件夹/查看路径操作接进行内 `...` 与右键 anchored 菜单。
        if (isDesktopFormFactor) {
          return _buildDesktopResults(
            context,
            completed: completed,
            downloading: downloading,
            failed: failed,
          );
        }

        return ListView(
          children: [
            if (completed.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                child: Row(
                  children: [
                    Text(
                      '已下载 ${completed.length} 首',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _confirmClearAll(context),
                      child: const Text('清空全部'),
                    ),
                  ],
                ),
              ),
              ...completed.map(
                (entry) => _DownloadedSongRow(
                  entry: entry,
                  api: api,
                  auth: auth,
                  player: player,
                  downloads: downloads,
                ),
              ),
            ],
            if (downloading.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Text(
                  '下载中 ${downloading.length} 首',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...downloading.map((entry) => _DownloadingRow(entry: entry)),
            ],
            if (failed.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Text(
                  '下载失败 ${failed.length} 首',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              ...failed.map(
                (entry) => _FailedRow(entry: entry, downloads: downloads),
              ),
            ],
            // 悬浮播放条占位：滑到底时末行不被盖住。
            const SizedBox(height: 84),
          ],
        );
      },
    );
  }

  /// PC 桌面端表格化布局：粘性表头（36px）+ 固定行高 44px 数据行，
  /// 与排行/歌手/搜索页的表格几何契约一致；下载中/失败分区沿用原行组件。
  Widget _buildDesktopResults(
    BuildContext context, {
    required List<DownloadEntry> completed,
    required List<DownloadEntry> downloading,
    required List<DownloadEntry> failed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
            child: Row(
              children: [
                Text(
                  '已下载 ${completed.length} 首',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _confirmClearAll(context),
                  child: const Text('清空全部'),
                ),
              ],
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: DesktopSongTableStickyHeaderDelegate(
            child: Container(
              color: colorScheme.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const DesktopSongTableHeader(
                selecting: false,
                allSelected: false,
                onToggleSelectAll: null,
              ),
            ),
          ),
        ),
        SliverFixedExtentList(
          itemExtent: DesktopSongTableRow.rowHeight,
          delegate: SliverChildBuilderDelegate((context, index) {
            final entry = completed[index];
            return DesktopSongTableRow(
              song: entry.song,
              index: index + 1,
              player: player,
              auth: auth,
              canDelete: false,
              selecting: false,
              selected: false,
              isFocused: false,
              onTap: () {},
              onDoubleTap: () => player.playSong(entry.song),
              onPlay: () => player.playSong(entry.song),
              onAddToPlaylist: () => showAddToPlaylistSheet(
                context: context,
                auth: auth,
                song: entry.song,
              ),
              onDelete: () {},
              onViewArtist: () => _openArtistPage(context, entry.song),
              onMore: () => _showDesktopEntryMenu(context, entry),
              onSecondaryMore: (position) =>
                  _showDesktopEntryMenu(context, entry, anchor: position),
            );
          }, childCount: completed.length),
        ),
        if (downloading.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
              child: Text(
                '下载中 ${downloading.length} 首',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: downloading
                  .map((entry) => _DownloadingRow(entry: entry))
                  .toList(),
            ),
          ),
        ],
        if (failed.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
              child: Text(
                '下载失败 ${failed.length} 首',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: failed
                  .map(
                    (entry) => _FailedRow(entry: entry, downloads: downloads),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }

  /// 桌面端行内 `...` / 右键菜单：删除下载、打开文件夹、复制文件路径。
  void _showDesktopEntryMenu(
    BuildContext context,
    DownloadEntry entry, {
    Offset? anchor,
  }) {
    final song = entry.song;
    final filePath = entry.filePath;
    showSongActionSheet(
      context: context,
      song: song,
      anchor: anchor,
      actions: [
        SongSheetAction(
          icon: Icons.delete_outline_rounded,
          title: '删除下载',
          danger: true,
          onTap: () => downloads.deleteDownload(song),
        ),
        if (filePath != null && filePath.isNotEmpty) ...[
          SongSheetAction(
            icon: Icons.folder_open_rounded,
            title: '打开文件夹',
            onTap: () => _openContainingFolder(
              filePath,
              downloads: downloads,
              song: song,
            ),
          ),
          SongSheetAction(
            icon: Icons.copy_rounded,
            title: '复制文件路径',
            onTap: () {
              Clipboard.setData(ClipboardData(text: filePath));
              // 全局 Toast：定位在播放栏之上，避免 SnackBar 压住底部播放栏。
              Toast.show('路径已复制到剪贴板', type: ToastType.success);
            },
          ),
        ],
      ],
    );
  }

  void _openArtistPage(BuildContext context, Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: api,
          auth: auth,
          artist: artist,
          player: player,
        ),
      ),
    );
  }

  void _confirmClearAll(BuildContext context) {
    unawaited(
      () async {
        final confirmed = await showAppConfirmDialog(
          context,
          title: '清空全部下载',
          message: '确定要删除所有已下载的歌曲吗？此操作不可撤销。',
          confirmText: '清空',
        );
        if (confirmed) {
          await downloads.clearAllDownloads();
        }
      }(),
    );
  }
}

/// 已下载歌曲行。
class _DownloadedSongRow extends StatelessWidget {
  const _DownloadedSongRow({
    required this.entry,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
  });

  final DownloadEntry entry;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;

    void play() {
      if (openPlayerIfSameSong(
        context,
        player: player,
        auth: auth,
        song: song,
      )) {
        return;
      }
      player.playSong(song);
    }

    // 行视觉与歌单/搜索/歌手页统一见 AppSongRow；点行即播，
    // 右侧只留 ⋮（删下载/看文件夹/拷路径），播放圈按钮已收敛掉。
    return AppSongRow(
      song: song,
      player: player,
      onTap: play,
      trailing: [
        AppSongRowMenuButton(onPressed: () => _showActions(context, song)),
      ],
    );
  }

  void _showActions(BuildContext context, Song song) {
    final filePath = entry.filePath;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除下载'),
              onTap: () {
                Navigator.pop(ctx);
                downloads.deleteDownload(song);
              },
            ),
            if (filePath != null && filePath.isNotEmpty) ...[
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('打开文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openContainingFolder(
                    filePath,
                    downloads: downloads,
                    song: song,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制文件路径'),
                subtitle: Text(
                  filePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: filePath));
                  // 全局 Toast：定位在播放栏之上，避免 SnackBar 压住底部播放栏。
                  Toast.show('路径已复制到剪贴板', type: ToastType.success);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 用系统文件管理器打开歌曲文件所在目录（移动端弹层与桌面菜单共用）。
///
/// - 打开前校验文件仍在：已被外部移动/删除时先对账（条目可能被移除或
///   在当前下载目录找回），找回则打开新位置，仍缺失则提示——绝不盲开，
///   否则 explorer 对无效路径会静默回落到默认视图（文档），看起来像
///   "打开了错误的位置"；
/// - Windows 用 `explorer /select,` 打开目录并选中歌曲文件（与浏览器
///   "在文件夹中显示"一致的现代口径），macOS 用 `open -R` 在 Finder
///   中定位；
/// - Android 走原生 openDirectory（ACTION_VIEW + 目录 MIME，见
///   [StorageAccessService.openDirectory]）；App 专属目录（默认下载
///   位置）在 Android 11+ 任何文件管理器都无权访问，转为引导用户
///   改用公共下载目录；
/// - 任何一步失败（精简发行版没有 xdg-open、explorer 拉起失败等）都以
///   全局 Toast 反馈，不产生未捕获异步异常。
Future<void> _openContainingFolder(
  String filePath, {
  required DownloadController downloads,
  required Song song,
}) async {
  var path = filePath;
  if (!File(path).existsSync()) {
    await downloads.reconcileDownloads();
    final refreshed = downloads.entryFor(song)?.filePath;
    if (refreshed != null && File(refreshed).existsSync()) {
      path = refreshed;
    } else {
      Toast.show('文件已被移动或删除，已同步下载列表');
      return;
    }
  }
  final file = File(path);
  final dir = file.parent.path;
  try {
    final platform = defaultTargetPlatform;
    if (platform == TargetPlatform.windows) {
      // 路径统一为 `\` 分隔（下载服务拼接用 `/`，explorer /select 对
      // 混合分隔符的解析不可靠）；/select 打开父目录并选中文件。
      final winPath = path.replaceAll('/', '\\');
      // 不能直接 Process.run('explorer', ['/select,$winPath'])：路径含
      // 空格（"歌手-歌名 (Live).mp3" 很常见）时 Dart 的 argv 重组会给
      // 整个参数包引号——`"/select,D:\a b.mp3"`——explorer 解析不了被
      // 引号包住的 /select，就退回打开默认位置（文档文件夹），表现为
      // 「打开文件夹开到了文档」。改经 PowerShell Start-Process 原样
      // 传递命令行，保住官方形态 `explorer /select,"D:\a b.mp3"`。
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          buildExplorerSelectCommand(winPath),
        ],
      );
      if (result.exitCode != 0) {
        // 兜底：放弃选中文件，直接打开所在文件夹（单个带引号的纯路径
        // explorer 可正确解析）。
        await Process.run('explorer', [dir.replaceAll('/', '\\')]);
      }
    } else if (platform == TargetPlatform.macOS) {
      await Process.run('open', ['-R', path]);
    } else if (platform == TargetPlatform.linux) {
      await Process.run('xdg-open', [dir]);
    } else if (platform == TargetPlatform.android) {
      // url_launcher 发 Intent 带不上 MIME 类型：file:// 目录 URI 现代
      // 系统无人响应且 targetSdk 24+ 有 FileUriExposed 风险，无 MIME 的
      // content URI 同样无人认领——必须走原生 openDirectory（ACTION_VIEW +
      // vnd.android.document/directory，文件管理器唯一标准打开口径）。
      final docId = buildStorageDocId(dir);
      if (docId == null) {
        Toast.error('该目录不在共享存储，文件管理器无法打开：$dir');
        return;
      }
      switch (await StorageAccessService.openDirectory(
        path: dir,
        docId: docId,
      )) {
        case 'opened':
          break; // 已拉起文件管理器，无需提示
        case 'app_private':
          // 默认下载目录是 App 专属目录，Android 11+ 系统禁止任何文件
          // 管理器访问（「所有文件访问」也不豁免）；引导改公共目录。
          Toast.show(
            '默认下载目录是应用专属目录，系统限制文件管理器访问；'
            '可在 设置 → 缓存 → 下载位置 改为公共目录后再打开',
          );
        default:
          Toast.error('未找到能打开目录的文件管理器，请手动前往：$dir');
      }
    } else {
      // iOS 无文件管理器直达能力：明确反馈而非静默无响应。
      Toast.error('当前平台暂不支持打开所在目录');
    }
  } catch (e) {
    debugPrint('[已下载] 打开所在目录失败: $e');
    Toast.error('打开目录失败，请手动前往：$dir');
  }
}

/// 把共享存储路径解析为 externalstorage documents 的卷 docId（打开
/// 所在目录用，原生侧 [StorageAccessService.openDirectory] 以
/// DocumentsContract.buildDocumentUri 组出正确编码的 content URI）。
///
/// - 内部存储 `/storage/emulated/0/Music` → `primary:Music`；
/// - 外置卷（SD/USB，自定义下载位置的常见落点）`/storage/0000-0000/Music`
///   → `0000-0000:Music`；
/// - 不以 `/storage/` 起头的路径（应用文档目录等）返回 null，由调用方
///   提示无法打开——拼 primary: 前缀只会得到指向不存在文档的 URI。
@visibleForTesting
String? buildStorageDocId(String dir) {
  final volume = RegExp(r'^/storage/([^/]+)/(.*)$').firstMatch(dir);
  if (volume != null) {
    final volumeId = volume.group(1)!;
    if (volumeId == 'emulated') {
      // /storage/emulated/<userId>/...：仅支持主用户（0）的 primary 卷。
      const primaryPrefix = '/storage/emulated/0/';
      return dir.startsWith(primaryPrefix)
          ? 'primary:${dir.substring(primaryPrefix.length)}'
          : null;
    }
    return '$volumeId:${volume.group(2)}';
  }
  return null;
}

/// 构造 PowerShell 侧「原样传递 explorer /select,"路径"」的命令片段。
///
/// explorer 的 /select 参数必须形如 `/select,"D:\path with space.mp3"`
/// （引号在逗号后、包住路径）；`"/select,D:\..."`（整参被引号包住）
/// 会被 explorer 当成无法解析的路径而退回打开默认位置（文档文件夹）。
/// Dart 的 [Process.run] 无法阻止 argv 含空格时自动加引号，故经
/// `powershell -Command` + `Start-Process -ArgumentList '<原样>'` 转发。
/// PowerShell 单引号字符串里 `'` 需写成 `''` 转义。
@visibleForTesting
String buildExplorerSelectCommand(String winPath) {
  final psEscaped = winPath.replaceAll("'", "''");
  return "Start-Process explorer.exe -ArgumentList '/select,\"$psEscaped\"'";
}

/// 下载中行（显示进度）。
class _DownloadingRow extends StatelessWidget {
  const _DownloadingRow({required this.entry});

  final DownloadEntry entry;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    return ListTile(
      leading: Artwork(url: song.coverUrl, size: 48, borderRadius: 8),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: SizedBox(
        width: 28,
        height: 28,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: entry.progress > 0 ? entry.progress : null,
              strokeWidth: 2.5,
            ),
            if (entry.progress > 0)
              Text(
                '${(entry.progress * 100).round()}',
                style: const TextStyle(fontSize: 9),
              ),
          ],
        ),
      ),
    );
  }
}

/// 下载失败行（可重试或移除）。
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.entry, required this.downloads});

  final DownloadEntry entry;
  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Artwork(url: song.coverUrl, size: 48, borderRadius: 8),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.error ?? '下载失败',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colorScheme.error.withValues(alpha: .85)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '重新下载',
            icon: const Icon(Icons.refresh_rounded),
            color: colorScheme.primary,
            onPressed: () => downloads.download(song, entry.quality),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => downloads.removeFailed(song),
          ),
        ],
      ),
    );
  }
}

/// 播放缓存列表。
class _PlayCacheList extends StatelessWidget {
  const _PlayCacheList({required this.downloads});

  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        final entries = downloads.playCacheEntries;
        if (entries.isEmpty) {
          return _emptyState(context, '还没有播放缓存', '播放歌曲后会自动缓存');
        }

        final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.size);

        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
              child: Row(
                children: [
                  Text(
                    '缓存 ${entries.length} 首 · ${_formatBytes(totalBytes)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _confirmClearCache(context),
                    child: const Text('清空缓存'),
                  ),
                ],
              ),
            ),
            ...entries.map(
              (entry) => ListTile(
                leading: Artwork(
                  url: entry.song.coverUrl,
                  size: 48,
                  borderRadius: 8,
                ),
                title: Text(
                  entry.song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${entry.song.artist} · ${_formatBytes(entry.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () =>
                      downloads.deletePlayCache(entry.song, entry.quality),
                ),
              ),
            ),
            // 悬浮播放条占位：滑到底时末行不被盖住。
            const SizedBox(height: 84),
          ],
        );
      },
    );
  }

  void _confirmClearCache(BuildContext context) {
    unawaited(
      () async {
        final confirmed = await showAppConfirmDialog(
          context,
          title: '清空播放缓存',
          message: '确定要清空所有播放缓存吗？下次播放需要重新加载。',
          confirmText: '清空',
        );
        if (confirmed) {
          await downloads.clearPlayCache();
        }
      }(),
    );
  }
}

Widget _emptyState(BuildContext context, String title, String subtitle) {
  final colorScheme = Theme.of(context).colorScheme;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_done_rounded,
            size: 64,
            color: colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
