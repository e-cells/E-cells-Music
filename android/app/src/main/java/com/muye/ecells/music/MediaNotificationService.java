package com.muye.ecells.music;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Handler;
import android.os.Looper;
import android.support.v4.media.MediaBrowserCompat;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.media.session.MediaButtonReceiver;
import androidx.media.MediaBrowserServiceCompat;

import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class MediaNotificationService extends MediaBrowserServiceCompat {

    private static final String TAG = "MediaNotification";
    private static final int NOTIFICATION_ID = 1001;
    private static final String CHANNEL_ID = "echomusic_playback";

    public static final String ACTION_UPDATE = "com.muye.ecells.music.UPDATE";
    public static final String ACTION_STOP = "com.muye.ecells.music.STOP";
    public static final String ACTION_PLAY_PAUSE = "com.muye.ecells.music.PLAY_PAUSE";
    public static final String ACTION_NEXT = "com.muye.ecells.music.NEXT";
    public static final String ACTION_PREV = "com.muye.ecells.music.PREV";

    private static WeakReference<MediaNotificationService> instanceRef;
    private static MainActivity pendingActivity;

    private MediaSessionCompat mediaSession;
    private MainActivity activity;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private Bitmap cachedArtwork;
    private String lastCoverUrl;
    private String currentTitle = "";
    private String currentArtist = "";
    private boolean isPlaying = false;
    private boolean wasPlayingBeforeDuck = false;
    private long currentDurationMs = 0;
    private long currentPositionMs = 0;

    private AudioManager audioManager;
    private AudioFocusRequest focusRequest;
    private boolean hasAudioFocus = false;

    // <== 新增：监听耳机拔出/蓝牙断开的防社死广播
    private final BroadcastReceiver noisyReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(intent.getAction())) {
                if (isPlaying) {
                    Log.i(TAG, "Audio becoming noisy (headphone disconnected), pausing playback.");
                    emitMediaButton("mediaButtonPause");
                }
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        instanceRef = new WeakReference<>(this);
        if (pendingActivity != null) {
            this.activity = pendingActivity;
            pendingActivity = null;
        }
        createNotificationChannel();
        initMediaSession();
        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        requestAudioFocus();
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        // <== 新增：注册防社死广播
        registerReceiver(noisyReceiver, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
        
        Log.i(TAG, "MediaNotificationService created");
    }

    public static MediaNotificationService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    public static void setPendingActivity(MainActivity act) {
        pendingActivity = act;
    }

    // ── MediaBrowserServiceCompat ──

    @Nullable
    @Override
    public BrowserRoot onGetRoot(@NonNull String clientPackageName, int clientUid, @Nullable Bundle rootHints) {
        return new BrowserRoot("echomusic_root", null);
    }

    @Override
    public void onLoadChildren(@NonNull String parentId, @NonNull Result<List<MediaBrowserCompat.MediaItem>> result) {
        result.sendResult(Collections.emptyList());
    }

    private void initMediaSession() {
        mediaSession = new MediaSessionCompat(this, "EchoMusic");
        mediaSession.setCallback(new MediaSessionCallbacks());
        mediaSession.setFlags(
            MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS |
            MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS |
            MediaSessionCompat.FLAG_HANDLES_QUEUE_COMMANDS
        );
        mediaSession.setActive(true);

        PlaybackStateCompat state = new PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY |
                PlaybackStateCompat.ACTION_PAUSE |
                PlaybackStateCompat.ACTION_PLAY_PAUSE |
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT |
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS |
                PlaybackStateCompat.ACTION_SEEK_TO |
                PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH |
                PlaybackStateCompat.ACTION_STOP
            )
            .setState(PlaybackStateCompat.STATE_PAUSED, 0, 1.0f)
            .build();
        mediaSession.setPlaybackState(state);
        setSessionToken(mediaSession.getSessionToken());
    }

    public void setActivity(MainActivity activity) {
        this.activity = activity;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            String action = intent.getAction();
            if (ACTION_STOP.equals(action)) {
                stopSelf();
                return START_NOT_STICKY;
            } else if (ACTION_PLAY_PAUSE.equals(action)) {
                if (isPlaying) {
                    mediaSession.getController().getTransportControls().pause();
                } else {
                    mediaSession.getController().getTransportControls().play();
                }
            } else if (ACTION_NEXT.equals(action)) {
                mediaSession.getController().getTransportControls().skipToNext();
            } else if (ACTION_PREV.equals(action)) {
                mediaSession.getController().getTransportControls().skipToPrevious();
            } else if (Intent.ACTION_MEDIA_BUTTON.equals(action)) {
                MediaButtonReceiver.handleIntent(mediaSession, intent);
            }
        }
        return START_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        instanceRef = null;
        abandonAudioFocus();
        if (mediaSession != null) {
            mediaSession.setActive(false);
            mediaSession.release();
            mediaSession = null;
        }
        if (cachedArtwork != null && !cachedArtwork.isRecycled()) {
            cachedArtwork.recycle();
            cachedArtwork = null;
        }
        lastCoverUrl = null;
        
        // <== 新增：注销防社死广播
        try {
            unregisterReceiver(noisyReceiver);
        } catch (Exception e) {
            Log.e(TAG, "Failed to unregister noisyReceiver", e);
        }
        
        super.onDestroy();
        Log.i(TAG, "MediaNotificationService destroyed");
    }

    // ── Called from NativeAudioPlugin via MainActivity ──

    public void updateMetadata(String title, String artist, String coverUrl, long durationMs) {
        this.currentTitle = title != null ? title : "";
        this.currentArtist = artist != null ? artist : "";
        this.currentDurationMs = durationMs;

        MediaMetadataCompat.Builder meta = new MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, this.currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, this.currentArtist)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, "")
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs);

        if (cachedArtwork != null && !cachedArtwork.isRecycled()) {
            meta.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, cachedArtwork);
        }
        mediaSession.setMetadata(meta.build());

        List<MediaSessionCompat.QueueItem> dummyQueue = new ArrayList<>();
        dummyQueue.add(new MediaSessionCompat.QueueItem(
            new android.support.v4.media.MediaDescriptionCompat.Builder()
                .setMediaId("current")
                .setTitle(this.currentTitle)
                .build(), 0));
        dummyQueue.add(new MediaSessionCompat.QueueItem(
            new android.support.v4.media.MediaDescriptionCompat.Builder()
                .setMediaId("next")
                .setTitle("下一首")
                .build(), 1));
        mediaSession.setQueue(dummyQueue);

        refreshNotification();

        if (coverUrl != null && !coverUrl.isEmpty() && !coverUrl.equals(lastCoverUrl)) {
            loadCoverArtwork(coverUrl);
        }
    }

    public void updatePlaybackState(boolean playing, long positionMs, long durationMs) {
        this.isPlaying = playing;
        this.currentPositionMs = positionMs;
        if (durationMs > 0) this.currentDurationMs = durationMs;
        if (playing) requestAudioFocus();

        int state = playing ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED;
        PlaybackStateCompat playbackState = new PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY |
                PlaybackStateCompat.ACTION_PAUSE |
                PlaybackStateCompat.ACTION_PLAY_PAUSE |
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT |
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS |
                PlaybackStateCompat.ACTION_SEEK_TO |
                PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH |
                PlaybackStateCompat.ACTION_STOP
            )
            .setState(state, positionMs, 1.0f)
            .build();
        mediaSession.setPlaybackState(playbackState);
        refreshNotification();
    }

    // ── 内存守护：计算图片的压缩比例 ──
    private int calculateInSampleSize(BitmapFactory.Options options, int reqWidth, int reqHeight) {
        final int height = options.outHeight;
        final int width = options.outWidth;
        int inSampleSize = 1;

        if (height > reqHeight || width > reqWidth) {
            final int halfHeight = height / 2;
            final int halfWidth = width / 2;
            while ((halfHeight / inSampleSize) >= reqHeight
                    && (halfWidth / inSampleSize) >= reqWidth) {
                inSampleSize *= 2;
            }
        }
        return inSampleSize;
    }

    // ── Cover artwork loading ──
    private void loadCoverArtwork(String coverUrl) {
        lastCoverUrl = coverUrl;
        new Thread(() -> {
            try {
                URL url = new URL(coverUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(5000);
                conn.setReadTimeout(5000);
                conn.setRequestProperty("User-Agent", "EchoMusic/1.0");
                InputStream is = conn.getInputStream();

                ByteArrayOutputStream baos = new ByteArrayOutputStream();
                byte[] buffer = new byte[1024];
                int len;
                while ((len = is.read(buffer)) > -1) {
                    baos.write(buffer, 0, len);
                }
                baos.flush();
                byte[] imageBytes = baos.toByteArray();
                
                is.close();
                conn.disconnect();

                BitmapFactory.Options options = new BitmapFactory.Options();
                options.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length, options);

                options.inSampleSize = calculateInSampleSize(options, 400, 400);

                options.inJustDecodeBounds = false;
                options.inPreferredConfig = Bitmap.Config.RGB_565; 
                Bitmap bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length, options);

                if (bitmap != null) {
                    handler.post(() -> {
                        if (cachedArtwork != null && !cachedArtwork.isRecycled()) {
                            cachedArtwork.recycle();
                        }
                        cachedArtwork = bitmap;

                        MediaMetadataCompat.Builder meta = new MediaMetadataCompat.Builder()
                            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
                            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, "")
                            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDurationMs)
                            .putBitmap(MediaMetadataCompat.METADATA_KEY_ART, cachedArtwork);
                        mediaSession.setMetadata(meta.build());
                        refreshNotification();
                    });
                }
            } catch (Exception e) {
                Log.w(TAG, "Failed to load cover safely: " + e.getMessage());
            }
        }).start();
    }

    // ── Notification ──

    private void refreshNotification() {
        try {
            Notification notification = buildNotification();
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) {
                nm.notify(NOTIFICATION_ID, notification);
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to refresh notification", e);
        }
    }

    private Notification buildNotification() {
        Intent contentIntent = new Intent(this, MainActivity.class);
        contentIntent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent contentPending = PendingIntent.getActivity(
            this, 0, contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        int playPauseIcon = isPlaying
            ? R.drawable.ic_pause : R.drawable.ic_play;
        String playPauseLabel = isPlaying ? "暂停" : "播放";

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setContentIntent(contentPending)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(R.drawable.ic_skip_prev, "上一曲", buildMediaActionPendingIntent(PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS))
            .addAction(playPauseIcon, playPauseLabel, buildMediaActionPendingIntent(PlaybackStateCompat.ACTION_PLAY_PAUSE))
            .addAction(R.drawable.ic_skip_next, "下一曲", buildMediaActionPendingIntent(PlaybackStateCompat.ACTION_SKIP_TO_NEXT))
            .setStyle(new androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(mediaSession.getSessionToken())
                .setShowActionsInCompactView(0, 1, 2)
            );

        if (cachedArtwork != null && !cachedArtwork.isRecycled()) {
            builder.setLargeIcon(cachedArtwork);
        }

        return builder.build();
    }

    private PendingIntent buildMediaActionPendingIntent(long action) {
        Intent intent = new Intent(this, MediaNotificationService.class);

        int requestCode;
        if (action == PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS) {
            intent.setAction(ACTION_PREV);
            requestCode = 1;
        } else if (action == PlaybackStateCompat.ACTION_SKIP_TO_NEXT) {
            intent.setAction(ACTION_NEXT);
            requestCode = 3;
        } else {
            intent.setAction(ACTION_PLAY_PAUSE);
            requestCode = 2;
        }

        return PendingIntent.getService(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "EchoMusic 播放控制",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("音乐播放状态和控制");
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) {
                nm.createNotificationChannel(channel);
            }
        }
    }

    // ── MediaSession Callbacks ──

    private class MediaSessionCallbacks extends MediaSessionCompat.Callback {
        @Override
        public void onPlay() {
            // MV 播放器活跃时，控制 MV 播放
            MvPlayerActivity mvActivity = MvPlayerActivity.currentInstance;
            if (mvActivity != null) {
                mvActivity.runOnUiThread(() -> mvActivity.playVideo());
                return;
            }
            emitMediaButton("mediaButtonPlay");
        }

        @Override
        public void onPause() {
            // MV 播放器活跃时，控制 MV 暂停
            MvPlayerActivity mvActivity = MvPlayerActivity.currentInstance;
            if (mvActivity != null) {
                mvActivity.runOnUiThread(() -> mvActivity.pauseVideo());
                return;
            }
            emitMediaButton("mediaButtonPause");
        }

        @Override
        public void onSkipToNext() {
            Log.i(TAG, "MediaSession: onSkipToNext triggered");
            // MV 播放器活跃时，切换 MV 下一曲
            MvPlayerActivity mvActivity = MvPlayerActivity.currentInstance;
            if (mvActivity != null) {
                mvActivity.runOnUiThread(() -> mvActivity.playNext());
                return;
            }
            emitMediaButton("mediaButtonNext");
        }

        @Override
        public void onSkipToPrevious() {
            Log.i(TAG, "MediaSession: onSkipToPrevious triggered");
            // MV 播放器活跃时，切换 MV 上一曲
            MvPlayerActivity mvActivity = MvPlayerActivity.currentInstance;
            if (mvActivity != null) {
                mvActivity.runOnUiThread(() -> mvActivity.playPrev());
                return;
            }
            emitMediaButton("mediaButtonPrev");
        }

        @Override
        public void onSeekTo(long pos) {
            emitMediaButton("mediaButtonSeek", pos / 1000.0);
        }

        @Override
        public void onStop() {
            emitMediaButton("mediaButtonStop");
        }

        @Override
        public void onPlayFromSearch(String query, Bundle extras) {
            Log.i(TAG, "Voice search: " + query);
            emitMediaButton("mediaButtonPlayFromSearch", query);
        }

        @Override
        public void onPlayFromMediaId(String mediaId, Bundle extras) {
            Log.i(TAG, "Play from media id: " + mediaId);
            emitMediaButton("mediaButtonPlayFromSearch", mediaId);
        }
    }

    // ── Emit Events to WebView ──

    private void emitMediaButton(String eventName) {
        if (activity != null) {
            handler.post(() -> {
                activity.evalJs(
                    "console.log('[NativeBridge] Triggered: " + eventName + "');" +
                    "if(window.NativeBridge&&window.NativeBridge._listeners['" + eventName + "']){" +
                    "window.NativeBridge._listeners['" + eventName + "'].forEach(function(cb){cb();});}"
                );
            });
        }
    }

    private void emitMediaButton(String eventName, double data) {
        if (activity != null) {
            handler.post(() -> {
                activity.evalJs(
                    "console.log('[NativeBridge] Triggered: " + eventName + "');" +
                    "if(window.NativeBridge&&window.NativeBridge._listeners['" + eventName + "']){" +
                    "window.NativeBridge._listeners['" + eventName + "'].forEach(function(cb){cb(" + data + ");});}"
                );
            });
        }
    }

    private void emitMediaButton(String eventName, String data) {
        if (activity != null) {
            handler.post(() -> {
                String escaped = data.replace("\\", "\\\\").replace("'", "\\'").replace("\"", "\\\"");
                activity.evalJs(
                    "console.log('[NativeBridge] Triggered: " + eventName + "');" +
                    "if(window.NativeBridge&&window.NativeBridge._listeners['" + eventName + "']){" +
                    "window.NativeBridge._listeners['" + eventName + "'].forEach(function(cb){cb('" + escaped + "');});}"
                );
            });
        }
    }

    // ── Audio Focus (with Duck support for car) ──

    private void requestAudioFocus() {
        if (hasAudioFocus) return;
        AudioManager.OnAudioFocusChangeListener focusListener = focusChange -> {
            switch (focusChange) {
                case AudioManager.AUDIOFOCUS_GAIN:
                    if (wasPlayingBeforeDuck) {
                        emitMediaButton("mediaButtonPlay");
                        wasPlayingBeforeDuck = false;
                    }
                    emitMediaButton("mediaButtonUnduck");
                    hasAudioFocus = true;
                    break;
                case AudioManager.AUDIOFOCUS_LOSS:
                    emitMediaButton("mediaButtonPause");
                    abandonAudioFocus();
                    break;
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                    wasPlayingBeforeDuck = isPlaying;
                    emitMediaButton("mediaButtonPause");
                    break;
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                    wasPlayingBeforeDuck = false;
                    emitMediaButton("mediaButtonDuck");
                    break;
            }
        };

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setOnAudioFocusChangeListener(focusListener)
                .build();
            audioManager.requestAudioFocus(focusRequest);
        } else {
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            );
        }
        hasAudioFocus = true;
    }

    private void abandonAudioFocus() {
        if (!hasAudioFocus) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) {
            audioManager.abandonAudioFocusRequest(focusRequest);
        } else {
            audioManager.abandonAudioFocus(null);
        }
        hasAudioFocus = false;
    }
}