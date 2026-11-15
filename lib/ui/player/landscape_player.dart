import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/lyric_converter.dart';
import '../form_factor.dart';
import '../desktop/desktop_player_bar.dart' hide formatDuration;
import '../pages/android_lyric_settings_page.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../pages/song_detail_page.dart';
import '../widgets/artwork.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'desktop_lyric_list.dart';
import 'lyric_display_mode.dart';
import 'lyric_offset_sheet.dart';
import 'lyric_seek_pointer_button.dart';
import 'lyric_views.dart'
    show kLyricShowRomanizationPrefKey, kLyricShowTranslationPrefKey;
import 'player_controls.dart';
import 'song_info_sheet.dart';

/// PC / 车机分栏播放页主体。
///
/// 译/音显示开关状态挂在这里：封面左下的切换按钮（[LandscapeLyricToggleColumn]）
/// 与右侧歌词面板分属两棵子树，由本组件统一持有并持久化
/// （与移动端歌词页共用 [kLyricShowTranslationPrefKey] / [kLyricShowRomanizationPrefKey]）。
class LandscapePlayerContent extends StatefulWidget {
  const LandscapePlayerContent({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;
  final ValueChanged<Song> onArtistTap;

  @override
  State<LandscapePlayerContent> createState() => _LandscapePlayerContentState();
}

class _LandscapePlayerContentState extends State<LandscapePlayerContent> {
  bool _showTranslation = true;
  bool _showRomanization = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showTranslation = prefs.getBool(kLyricShowTranslationPrefKey) ?? true;
      _showRomanization = prefs.getBool(kLyricShowRomanizationPrefKey) ?? false;
    });
  }

  Future<void> _setShowTranslation(bool show) async {
    setState(() => _showTranslation = show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLyricShowTranslationPrefKey, show);
  }

  Future<void> _setShowRomanization(bool show) async {
    setState(() => _showRomanization = show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLyricShowRomanizationPrefKey, show);
  }

  /// 打开「歌词进度」锚定面板（封面开关列的 `调` 按钮 / 歌词列表右键）。
  void _openLyricOffsetMenu(Offset anchor) {
    unawaited(
      showLyricOffsetMenu(context, player: widget.player, anchor: anchor),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PC（QQ 音乐 PC 正在播放页式）：页面最底是那条与主界面同源的常驻播放栏
    // （封面/歌名/操作 + 控制/进度 + 音质/音效/桌面词/队列），最左「收起」返回。
    // 车机横屏没有鼠标语义，保持原「右栏内进度+控制」，不套这层。
    final useBottomBar = isDesktopFormFactor;
    final lyrics = widget.player.lyrics;
    final hasTranslation = lyrics.any((l) => l.translation?.isNotEmpty == true);
    final hasRomanization = lyrics.any(
      (l) => l.romanization?.isNotEmpty == true,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 350;
        final content = Column(
          children: [
            LandscapeHeader(
              player: widget.player,
              auth: widget.auth,
              song: widget.song,
              onClose: widget.onClose,
              compact: compact,
              onArtistTap: widget.onArtistTap,
            ),
            SizedBox(height: compact ? 2 : 10),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 9,
                    child: LandscapeArtworkShowcase(
                      player: widget.player,
                      song: widget.song,
                      compact: compact,
                      showTranslation: _showTranslation,
                      showRomanization: _showRomanization,
                      hasTranslation: hasTranslation,
                      hasRomanization: hasRomanization,
                      onToggleTranslation: _setShowTranslation,
                      onToggleRomanization: _setShowRomanization,
                      onOpenLyricOffset: _openLyricOffsetMenu,
                    ),
                  ),
                  SizedBox(width: compact ? 18 : 34),
                  Expanded(
                    flex: 12,
                    child: LandscapeRightPanel(
                      player: widget.player,
                      auth: widget.auth,
                      song: widget.song,
                      onQueue: widget.onQueue,
                      compact: compact,
                      // 进度/控制已下沉到页面底部常驻播放栏时，右栏只留歌名 + 歌词，
                      // 歌词区域顺势吃满剩余高度。
                      showTransport: !useBottomBar,
                      showTranslation: _showTranslation,
                      showRomanization: _showRomanization,
                      onOpenLyricOffset: _openLyricOffsetMenu,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        if (!useBottomBar) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 4 : 10,
              compact ? 16 : 30,
              compact ? 24 : 36,
            ),
            child: content,
          );
        }

        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  compact ? 4 : 10,
                  compact ? 16 : 30,
                  compact ? 8 : 16,
                ),
                child: content,
              ),
            ),
            // 播放页内复用常驻底栏：禁止再进一层播放页，最左加「收起」返回主界面。
            // 桌面端歌名可点进歌曲详情页：内嵌处拿不到内容区 Navigator，
            // 发请求走 shell（先退播放页、再推入内容区，侧栏保留）；
            // 车机保持不可点（详情页是桌面版式）。
            DesktopPlayerBar(
              player: widget.player,
              auth: widget.auth,
              overlayDark: true,
              openPlayerPageEnabled: false,
              onCollapse: widget.onClose,
              onOpenSongDetail: isDesktopFormFactor
                  ? (song, tab) =>
                        widget.player.openSongDetailRequest.value = (
                          song: song,
                          commentsTab: tab == SongDetailTab.comments,
                        )
                  : null,
            ),
          ],
        );
      },
    );
  }
}

class LandscapeHeader extends StatelessWidget {
  const LandscapeHeader({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.compact,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final bool compact;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 40 : 48,
      child: Row(
        children: [
          LandscapeHeaderButton(
            tooltip: '返回',
            size: compact ? 38 : 44,
            iconSize: compact ? 30 : 34,
            onPressed: onClose,
            icon: Icons.keyboard_arrow_left_rounded,
          ),
          SizedBox(width: compact ? 10 : 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText.text(
                  song.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white.withValues(alpha: .92),
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!compact)
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: .7),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          // 观看 MV（歌曲 ⇄ MV 互切）：车机触控尺寸；MV 反查走酷狗 id
          // 体系，非酷狗源不展示（与「更多」面板里的入口同一约束）。
          if (!isDesktopFormFactor && song.source == SongSource.kugou) ...[
            LandscapeHeaderButton(
              tooltip: '观看 MV',
              size: compact ? 38 : 44,
              iconSize: compact ? 22 : 24,
              onPressed: () => watchMvWithFeedback(
                context: context,
                song: song,
                songs: player.queue,
              ),
              icon: Icons.music_video_rounded,
            ),
            SizedBox(width: compact ? 8 : 12),
          ],
          if (!isDesktopFormFactor)
            Builder(
              builder: (moreButtonContext) => LandscapeHeaderButton(
                tooltip: '更多',
                size: compact ? 38 : 44,
                iconSize: compact ? 22 : 24,
                onPressed: () => _showMoreSheet(moreButtonContext),
                icon: Icons.more_horiz_rounded,
              ),
            ),
        ],
      ),
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      // PC：锚定到"更多"按钮下方（context 已由调用点传入按钮级 context）。
      anchor: anchorBelow(context),
      actions: [
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速播放',
          subtitle: player.playbackSpeedLabel,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质：${player.audioQuality.label}',
          subtitle: '切换当前播放音质',
          onTap: () => showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '试听高潮',
          subtitle: '播放歌曲高潮片段',
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        if (player.isAudioEffectsSupported)
          SongSheetAction(
            icon: Icons.graphic_eq_rounded,
            title: '音效',
            subtitle: player.audioEffectsLabel,
            onTap: () => showAudioEffectsSheet(
              context: context,
              player: player,
            ),
          ),
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () => showAddToPlaylistSheet(
              context: context,
              auth: auth,
              song: song,
            ),
          ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时播放',
          subtitle: player.isSleepTimerActive
              ? '剩余 ${formatSleepRemaining(player.sleepTimerRemaining)}'
              : player.isSleepFinishCurrentSong
              ? '播完歌曲后停止'
              : null,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),
        // 歌曲信息：车机偶尔也要看（与移动端详情弹层入口对齐）。
        SongSheetAction(
          icon: Icons.info_outline_rounded,
          title: '歌曲信息',
          subtitle: '歌手 · 专辑 · 发行年份',
          onTap: () => showSongInfoSheet(
            context: context,
            player: player,
            auth: auth,
            song: song,
          ),
        ),
        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            subtitle: player.desktopLyricsEnabled ? '已开启' : '已关闭',
            onTap: () async {
              // 菜单壳已负责关闭（先 pop + 120ms 后回调），这里不再手动 pop，
              // 否则会连带退出播放页（与 player_top_bar 同款修复）。
              await player.setDesktopLyricsEnabled(
                !player.desktopLyricsEnabled,
              );
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  // PC 用原设置页；Android（易格方案）用移动端设置页。
                  builder: (_) => isDesktopFormFactor
                      ? DesktopLyricsSettingsPage(player: player)
                      : AndroidLyricSettingsPage(player: player),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class LandscapeHeaderButton extends StatelessWidget {
  const LandscapeHeaderButton({
    super.key,
    required this.tooltip,
    required this.size,
    required this.iconSize,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: isDesktopFormFactor
            ? Colors.transparent
            : Colors.white.withValues(alpha: .12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            color: Colors.white,
            iconSize: iconSize,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: size, height: size),
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}

class LandscapeArtworkShowcase extends StatefulWidget {
  const LandscapeArtworkShowcase({
    super.key,
    required this.player,
    required this.song,
    required this.compact,
    required this.showTranslation,
    required this.showRomanization,
    required this.hasTranslation,
    required this.hasRomanization,
    required this.onToggleTranslation,
    required this.onToggleRomanization,
    this.onOpenLyricOffset,
  });

  final PlayerController player;
  final Song song;
  final bool compact;
  final bool showTranslation;
  final bool showRomanization;
  final bool hasTranslation;
  final bool hasRomanization;
  final ValueChanged<bool> onToggleTranslation;
  final ValueChanged<bool> onToggleRomanization;

  /// 打开「歌词进度」面板（锚点 = 按钮右上角全局坐标）。
  final ValueChanged<Offset>? onOpenLyricOffset;

  @override
  State<LandscapeArtworkShowcase> createState() =>
      _LandscapeArtworkShowcaseState();
}

class _LandscapeArtworkShowcaseState extends State<LandscapeArtworkShowcase>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  bool _appHidden = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    );
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appHidden = lifecycle != null && _isHiddenState(lifecycle);
    _syncRotation();
  }

  /// 仅在窗口真正不可见（hidden/paused/detached）时冻结：最小化后桌面端
  /// 仍会出帧，不可见空转唱片没有意义。仅失焦（inactive）但可见时保持
  /// 旋转——桌面多软件并排是常态，转着更自然。
  static bool _isHiddenState(AppLifecycleState state) =>
      state != AppLifecycleState.resumed && state != AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appHidden = _isHiddenState(state);
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant LandscapeArtworkShowcase oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash) {
      _rotationController.value = 0;
    }
    _syncRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotationController.dispose();
    super.dispose();
  }

  void _syncRotation() {
    if (widget.player.isPlaying && !_appHidden) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        if (velocity < -200) {
          widget.player.next();
        } else if (velocity > 200) {
          widget.player.previous();
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final available = math.min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final discSize = (available * (widget.compact ? .84 : .9))
                    .clamp(150.0, 330.0)
                    .toDouble();
                final coverSize = discSize * (widget.compact ? .58 : .70);

                return Center(
                  // 旋转唱片是纯装饰动画，仅桌面 Windows 排除语义树
                  // （AXTree 竞态），移动端保留
                  child: ExcludeSemantics(
                    excluding: isDesktopPlatform,
                    child: SizedBox.square(
                      dimension: discSize,
                      child: AnimatedBuilder(
                        animation: _rotationController,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle: _rotationController.value * math.pi * 2,
                            child: child,
                          );
                        },
                        // 静态唱片内容外包 RepaintBoundary：每帧只有外层
                        // Transform.rotate 变化，唱片栅格（含 30px 阴影模糊
                        // 与多层圆环描边）因此能命中缓存，不必逐帧重绘。
                        child: RepaintBoundary(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      Colors.white.withValues(alpha: .88),
                                      Colors.white.withValues(alpha: .58),
                                      Colors.white.withValues(alpha: .22),
                                    ],
                                    stops: const [0, .62, 1],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: .26,
                                      ),
                                      blurRadius: 30,
                                      offset: const Offset(0, 18),
                                    ),
                                  ],
                                ),
                                child: const SizedBox.expand(),
                              ),
                              for (final ratio in const [.36, .52, .68, .82])
                                SizedBox.square(
                                  dimension: discSize * ratio,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: .16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ClipOval(
                                child: Artwork(
                                  url: widget.song.coverUrl,
                                  size: coverSize,
                                  borderRadius: coverSize,
                                  // 横屏唱片大图：任何形态都保持 2x/600 解码档。
                                  highRes: true,
                                ),
                              ),
                              SizedBox.square(
                                dimension: discSize * .08,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withValues(alpha: .82),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 封面左下角：译/音显示切换 + 歌词进度调整按钮（截图红框位置）。
          // 按钮放在拖拽切歌手势层之上，点按不触发切歌。
          Positioned(
            left: 2,
            bottom: 4,
            child: LandscapeLyricToggleColumn(
              showTranslation: widget.showTranslation,
              showRomanization: widget.showRomanization,
              hasTranslation: widget.hasTranslation,
              hasRomanization: widget.hasRomanization,
              onToggleTranslation: widget.onToggleTranslation,
              onToggleRomanization: widget.onToggleRomanization,
              hasLyricOffset: widget.player.hasLyricOffset,
              onOpenLyricOffset: widget.onOpenLyricOffset,
              buttonSize: widget.compact
                  ? 32.0
                  : (isDesktopFormFactor ? 36.0 : 52.0),
            ),
          ),
        ],
      ),
    );
  }
}

class LandscapeRightPanel extends StatelessWidget {
  const LandscapeRightPanel({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    required this.onQueue,
    required this.compact,
    this.showTransport = true,
    this.showTranslation = true,
    this.showRomanization = false,
    this.onOpenLyricOffset,
  });

  final PlayerController player;
  final AuthController auth;
  final Song? song;
  final VoidCallback onQueue;
  final bool compact;

  /// 是否在本栏底部渲染进度条 + 控制行。
  ///
  /// PC 播放页已把这些下沉到页面底部的常驻播放栏，故传 false；
  /// 车机横屏没有常驻播放栏，保持 true。
  final bool showTransport;

  /// 歌词是否显示翻译/音译（由 [LandscapePlayerContent] 持有的开关传入）。
  final bool showTranslation;
  final bool showRomanization;

  /// 歌词列表右键时打开「歌词进度」面板（锚点 = 指针全局坐标）。
  final ValueChanged<Offset>? onOpenLyricOffset;

  @override
  Widget build(BuildContext context) {
    final currentSong = song;
    return LayoutBuilder(
      builder: (context, constraints) {
        final veryTight = constraints.maxHeight < 250;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (currentSong != null)
              Padding(
                padding: EdgeInsets.only(
                  bottom: veryTight ? 6.0 : 12.0,
                  top: veryTight ? 2.0 : 6.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentSong.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white.withValues(alpha: .92),
                        fontSize: compact ? 18 : 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentSong.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: LandscapeLyricPanel(
                player: player,
                songHash: currentSong?.hash ?? '',
                lyrics: player.lyrics,
                compact: compact || veryTight,
                showTranslation: showTranslation,
                showRomanization: showRomanization,
                onOpenLyricOffset: onOpenLyricOffset,
              ),
            ),
            if (showTransport) ...[
              SizedBox(height: veryTight ? 2 : 6),
              Progress(player: player, bright: true, compact: true),
              SizedBox(height: veryTight ? 0 : 4),
              Controls(
                player: player,
                bright: true,
                onQueue: onQueue,
                compactOverride: true,
                denseOverride: veryTight,
                likeAuth: auth,
                likeSong: song,
              ),
            ],
          ],
        );
      },
    );
  }
}

class LandscapeLyricPanel extends StatefulWidget {
  const LandscapeLyricPanel({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.compact,
    this.showTranslation = true,
    this.showRomanization = false,
    this.onOpenLyricOffset,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final bool compact;

  /// 歌词是否显示翻译/音译。桌面分支换算 [LyricDisplayMode]，
  /// 车机分支透传给 flutter_lyric 模型（两者切换都会触发歌词重建）。
  final bool showTranslation;
  final bool showRomanization;

  /// 桌面分支：歌词列表右键打开「歌词进度」面板。
  final ValueChanged<Offset>? onOpenLyricOffset;

  @override
  State<LandscapeLyricPanel> createState() => _LandscapeLyricPanelState();
}

class _LandscapeLyricPanelState extends State<LandscapeLyricPanel> {
  late final LyricController _lyricController;
  late final Ticker _ticker;
  bool _isUserSelecting = false;
  // 与竖屏 LyricViewport 同理：记录已下发进度，屏蔽冷启动定位起播加载期的回 0 闪动。
  Duration _lastSentProgress = Duration.zero;
  // 已加载歌词快照：面板自己监听 player，切歌后歌词到达不再依赖父级 rebuild
  // 透传（此前全靠 PlayerPage 顶层 AnimatedBuilder 顺带刷新，一旦复用位置变动
  // 或父级不再重建，就会卡在"正在准备音乐..."）。
  List<LyricLine> _loadedLyrics = const [];
  // 准备态快照：歌词为空时 isPreparing 翻转（"正在准备音乐..."→"暂无歌词"）
  // 也要自刷新，否则空歌词歌曲的状态文本不会更新。
  bool _lastPreparing = false;
  // 歌词进度偏移快照：偏移变更后桌面歌词列表/车机歌词视图都要按新位置重排
  // （暂停时没有 ticker 帧，不主动补推就会停在旧位置）。
  Duration _lastLyricOffset = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadedLyrics = widget.lyrics;
    _lastPreparing = widget.player.isPreparing;
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      _lastSentProgress = position;
      _lyricController.setProgress(position);
      widget.player.seekToAndPlay(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    widget.player.addListener(_onPlayerChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant LandscapeLyricPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
      _lastPreparing = widget.player.isPreparing;
    }
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.showTranslation != widget.showTranslation ||
        oldWidget.showRomanization != widget.showRomanization ||
        !_sameLyricContent(oldWidget.lyrics, widget.lyrics)) {
      _loadedLyrics = widget.lyrics;
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  /// player 状态变化（切歌清空/歌词到达/准备态翻转）时自刷新，不依赖父级 rebuild。
  ///
  /// 歌词以 player 持有的为准（`loadLyrics` 落定即 `notifyListeners`），快照比对
  /// 去重后才 `setState`，高频通知只走轻量 `_syncTicker`（启停判断），不开销重建。
  void _onPlayerChanged() {
    if (!mounted) return;
    final current = widget.player.lyrics;
    final preparing = widget.player.isPreparing;
    if (!_sameLyricContent(current, _loadedLyrics) ||
        preparing != _lastPreparing) {
      _loadedLyrics = current;
      _lastPreparing = preparing;
      setState(() {
        _syncLyrics();
        _syncTicker();
      });
      return;
    }
    if (widget.player.lyricOffset != _lastLyricOffset) {
      _lastLyricOffset = widget.player.lyricOffset;
      final position = widget.player.lyricPosition;
      _lastSentProgress = position;
      _lyricController.setProgress(position);
      setState(() {});
      return;
    }
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = _loadedLyrics;
    if (lyrics.isNotEmpty) {
      final model = convertToFlutterLyricModel(
        lyrics,
        showTranslation: widget.showTranslation,
        showRomanization: widget.showRomanization,
      );
      _lyricController.loadLyricModel(model);
      // 重载后立即用当前播放位置校准，避免用陈旧 progress(0) 闪回开头。
      final current = widget.player.lyricPosition;
      _lastSentProgress = current;
      _lyricController.setProgress(current);
    }
  }

  bool _sameLyricContent(List<LyricLine> a, List<LyricLine> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _syncTicker() {
    final shouldTick =
        widget.player.isPlaying &&
        _loadedLyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // 车载/分栏歌词按带偏移的歌词位置推进（偏移只作用于歌词）。
    final pos = widget.player.lyricPosition;
    if (widget.player.isPreparing &&
        _lastSentProgress > Duration.zero &&
        (pos <= Duration.zero ||
            _lastSentProgress - pos > const Duration(milliseconds: 500))) {
      return;
    }
    _lastSentProgress = pos;
    _lyricController.setProgress(pos);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = _loadedLyrics;
    if (lyrics.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          player.isPreparing ? '正在准备音乐...' : '暂无歌词',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white.withValues(alpha: .82),
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    if (isDesktopFormFactor) {
      return ExcludeSemantics(
        excluding: isDesktopPlatform,
        child: DesktopLyricList(
          player: player,
          songHash: widget.songHash,
          lyrics: lyrics,
          activeIndex: player.activeLyricIndex,
          displayMode: lyricDisplayModeOf(
            showTranslation: widget.showTranslation,
            showRomanization: widget.showRomanization,
          ),
          lyricScale: widget.compact ? 0.85 : 1.0,
          onSecondaryTapLine: widget.onOpenLyricOffset,
        ),
      );
    }

    final fontSize = widget.compact ? 26.0 : 34.0;
    final inactiveFontSize = widget.compact ? 18.0 : 24.0;

    // 与移动端 MobileLyricList 同一层级策略：用户滚动时锚点行不放大字号，
    // 仅把颜色加重到移动端聚焦行的量级（主行 alpha 0.85 / 译行 0.70）。
    final lyricStyle = LyricStyles.default1.copyWith(
      textStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: inactiveFontSize,
        height: 1.18,
        fontWeight: FontWeight.w800,
      ),
      activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: fontSize,
        height: 1.18,
        fontWeight: FontWeight.w900,
      ),
      selectedColor: Colors.white.withValues(alpha: .85),
      selectedTranslationColor: Colors.white.withValues(alpha: .70),
      lineGap: widget.compact ? 10 : 16,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: widget.compact ? 20 : 40,
      ),
      fadeRange: FadeRange(top: 40, bottom: 40),
      textAlign: TextAlign.left,
      contentAlignment: CrossAxisAlignment.start,
      activeHighlightColor: Colors.white,
    );

    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，仅桌面排除
      excluding: isDesktopPlatform,
      child: Stack(
        children: [
          LyricView(controller: _lyricController, style: lyricStyle),
          _buildSelectionCrosshair(),
        ],
      ),
    );
  }

  /// 用户滚动歌词时的准星覆盖层：与移动端 MobileLyricList 同款——
  /// 左侧渐隐准星线 + 右侧 [ ▶ mm:ss ] 播放胶囊，点击跳转播放并立即恢复
  /// 跟随播放行；点击歌词行直接跳播的逻辑保持不变。
  Widget _buildSelectionCrosshair() {
    return SelectListenableBuilder(
      controller: _lyricController,
      builder: (state, _) {
        return Positioned(
          left: 0,
          right: 12,
          top: state.centerY - 14,
          height: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                // 准星线仅 1px 高且不参与命中，保证拖拽手势穿透回歌词视图
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.08),
                          Colors.white.withValues(alpha: 0.28),
                          Colors.white.withValues(alpha: 0.14),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              LyricSeekPointerButton(
                key: const ValueKey('landscape_lyric_seek_pointer_button'),
                timeText: formatDuration(state.duration),
                onTap: () {
                  // 先校准进度（防跳转后回 0 闪动），再退出选区恢复跟随，
                  // 最后走与点击歌词行相同的跳播路径。
                  _lastSentProgress = state.duration;
                  _lyricController.setProgress(state.duration);
                  _lyricController.stopSelection();
                  widget.player.seekToAndPlay(state.duration);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 封面左下角的译/音显示切换 + 歌词进度调整按钮列。
///
/// 视觉对齐移动端歌词页的开关语义（同一份持久化设置），按钮为竖排
/// 圆角方形描边样式：开启时主题色描边 + 淡色衬底高亮，关闭时灰色
/// 无高亮；仅在当前歌词确有翻译/音译内容时渲染对应按钮，
/// `调`（歌词进度）按钮始终可见——它是功能入口而不是状态开关。
class LandscapeLyricToggleColumn extends StatelessWidget {
  const LandscapeLyricToggleColumn({
    super.key,
    required this.showTranslation,
    required this.showRomanization,
    required this.hasTranslation,
    required this.hasRomanization,
    required this.onToggleTranslation,
    required this.onToggleRomanization,
    this.hasLyricOffset = false,
    this.onOpenLyricOffset,
    this.buttonSize = 36,
  });

  final bool showTranslation;
  final bool showRomanization;
  final bool hasTranslation;
  final bool hasRomanization;
  final ValueChanged<bool> onToggleTranslation;
  final ValueChanged<bool> onToggleRomanization;

  /// 当前歌曲是否带非零歌词进度偏移（`调` 按钮据此点亮）。
  final bool hasLyricOffset;

  /// 打开「歌词进度」面板；为空则不渲染 `调` 按钮。
  final ValueChanged<Offset>? onOpenLyricOffset;

  /// 按钮边长：桌面取 36（对齐移动端药丸宽度量级），车机触控取 52，
  /// 紧凑高度取 32。
  final double buttonSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onOpenLyricOffset != null) ...[
          _LyricOffsetAnchorButton(
            size: buttonSize,
            isOn: hasLyricOffset,
            onOpen: onOpenLyricOffset!,
          ),
          if (hasTranslation || hasRomanization)
            SizedBox(height: buttonSize * .24),
        ],
        if (hasTranslation)
          _LandscapeSquareToggle(
            label: '译',
            size: buttonSize,
            isOn: showTranslation,
            tooltip: '翻译 (${showTranslation ? '已开启' : '已关闭'})',
            onToggle: () => onToggleTranslation(!showTranslation),
          ),
        if (hasTranslation && hasRomanization)
          SizedBox(height: buttonSize * .24),
        if (hasRomanization)
          _LandscapeSquareToggle(
            label: '音',
            size: buttonSize,
            isOn: showRomanization,
            tooltip: '拼音/音译 (${showRomanization ? '已开启' : '已关闭'})',
            onToggle: () => onToggleRomanization(!showRomanization),
          ),
      ],
    );
  }
}

/// `调` 按钮：与 [_LandscapeSquareToggle] 同款外观，但点击打开锚定面板
/// （锚点取按钮右上角，菜单落在按钮右侧，不遮挡封面）。
class _LyricOffsetAnchorButton extends StatelessWidget {
  const _LyricOffsetAnchorButton({
    required this.size,
    required this.isOn,
    required this.onOpen,
  });

  final double size;
  final bool isOn;
  final ValueChanged<Offset> onOpen;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final borderColor = isOn ? accent : Colors.white.withValues(alpha: .30);
    final foreground = isOn ? accent : Colors.white.withValues(alpha: .55);

    return Tooltip(
      message: isOn ? '歌词进度（已调整）' : '调整歌词进度',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onOpen(anchorAboveRight(context)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * .26),
              border: Border.all(color: borderColor, width: 1.4),
              color: isOn ? accent.withValues(alpha: .14) : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '调',
              style: TextStyle(
                fontSize: size * .42,
                fontWeight: FontWeight.w700,
                color: foreground,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LandscapeSquareToggle extends StatelessWidget {
  const _LandscapeSquareToggle({
    required this.label,
    required this.size,
    required this.isOn,
    required this.tooltip,
    required this.onToggle,
  });

  final String label;
  final double size;
  final bool isOn;
  final String tooltip;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // 播放页底是封面背景，按钮用主题强调色点亮（深色主题下为提亮后的
    // 主题色），关闭态仅保留低透明度描边，不与背景抢视线。
    final accent = Theme.of(context).colorScheme.primary;
    final borderColor = isOn ? accent : Colors.white.withValues(alpha: .30);
    final foreground = isOn ? accent : Colors.white.withValues(alpha: .55);

    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * .26),
              border: Border.all(color: borderColor, width: 1.4),
              color: isOn ? accent.withValues(alpha: .14) : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: size * .42,
                fontWeight: FontWeight.w700,
                color: foreground,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
