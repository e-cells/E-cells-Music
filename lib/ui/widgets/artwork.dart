import 'dart:async';
import 'dart:io';
import 'dart:math' show cos, min, pi;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/disk_cached_image_provider.dart';
import '../../services/network_monitor.dart';
import '../form_factor.dart';

/// 图片解码尺寸档位。
///
/// `Artwork` 的尺寸来自布局（网格列宽、卡片宽度等），直接拿它当解码尺寸
/// 会让**同一个封面在不同布局尺寸下产生多条 ImageCache 条目**，互相挤兑
/// 淘汰（桌面宽窗一次铺开的封面数本就远超上限，条目再被放大就更容易淘汰，
/// 淘汰后只能重新走网络）。吸附到固定档位后，同一封面跨布局复用同一条
/// 缓存。代价是解码尺寸只升不降——内存按**面积**计：相邻档位线性比最大
/// 1.5×（64→96），单张最坏约 2.2×；常见 1.25× 档位约 1.56×。换来的是条目
/// 数下降与跨布局复用，整体仍显著优于"淘汰后重新走网络"。
const _decodeSizeSteps = <int>[64, 96, 128, 160, 200, 256, 320, 400, 480, 600];

/// 把布局尺寸换算为量化后的解码边长。
///
/// - 移动/车机（!isDesktopFormFactor）：维持 `size*2.0` 吸档、上限 600，
///   size 非有限 → 600（与历史口径完全一致，档位零变化）。
/// - 桌面且 [highRes] 为 false：网格/列表缩略图降为 `size*1.5` 吸档、上限
///   400，size 非有限 → 400。桌面常见 DPR 1.0~1.5，1.5x 恰够显示清晰度，
///   单张位图内存约降为原来的 (1.5/2)² ≈ 56%。
/// - [highRes] 为 true（播放页海报/横屏大图）：任何形态都走 2x/600 旧档。
int decodeSizeFor(double size, {bool highRes = false}) {
  final highTier = highRes || !isDesktopFormFactor;
  final cap = highTier ? 600 : 400;
  if (!size.isFinite) return cap;
  final scale = highTier ? 2.0 : 1.5;
  // 超过上限时直接钳到上限档，避免桌面档位“触顶后升到 480/600”。
  final target = min((size * scale).ceil(), cap);
  for (final step in _decodeSizeSteps) {
    if (target <= step) return step;
  }
  return cap;
}

/// 网络图片，断网恢复后自动重试。
///
/// Flutter 的 [Image] 在 provider 不变时 rebuild 不会重新发起请求，
/// 断网期间失败的图片会一直停留在 errorBuilder 上，直到该 widget
/// 被销毁重建。这里监听 [NetworkMonitor] 的网络恢复事件，通过更换
/// key 强制重建内部 [Image] 重新加载。
///
/// 两处刻意的克制：
/// - **只重建真正失败过的图**（[_failed]）。历史上这里对任何网络恢复事件都
///   无条件换代，一次瞬时抖动就会把全 App 的图片 Element 全部重建并重新
///   解析；在缓存吃紧的页面上（桌面推荐页一次铺开几百张）就表现为整页封面
///   变白再逐张重下。成功过的图无需求重试，换代纯属自伤。
/// - 取图走 [DiskCachedImageProvider]：内存条目被淘汰时先从磁盘取字节，
///   不必等网络往返，用户看不到"空白"这一帧。
class RetryableNetworkImage extends StatefulWidget {
  const RetryableNetworkImage({
    super.key,
    required this.url,
    this.fit,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final String url;
  final BoxFit? fit;

  /// 对齐方式（如歌手头图 bottom 铺满 SliverAppBar 时需要 topCenter）。
  final Alignment alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<RetryableNetworkImage> createState() => _RetryableNetworkImageState();
}

class _RetryableNetworkImageState extends State<RetryableNetworkImage> {
  int _generation = 0;

  /// 当前这一代是否失败过（errorBuilder 被调用过）。只有失败态才值得重试。
  bool _failed = false;
  StreamSubscription<void>? _networkRestoredSub;

  @override
  void initState() {
    super.initState();
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (!mounted || !_failed) return;
        setState(() {
          _failed = false;
          _generation++;
        });
      },
    );
  }

  @override
  void dispose() {
    _networkRestoredSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: ResizeImage.resizeIfNeeded(
        widget.cacheWidth,
        widget.cacheHeight,
        DiskCachedImageProvider(widget.url),
      ),
      // key 变化会让 Element 整体重建（而非复用 _ImageState），
      // 从而重新 resolve 图片；此时磁盘/内存缓存里已有字节，无闪烁。
      key: ValueKey('retry-$_generation'),
      fit: widget.fit,
      alignment: widget.alignment,
      // errorBuilder 在 build 期间被调用，此处不能 setState；只登记失败态，
      // 换代重建交给下一个网络恢复事件（也不需要本帧就重建）。
      errorBuilder: (context, error, stackTrace) {
        _failed = true;
        return widget.errorBuilder?.call(context, error, stackTrace) ??
            const SizedBox.shrink();
      },
      loadingBuilder: widget.loadingBuilder,
    );
  }
}

class Artwork extends StatefulWidget {
  const Artwork({
    super.key,
    this.url,
    required this.size,
    this.borderRadius = 8,
    this.icon = Icons.music_note_rounded,
    this.highRes = false,
  });

  final String? url;
  final double size;
  final double borderRadius;
  final IconData icon;

  /// 是否按高分辨率档解码（2x/600）。仅播放页大图（海报、横屏唱片）传 true；
  /// 网格/列表缩略图保持默认 false，桌面形态下走 1.5x/400 降档省内存。
  /// 移动/车机下该参数不改变行为（恒为 2x/600）。
  final bool highRes;

  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.url;
    final bool isLocalFile = imageUrl != null &&
        !imageUrl.startsWith('content://') &&
        !imageUrl.startsWith('http://') &&
        !imageUrl.startsWith('https://');

    final child = imageUrl == null
        ? _Fallback(icon: widget.icon)
        : imageUrl.startsWith('content://')
            ? _ContentUriImage(
                uri: imageUrl,
                size: widget.size,
                borderRadius: widget.borderRadius,
                icon: widget.icon,
                highRes: widget.highRes,
              )
            : isLocalFile
                ? Image.file(
                    File(
                      imageUrl.startsWith('file://')
                          ? Uri.parse(imageUrl).toFilePath()
                          : imageUrl,
                    ),
                    cacheWidth:
                        decodeSizeFor(widget.size, highRes: widget.highRes),
                    cacheHeight:
                        decodeSizeFor(widget.size, highRes: widget.highRes),
                    fit: BoxFit.cover,
                    errorBuilder:
                        (context, error, stackTrace) => _Fallback(icon: widget.icon),
                  )
                : RetryableNetworkImage(
                    url: imageUrl,
                    // 解码尺寸吸附到固定档位（见 [decodeSizeFor]）：同一封面在不同
                    // 布局尺寸下复用同一条 ImageCache 条目，条目数下降、重复下载变少。
                    cacheWidth: decodeSizeFor(widget.size, highRes: widget.highRes),
                    cacheHeight:
                        decodeSizeFor(widget.size, highRes: widget.highRes),
                    fit: BoxFit.cover,
                    errorBuilder:
                        (context, error, stackTrace) => _Fallback(icon: widget.icon),
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) {
                        return child;
                      }
                      return _ShimmerBox(
                        size: widget.size,
                        borderRadius: widget.borderRadius,
                      );
                    },
                  );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.size.isFinite
          ? SizedBox.square(dimension: widget.size, child: child)
          : SizedBox.expand(child: child),
    );
  }
}

/// 加载 content:// URI 的图片（用于本地音乐专辑封面）。
class _ContentUriImage extends StatefulWidget {
  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.icon,
    required this.highRes,
  });

  final String uri;
  final double size;
  final double borderRadius;
  final IconData icon;
  final bool highRes;

  @override
  State<_ContentUriImage> createState() => _ContentUriImageState();
}

class _ContentUriImageState extends State<_ContentUriImage> {
  static const _channel = MethodChannel('shiyin_music/local_music');
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      // 从 content URI 中提取 albumId
      final uri = widget.uri;
      final albumId = int.tryParse(uri.split('/').last);
      if (albumId == null || albumId <= 0) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getAlbumArt',
        {'albumId': albumId},
      );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _ShimmerBox(size: widget.size, borderRadius: widget.borderRadius);
    }
    if (_bytes == null) {
      return _Fallback(icon: widget.icon);
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      cacheWidth: decodeSizeFor(widget.size, highRes: widget.highRes),
      cacheHeight: decodeSizeFor(widget.size, highRes: widget.highRes),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .88),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .72),
          ],
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}

/// 图片加载时的 Shimmer 占位效果。
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({required this.size, required this.borderRadius});

  final double size;
  final double borderRadius;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox> {
  static final _shared = _ShimmerNotifier();

  @override
  void initState() {
    super.initState();
    _shared.attach();
  }

  @override
  void dispose() {
    _shared.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainer;
    final highlightColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: .4)
        : Colors.white.withValues(alpha: .6);

    return AnimatedBuilder(
      animation: _shared,
      builder: (context, child) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(_shared.value - 0.5, 0),
                end: Alignment(_shared.value + 0.5, 0),
                colors: [baseColor, highlightColor, baseColor],
                stops: const [0, 0.5, 1],
              ),
            ),
            child: child,
          ),
        );
      },
      child: SizedBox(
        width: widget.size.isFinite ? widget.size : null,
        height: widget.size.isFinite ? widget.size : null,
      ),
    );
  }
}

class _ShimmerNotifier extends ChangeNotifier {
  Timer? _timer;
  int _refCount = 0;

  void attach() {
    _refCount++;
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      _elapsed = (_elapsed + 16) % 1200;
      _value = -cos(_elapsed / 1200.0 * pi);
      notifyListeners();
    });
  }

  void detach() {
    _refCount--;
    if (_refCount <= 0) {
      _refCount = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  double _elapsed = 0;
  double _value = -1.0;
  double get value => _value;
}
