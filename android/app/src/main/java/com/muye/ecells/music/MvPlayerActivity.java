package com.muye.ecells.music;

import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.PlayerView;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 原生 MV 播放 Activity。
 * 支持竖屏（视频+信息/播放列表）和横屏（全屏视频）两种布局，
 * 使用 ExoPlayer + FFmpeg 软件解码扩展播放视频。
 * 支持播放列表连续播放、上一个/下一个、播放列表面板。
 * 支持画质选择和播放失败自动换源。
 */
public class MvPlayerActivity extends AppCompatActivity {

    private static final String TAG = "MvPlayerActivity";

    // Intent extras 常量
    public static final String EXTRA_VIDEO_URL = "videoUrl";
    public static final String EXTRA_TITLE = "title";
    public static final String EXTRA_AUTHOR = "author";
    public static final String EXTRA_COVER_URL = "coverUrl";
    public static final String EXTRA_POSITION = "position";
    public static final String EXTRA_HASH = "hash";
    public static final String EXTRA_PLAYLIST = "playlist";
    public static final String EXTRA_START_INDEX = "startIndex";
    public static final String EXTRA_SOURCE_HASHES = "sourceHashes";
    public static final String EXTRA_AUTO_FULLSCREEN = "autoFullscreen";
    public static final String EXTRA_SCREEN_ORIENTATION = "screenOrientation";

    private static final int HIDE_CONTROLS_DELAY_MS = 3000;
    private static final int PROGRESS_UPDATE_INTERVAL_MS = 500;

    // 静态实例引用（供 NativeAudioPlugin 回调）
    public static volatile MvPlayerActivity currentInstance;

    // 视图引用
    private PlayerView playerView;
    private View controlsRoot;
    private View bottomControls;
    private ImageButton centerPlayPause;
    private ImageButton btnPlayPause;
    private ImageButton btnFullscreen;
    private ImageButton btnPrev;
    private ImageButton btnNext;
    private ImageButton btnPlaylist;
    private SeekBar seekBar;
    private TextView timeCurrent;
    private TextView timeDuration;
    private ProgressBar loadingIndicator;
    private TextView errorMessage;
    private TextView infoTitle;
    private TextView infoAuthor;
    private FrameLayout videoContainer;
    private ScrollView infoScroll;
    private LinearLayout rootLayout;
    private FrameLayout bottomContainer;
    private View portraitPlaylistPanel;
    private View landscapePlaylistDrawer;
    private RecyclerView playlistRecyclerView;
    private TextView playlistIndicator;
    private TextView btnQuality;

    // 播放器
    private ExoPlayer player;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable progressUpdateRunnable;
    private Runnable hideControlsRunnable;
    private boolean isSeeking = false;
    private boolean isShowingControls = true;
    private long savedPosition = 0;

    // 播放列表状态
    private JSONArray playlistJson;
    private int currentIndex = 0;
    private int playlistSize = 0;
    private boolean isPlaylistVisible = false;
    private MvPlaylistAdapter playlistAdapter;

    // 视频数据
    private String videoUrl;
    private String videoTitle;
    private String videoAuthor;

    // 画质切换 / 自动换源
    private String[] sourceHashes;
    private String[] sourceLabels;
    private int currentSourceIndex = 0;
    private boolean autoFullscreen = false;
    // 屏幕方向设置："auto" / "portrait" / "landscape"
    private String screenOrientation = "auto";
    private boolean isSwitchingQuality = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        currentInstance = this;

        // 读取 Intent extras
        videoUrl = getIntent().getStringExtra(EXTRA_VIDEO_URL);
        videoTitle = getIntent().getStringExtra(EXTRA_TITLE);
        videoAuthor = getIntent().getStringExtra(EXTRA_AUTHOR);
        savedPosition = getIntent().getLongExtra(EXTRA_POSITION, 0);

        // 读取播放列表
        String playlistStr = getIntent().getStringExtra(EXTRA_PLAYLIST);
        if (playlistStr != null && !playlistStr.isEmpty()) {
            try {
                playlistJson = new JSONArray(playlistStr);
                playlistSize = playlistJson.length();
            } catch (Exception e) {
                Log.e(TAG, "Failed to parse playlist JSON", e);
                playlistJson = null;
                playlistSize = 0;
            }
        }
        currentIndex = getIntent().getIntExtra(EXTRA_START_INDEX, 0);
        if (currentIndex < 0) currentIndex = 0;
        if (playlistSize > 0 && currentIndex >= playlistSize) currentIndex = playlistSize - 1;

        // 解析画质片源列表
        String sourceHashesStr = getIntent().getStringExtra(EXTRA_SOURCE_HASHES);
        if (sourceHashesStr != null && !sourceHashesStr.isEmpty()) {
            String[] pairs = sourceHashesStr.split(",");
            sourceHashes = new String[pairs.length];
            sourceLabels = new String[pairs.length];
            for (int i = 0; i < pairs.length; i++) {
                String[] parts = pairs[i].split("\\|", 2);
                sourceHashes[i] = parts[0];
                sourceLabels[i] = parts.length > 1 ? parts[1] : ("源" + (i + 1));
            }
        }

        // 解析自动全屏标记
        autoFullscreen = "true".equals(getIntent().getStringExtra(EXTRA_AUTO_FULLSCREEN));
        String orientationStr = getIntent().getStringExtra(EXTRA_SCREEN_ORIENTATION);
        if (orientationStr != null && !orientationStr.isEmpty()) {
            screenOrientation = orientationStr;
        }

        if (savedInstanceState != null) {
            savedPosition = savedInstanceState.getLong("savedPosition", savedPosition);
            currentIndex = savedInstanceState.getInt("savedCurrentIndex", currentIndex);
            isPlaylistVisible = savedInstanceState.getBoolean("isPlaylistVisible", false);
            currentSourceIndex = savedInstanceState.getInt("currentSourceIndex", 0);
        }

        // 窗口配置
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(Color.TRANSPARENT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            getWindow().getAttributes().layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        setContentView(R.layout.activity_mv_player);

        // 绑定视图
        bindViews();

        // 设置信息区文本
        if (videoTitle != null) infoTitle.setText(videoTitle);
        if (videoAuthor != null) infoAuthor.setText(videoAuthor);

        // 初始化播放列表控件
        initPlaylist();

        // 初始化播放器
        initPlayer();

        // 设置控件事件
        setupControls();

        // 根据当前方向调整布局
        applyOrientationLayout(getResources().getConfiguration().orientation);

        // 横屏自动全屏
        if (autoFullscreen
                && getResources().getConfiguration().orientation != Configuration.ORIENTATION_LANDSCAPE) {
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        }
    }

    private void bindViews() {
        rootLayout = findViewById(R.id.root_layout);
        playerView = findViewById(R.id.player_view);
        controlsRoot = findViewById(R.id.controls_root);
        bottomControls = findViewById(R.id.bottom_controls);
        centerPlayPause = findViewById(R.id.center_play_pause);
        btnPlayPause = findViewById(R.id.btn_play_pause);
        btnFullscreen = findViewById(R.id.btn_fullscreen);
        btnPrev = findViewById(R.id.btn_prev);
        btnNext = findViewById(R.id.btn_next);
        btnPlaylist = findViewById(R.id.btn_playlist);
        seekBar = findViewById(R.id.seek_bar);
        timeCurrent = findViewById(R.id.time_current);
        timeDuration = findViewById(R.id.time_duration);
        loadingIndicator = findViewById(R.id.loading_indicator);
        errorMessage = findViewById(R.id.error_message);
        infoTitle = findViewById(R.id.info_title);
        infoAuthor = findViewById(R.id.info_author);
        videoContainer = findViewById(R.id.video_container);
        infoScroll = findViewById(R.id.info_scroll);
        bottomContainer = findViewById(R.id.bottom_container);
        playlistIndicator = findViewById(R.id.playlist_indicator);
        btnQuality = findViewById(R.id.btn_quality);

        // 竖屏播放列表面板（在 bottom_container 内）
        portraitPlaylistPanel = findViewById(R.id.portrait_playlist_panel);

        // 横屏播放列表抽屉（在 video_container 内）
        landscapePlaylistDrawer = findViewById(R.id.landscape_playlist_drawer);
        // 横屏全屏时抽屉顶部需要避开状态栏
        ViewCompat.setOnApplyWindowInsetsListener(landscapePlaylistDrawer, (v, insets) -> {
            int statusBarTop = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top;
            v.setPadding(v.getPaddingLeft(), statusBarTop, v.getPaddingRight(), v.getPaddingBottom());
            return insets;
        });

        // RecyclerView（两个布局都包含同一个 include，取其中之一）
        playlistRecyclerView = portraitPlaylistPanel.findViewById(R.id.playlist_recycler_view);

        // 播放列表面板关闭按钮
        ImageButton btnClosePlaylist = findViewById(R.id.btn_close_playlist);
        if (btnClosePlaylist != null) {
            btnClosePlaylist.setOnClickListener(v -> hidePlaylistPanel());
        }
    }

    private void initPlaylist() {
        if (playlistSize <= 1) return;

        // 显示播放列表控件
        btnPrev.setVisibility(View.VISIBLE);
        btnNext.setVisibility(View.VISIBLE);
        btnPlaylist.setVisibility(View.VISIBLE);
        playlistIndicator.setVisibility(View.VISIBLE);
        updatePlaylistIndicator();

        // 设置 RecyclerView 适配器
        playlistAdapter = new MvPlaylistAdapter(playlistJson, currentIndex);
        playlistRecyclerView.setLayoutManager(new LinearLayoutManager(this));
        playlistRecyclerView.setAdapter(playlistAdapter);
        playlistRecyclerView.scrollToPosition(currentIndex);

        // 如果之前保存了面板可见状态，或竖屏有播放列表时自动显示
        int orientation = getResources().getConfiguration().orientation;
        if (isPlaylistVisible || (playlistSize > 1 && orientation != Configuration.ORIENTATION_LANDSCAPE)) {
            showPlaylistPanel();
        }
    }

    private void initPlayer() {
        if (videoUrl == null || videoUrl.isEmpty()) {
            showError("视频地址无效");
            return;
        }

        // ExoPlayer + FFmpeg 软件解码
        DefaultRenderersFactory renderersFactory = new DefaultRenderersFactory(this);
        renderersFactory.setExtensionRendererMode(
            DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
        );

        player = new ExoPlayer.Builder(this)
            .setRenderersFactory(renderersFactory)
            .setLoadControl(new DefaultLoadControl.Builder()
                .setBufferDurationsMs(5000, 10000, 1000, 1000)
                .build())
            .build();

        playerView.setPlayer(player);

        // 监听播放事件
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int playbackState) {
                switch (playbackState) {
                    case Player.STATE_BUFFERING:
                        loadingIndicator.setVisibility(View.VISIBLE);
                        break;
                    case Player.STATE_READY:
                        loadingIndicator.setVisibility(View.GONE);
                        errorMessage.setVisibility(View.GONE);
                        isSwitchingQuality = false;
                        long durationMs = player.getDuration();
                        if (durationMs > 0) {
                            timeDuration.setText(formatTime(durationMs));
                        }
                        if (savedPosition > 0) {
                            player.seekTo(savedPosition);
                            savedPosition = 0;
                        }
                        break;
                    case Player.STATE_ENDED:
                        stopProgressUpdates();
                        // 有播放列表时自动播放下一个
                        if (playlistSize > 1 && currentIndex < playlistSize - 1) {
                            requestVideo(currentIndex + 1);
                        } else {
                            // 单曲或列表末尾，显示重播
                            btnPlayPause.setImageResource(R.drawable.ic_play);
                            centerPlayPause.setImageResource(R.drawable.ic_play);
                            showControls();
                        }
                        break;
                }
            }

            @Override
            public void onPlayerError(@NonNull PlaybackException error) {
                loadingIndicator.setVisibility(View.GONE);
                // 播放失败自动换源：尝试下一个片源
                if (sourceHashes != null && currentSourceIndex < sourceHashes.length - 1) {
                    currentSourceIndex++;
                    Log.w(TAG, "播放失败，自动切换到源: " + sourceLabels[currentSourceIndex]);
                    requestSourceUrl(currentSourceIndex);
                } else {
                    String msg = error.getMessage();
                    if (msg == null) msg = "播放出错";
                    Log.e(TAG, "ExoPlayer error: " + msg, error);
                    showError(msg);
                }
            }

            @Override
            public void onIsPlayingChanged(boolean playing) {
                btnPlayPause.setImageResource(playing ? R.drawable.ic_pause : R.drawable.ic_play);
                centerPlayPause.setImageResource(playing ? R.drawable.ic_pause : R.drawable.ic_play);
                if (playing) {
                    startProgressUpdates();
                    // 仅横屏模式下自动隐藏控件
                    if (getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE) {
                        hideControlsDelayed();
                    }
                } else {
                    stopProgressUpdates();
                    showControls();
                }
            }

            @Override
            public void onVideoSizeChanged(@NonNull VideoSize videoSize) {
            }
        });

        // 设置媒体源并准备，自动播放
        loadMediaSource(videoUrl);

        loadingIndicator.setVisibility(View.VISIBLE);
        Log.i(TAG, "MV 播放加载: " + videoUrl);
    }

    private float touchDownX = 0;
    private float touchDownY = 0;
    private boolean isTouchTap = false;

    private void setupControls() {
        // 视频区域触摸处理：
        // 竖屏/横屏统一：左侧50%切换功能条，右侧50%切换播放列表
        // 竖屏模式下功能条不自动隐藏，但可手动切换
        playerView.setOnTouchListener((v, event) -> {
            if (event.getAction() == android.view.MotionEvent.ACTION_DOWN) {
                touchDownX = event.getX();
                touchDownY = event.getY();
                isTouchTap = true;
            } else if (event.getAction() == android.view.MotionEvent.ACTION_MOVE) {
                float dx = Math.abs(event.getX() - touchDownX);
                float dy = Math.abs(event.getY() - touchDownY);
                if (dx > 20 || dy > 20) isTouchTap = false;
            } else if (event.getAction() == android.view.MotionEvent.ACTION_UP && isTouchTap) {
                boolean isRightSide = touchDownX > v.getWidth() * 0.5f;
                if (isRightSide && playlistSize > 1) {
                    // 右侧50%：切换播放列表显隐
                    if (isPlaylistVisible) {
                        hidePlaylistPanel();
                    } else {
                        showPlaylistPanel();
                    }
                } else {
                    // 左侧50%（或无播放列表时）：切换功能条显隐
                    toggleControlsVisibility();
                }
            }
            // 消费触摸事件，使 PlayerView 成为触摸目标，确保收到完整的 DOWN/MOVE/UP 序列。
            // use_controller="false" 已禁用 PlayerView 内置手势，返回 true 不会产生副作用。
            return true;
        });

        // 注意：不设置 controlsRoot.setOnClickListener，否则 controls_root 会消费所有触摸事件，
        // 导致 player_view 的触摸监听器收不到事件。空白区域的触摸由 player_view 的
        // setOnTouchListener 统一处理（50/50 分区逻辑）。子按钮各自处理自己的点击。

        // 播放/暂停按钮
        btnPlayPause.setOnClickListener(v -> togglePlayPause());
        centerPlayPause.setOnClickListener(v -> togglePlayPause());

        // 全屏按钮
        btnFullscreen.setOnClickListener(v -> toggleFullscreen());

        // 上一个/下一个
        btnPrev.setOnClickListener(v -> playPrev());
        btnNext.setOnClickListener(v -> playNext());

        // 播放列表按钮
        btnPlaylist.setOnClickListener(v -> togglePlaylistPanel());

        // 画质选择按钮
        if (sourceHashes != null && sourceHashes.length > 1) {
            btnQuality.setVisibility(View.VISIBLE);
            btnQuality.setOnClickListener(v -> showQualityDialog());
            updateQualityBadge();
        }

        // 进度条
        seekBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                if (fromUser && player != null) {
                    long duration = player.getDuration();
                    if (duration > 0) {
                        long position = (long) ((progress / 1000.0) * duration);
                        timeCurrent.setText(formatTime(position));
                    }
                }
            }

            @Override
            public void onStartTrackingTouch(SeekBar seekBar) {
                isSeeking = true;
                cancelHideControls();
            }

            @Override
            public void onStopTrackingTouch(SeekBar seekBar) {
                isSeeking = false;
                if (player != null) {
                    long duration = player.getDuration();
                    if (duration > 0) {
                        long position = (long) ((seekBar.getProgress() / 1000.0) * duration);
                        player.seekTo(position);
                    }
                }
                // 仅横屏模式下拖动结束后自动隐藏控件
                if (getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE) {
                    hideControlsDelayed();
                }
            }
        });
    }

    // ── 播放控制 ──

    private void togglePlayPause() {
        if (player == null) return;
        if (player.isPlaying()) {
            player.pause();
        } else {
            if (player.getPlaybackState() == Player.STATE_ENDED) {
                player.seekTo(0);
            }
            player.play();
        }
    }

    private void toggleFullscreen() {
        int currentOrientation = getResources().getConfiguration().orientation;
        if (currentOrientation == Configuration.ORIENTATION_LANDSCAPE) {
            finish();
        } else {
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        }
    }

    // ── 画质选择 ──

    private void showQualityDialog() {
        if (sourceLabels == null || sourceLabels.length == 0) return;

        // 取消自动隐藏控件
        cancelHideControls();

        new AlertDialog.Builder(this)
            .setTitle("画质选择")
            .setSingleChoiceItems(sourceLabels, currentSourceIndex, (dialog, which) -> {
                dialog.dismiss();
                if (which != currentSourceIndex) {
                    switchSource(which);
                }
            })
            .setNegativeButton("取消", null)
            .show();
    }

    /**
     * 手动切换画质。
     */
    private void switchSource(int index) {
        if (index < 0 || index >= sourceHashes.length) return;
        currentSourceIndex = index;
        isSwitchingQuality = true;
        updateQualityBadge();
        loadingIndicator.setVisibility(View.VISIBLE);
        errorMessage.setVisibility(View.GONE);

        // 保存当前播放位置
        if (player != null) {
            savedPosition = player.getCurrentPosition();
        }

        requestSourceUrl(index);
    }

    /**
     * 请求指定片源的 URL。
     * 通过 NativeAudioPlugin 发射事件到 WebView，由 Vue 层解析 URL 后回调 loadNextVideo。
     */
    private void requestSourceUrl(int index) {
        if (sourceHashes == null || index < 0 || index >= sourceHashes.length) return;
        String hash = sourceHashes[index];
        loadingIndicator.setVisibility(View.VISIBLE);
        errorMessage.setVisibility(View.GONE);
        Log.i(TAG, "MV 画质切换: 请求源 " + index + " hash=" + hash);

        NativeAudioPlugin.emitStaticEvent("mvPlaylistNeedUrl",
            "{\"index\":" + currentIndex + ",\"hash\":\"" + hash + "\",\"switchQuality\":true}");
    }

    private void updateQualityBadge() {
        if (btnQuality != null && sourceLabels != null && sourceLabels.length > 0) {
            btnQuality.setText(sourceLabels[currentSourceIndex]);
        }
    }

    // ── 播放列表控制 ──

    public void playPrev() {
        if (playlistSize <= 1 || currentIndex <= 0) return;
        requestVideo(currentIndex - 1);
    }

    public void playNext() {
        if (playlistSize <= 1 || currentIndex >= playlistSize - 1) return;
        requestVideo(currentIndex + 1);
    }

    // ── 公共访问器（供 MediaNotificationService 的 MediaSession 回调使用）──

    public boolean isPlayerPlaying() {
        return player != null && player.isPlaying();
    }

    public void playVideo() {
        if (player != null) {
            if (player.getPlaybackState() == Player.STATE_ENDED) {
                player.seekTo(0);
            }
            player.play();
        }
    }

    public void pauseVideo() {
        if (player != null && player.isPlaying()) {
            player.pause();
        }
    }

    /**
     * 请求播放指定索引的 MV。
     * 通过 NativeAudioPlugin 发射事件到 WebView，由 Vue 层解析 URL 后回调 loadNextVideo。
     */
    private void requestVideo(int index) {
        if (index < 0 || index >= playlistSize) return;
        String hash = getPlaylistItemField(index, "hash");
        loadingIndicator.setVisibility(View.VISIBLE);
        errorMessage.setVisibility(View.GONE);
        Log.i(TAG, "MV playlist: requesting index " + index + " hash=" + hash);

        NativeAudioPlugin.emitStaticEvent("mvPlaylistNeedUrl",
            "{\"index\":" + index + ",\"hash\":\"" + hash + "\"}");
    }

    /**
     * 由 NativeAudioPlugin 调用：加载指定 MV 的 URL 并开始播放。
     * 这是无缝切换——不重启 Activity。
     */
    public void loadNextVideo(String url, String title, String author, String coverUrl, int index) {
        if (player == null) return;
        currentIndex = index;
        videoTitle = title;
        videoAuthor = author;

        // 更新信息区
        infoTitle.setText(title);
        infoAuthor.setText(author);

        // 更新播放列表指示
        updatePlaylistIndicator();
        if (playlistAdapter != null) {
            playlistAdapter.setCurrentIndex(index);
        }
        if (playlistRecyclerView != null) {
            playlistRecyclerView.scrollToPosition(index);
        }

        // 创建新媒体源并播放
        loadMediaSource(url);

        Log.i(TAG, "MV playlist: loaded index " + index + " - " + title);
    }

    /**
     * 加载媒体源并开始准备播放。
     */
    private void loadMediaSource(String url) {
        MediaItem mediaItem = new MediaItem.Builder().setUri(url).build();
        player.setMediaItem(mediaItem);
        player.setPlayWhenReady(true);
        player.prepare();
    }

    // ── 播放列表面板 ──

    private void togglePlaylistPanel() {
        if (isPlaylistVisible) {
            hidePlaylistPanel();
        } else {
            showPlaylistPanel();
        }
    }

    private void showPlaylistPanel() {
        if (playlistSize <= 1) return;
        isPlaylistVisible = true;

        int orientation = getResources().getConfiguration().orientation;
        if (orientation == Configuration.ORIENTATION_LANDSCAPE) {
            // 横屏：右侧抽屉
            landscapePlaylistDrawer.setVisibility(View.VISIBLE);
            // 横屏用抽屉内的 RecyclerView
            RecyclerView landRv = landscapePlaylistDrawer.findViewById(R.id.playlist_recycler_view);
            if (landRv != null && landRv.getAdapter() == null) {
                landRv.setLayoutManager(new LinearLayoutManager(this));
                landRv.setAdapter(playlistAdapter);
            }
            if (landRv != null) landRv.scrollToPosition(currentIndex);
        } else {
            // 竖屏：替换信息区
            infoScroll.setVisibility(View.GONE);
            portraitPlaylistPanel.setVisibility(View.VISIBLE);
        }
    }

    private void hidePlaylistPanel() {
        isPlaylistVisible = false;
        landscapePlaylistDrawer.setVisibility(View.GONE);
        portraitPlaylistPanel.setVisibility(View.GONE);
        // 竖屏恢复信息区
        int orientation = getResources().getConfiguration().orientation;
        if (orientation != Configuration.ORIENTATION_LANDSCAPE) {
            infoScroll.setVisibility(View.VISIBLE);
        }
    }

    // ── 控件显隐 ──

    private void toggleControlsVisibility() {
        if (isShowingControls) {
            hideControls();
        } else {
            showControls();
        }
    }

    private void showControls() {
        isShowingControls = true;
        controlsRoot.setVisibility(View.VISIBLE);
        centerPlayPause.setVisibility(View.VISIBLE);
        bottomControls.setVisibility(View.VISIBLE);
        cancelHideControls();
        // 仅横屏模式下自动隐藏控件，竖屏始终显示
        int orientation = getResources().getConfiguration().orientation;
        if (orientation == Configuration.ORIENTATION_LANDSCAPE
                && player != null && player.isPlaying()) {
            hideControlsDelayed();
        }
    }

    private void hideControls() {
        isShowingControls = false;
        controlsRoot.setVisibility(View.GONE);
        centerPlayPause.setVisibility(View.GONE);
        bottomControls.setVisibility(View.GONE);
        cancelHideControls();
    }

    private void hideControlsDelayed() {
        cancelHideControls();
        hideControlsRunnable = () -> {
            if (player != null && player.isPlaying() && !isSeeking) {
                hideControls();
            }
        };
        handler.postDelayed(hideControlsRunnable, HIDE_CONTROLS_DELAY_MS);
    }

    private void cancelHideControls() {
        if (hideControlsRunnable != null) {
            handler.removeCallbacks(hideControlsRunnable);
            hideControlsRunnable = null;
        }
    }

    // ── 进度更新 ──

    private void startProgressUpdates() {
        stopProgressUpdates();
        progressUpdateRunnable = new Runnable() {
            @Override
            public void run() {
                if (player == null || isSeeking) return;
                updateProgress();
                handler.postDelayed(this, PROGRESS_UPDATE_INTERVAL_MS);
            }
        };
        handler.post(progressUpdateRunnable);
    }

    private void stopProgressUpdates() {
        if (progressUpdateRunnable != null) {
            handler.removeCallbacks(progressUpdateRunnable);
            progressUpdateRunnable = null;
        }
    }

    private void updateProgress() {
        if (player == null) return;
        long position = player.getCurrentPosition();
        long duration = player.getDuration();
        timeCurrent.setText(formatTime(position));
        if (duration > 0) {
            seekBar.setProgress((int) ((position * 1000.0) / duration));
        }
    }

    // ── 横竖屏布局 ──

    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // 先隐藏面板再重新根据方向显示
        boolean wasVisible = isPlaylistVisible;
        hidePlaylistPanel();
        applyOrientationLayout(newConfig.orientation);
        if (wasVisible) showPlaylistPanel();
    }

    private void applyOrientationLayout(int orientation) {
        if (orientation == Configuration.ORIENTATION_LANDSCAPE) {
            // 横屏：全屏视频，隐藏底部信息区
            bottomContainer.setVisibility(View.GONE);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT
            );
            params.weight = 0;
            videoContainer.setLayoutParams(params);
            btnFullscreen.setImageResource(R.drawable.ic_fullscreen_exit);

            if ("landscape".equals(screenOrientation)) {
                // 横屏锁定模式：保持系统栏可见，视频缩放到系统栏之间
                exitImmersiveMode();

                ViewCompat.setOnApplyWindowInsetsListener(videoContainer, (v, insets) -> {
                    int navBarHeight = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom;
                    int statusBarHeight = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top;

                    // 兼容刘海屏等异形屏的安全边距
                    int safeLeft = 0;
                    int safeRight = 0;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && insets.getDisplayCutout() != null) {
                        safeLeft = insets.getDisplayCutout().getSafeInsetLeft();
                        safeRight = insets.getDisplayCutout().getSafeInsetRight();
                    }

                    // 给 PlayerView 设置 Margin，视频不延申到状态栏和导航栏
                    FrameLayout.LayoutParams playerLp = (FrameLayout.LayoutParams) playerView.getLayoutParams();
                    playerLp.setMargins(safeLeft, statusBarHeight, safeRight, navBarHeight);
                    playerView.setLayoutParams(playerLp);

                    // 给控制层也设置 Margin
                    if (controlsRoot != null) {
                        FrameLayout.LayoutParams controlsLp = (FrameLayout.LayoutParams) controlsRoot.getLayoutParams();
                        controlsLp.setMargins(safeLeft, statusBarHeight, safeRight, navBarHeight);
                        controlsRoot.setLayoutParams(controlsLp);
                    }

                    return insets;
                });
            } else {
                // 竖屏锁定 / 自动旋转模式：真正沉浸式全屏，隐藏状态栏和导航栏
                enterImmersiveMode();

                // 沉浸模式下视频铺满全屏，仅处理刘海屏安全边距
                ViewCompat.setOnApplyWindowInsetsListener(videoContainer, (v, insets) -> {
                    int safeLeft = 0;
                    int safeRight = 0;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && insets.getDisplayCutout() != null) {
                        safeLeft = insets.getDisplayCutout().getSafeInsetLeft();
                        safeRight = insets.getDisplayCutout().getSafeInsetRight();
                    }

                    FrameLayout.LayoutParams playerLp = (FrameLayout.LayoutParams) playerView.getLayoutParams();
                    playerLp.setMargins(safeLeft, 0, safeRight, 0);
                    playerView.setLayoutParams(playerLp);

                    if (controlsRoot != null) {
                        FrameLayout.LayoutParams controlsLp = (FrameLayout.LayoutParams) controlsRoot.getLayoutParams();
                        controlsLp.setMargins(safeLeft, 0, safeRight, 0);
                        controlsRoot.setLayoutParams(controlsLp);
                    }

                    return insets;
                });
            }
        } else {
            // 竖屏：视频 + 信息区
            bottomContainer.setVisibility(View.VISIBLE);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0
            );
            params.weight = 4;
            videoContainer.setLayoutParams(params);
            exitImmersiveMode();
            btnFullscreen.setImageResource(R.drawable.ic_fullscreen);

            // 竖屏切回时，清空之前设置的 Margin，恢复原本布局
            FrameLayout.LayoutParams playerLp = (FrameLayout.LayoutParams) playerView.getLayoutParams();
            playerLp.setMargins(0, 0, 0, 0);
            playerView.setLayoutParams(playerLp);

            if (controlsRoot != null) {
                FrameLayout.LayoutParams controlsLp = (FrameLayout.LayoutParams) controlsRoot.getLayoutParams();
                controlsLp.setMargins(0, 0, 0, 0);
                controlsRoot.setLayoutParams(controlsLp);
            }

            ViewCompat.setOnApplyWindowInsetsListener(videoContainer, null);
        }
    }

    private void enterImmersiveMode() {
        // 隐藏状态栏和导航栏，真正沉浸式全屏
        WindowInsetsControllerCompat controller = WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        if (controller != null) {
            controller.hide(WindowInsetsCompat.Type.systemBars());
            controller.setSystemBarsBehavior(WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    private void exitImmersiveMode() {
        // 显示状态栏和导航栏
        WindowInsetsControllerCompat controller = WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        if (controller != null) {
            controller.show(WindowInsetsCompat.Type.systemBars());
        }
    }

    // ── 生命周期 ──

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        if (player != null) {
            outState.putLong("savedPosition", player.getCurrentPosition());
        }
        outState.putInt("savedCurrentIndex", currentIndex);
        outState.putBoolean("isPlaylistVisible", isPlaylistVisible);
        outState.putInt("currentSourceIndex", currentSourceIndex);
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (player != null) {
            player.pause();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        currentInstance = null;
        stopProgressUpdates();
        cancelHideControls();
        if (player != null) {
            player.stop();
            player.release();
            player = null;
        }
        playerView.setPlayer(null);
    }

    @Override
    public void onBackPressed() {
        if (getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE) {
            // 横屏全屏时，返回键直接退出MV播放器，回到之前的页面
            finish();
            return;
        }
        super.onBackPressed();
    }

    // ── 错误显示 ──

    private void showError(String message) {
        if (errorMessage != null) {
            errorMessage.setText(message);
            errorMessage.setVisibility(View.VISIBLE);
        }
        if (loadingIndicator != null) {
            loadingIndicator.setVisibility(View.GONE);
        }
    }

    // ── 播放列表辅助方法 ──

    private String getPlaylistItemField(int index, String field) {
        try {
            if (playlistJson != null && index >= 0 && index < playlistJson.length()) {
                return playlistJson.getJSONObject(index).optString(field, "");
            }
        } catch (Exception ignored) {}
        return "";
    }

    private void updatePlaylistIndicator() {
        if (playlistIndicator != null && playlistSize > 1) {
            playlistIndicator.setText((currentIndex + 1) + " / " + playlistSize);
        }
    }

    // ── 工具方法 ──

    private static String formatTime(long ms) {
        long totalSeconds = ms / 1000;
        long minutes = totalSeconds / 60;
        long seconds = totalSeconds % 60;
        if (minutes >= 60) {
            long hours = minutes / 60;
            minutes = minutes % 60;
            return String.format("%d:%02d:%02d", hours, minutes, seconds);
        }
        return String.format("%d:%02d", minutes, seconds);
    }

    // ── 播放列表适配器 ──

    private class MvPlaylistAdapter extends RecyclerView.Adapter<MvPlaylistAdapter.ViewHolder> {

        private final JSONArray items;
        private int activeIndex;

        MvPlaylistAdapter(JSONArray items, int activeIndex) {
            this.items = items;
            this.activeIndex = activeIndex;
        }

        void setCurrentIndex(int index) {
            int oldIndex = activeIndex;
            activeIndex = index;
            if (oldIndex >= 0 && oldIndex < getItemCount()) {
                notifyItemChanged(oldIndex);
            }
            if (index >= 0 && index < getItemCount()) {
                notifyItemChanged(index);
            }
        }

        @NonNull
        @Override
        public ViewHolder onCreateViewHolder(@NonNull android.view.ViewGroup parent, int viewType) {
            android.view.View view = getLayoutInflater().inflate(R.layout.mv_playlist_item, parent, false);
            return new ViewHolder(view);
        }

        @Override
        public void onBindViewHolder(@NonNull ViewHolder holder, int position) {
            try {
                JSONObject item = items.getJSONObject(position);
                String title = item.optString("title", "");
                String artist = item.optString("artist", "");

                holder.itemTitle.setText(title);
                holder.itemAuthor.setText(artist);
                holder.itemIndex.setText(String.valueOf(position + 1));

                boolean isActive = (position == activeIndex);
                holder.itemIndicator.setVisibility(isActive ? View.VISIBLE : View.INVISIBLE);
                holder.itemTitle.setTextColor(isActive ? Color.parseColor("#1DB954") : Color.WHITE);
                holder.itemView.setBackgroundColor(isActive ? Color.parseColor("#1A1DB954") : Color.TRANSPARENT);

                holder.itemView.setOnClickListener(v -> {
                    int pos = holder.getAdapterPosition();
                    if (pos != RecyclerView.NO_POSITION && pos != activeIndex) {
                        requestVideo(pos);
                    }
                });

            } catch (Exception e) {
                Log.e(TAG, "Playlist bind error", e);
            }
        }

        @Override
        public int getItemCount() {
            return items != null ? items.length() : 0;
        }

        class ViewHolder extends RecyclerView.ViewHolder {
            View itemIndicator;
            TextView itemIndex;
            TextView itemTitle;
            TextView itemAuthor;

            ViewHolder(android.view.View itemView) {
                super(itemView);
                itemIndicator = itemView.findViewById(R.id.item_indicator);
                itemIndex = itemView.findViewById(R.id.item_index);
                itemTitle = itemView.findViewById(R.id.item_title);
                itemAuthor = itemView.findViewById(R.id.item_author);
            }
        }
    }
}
