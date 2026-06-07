# === EchoMusic ProGuard Rules ===

# Preserve line numbers for crash reports
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# === GeckoView ===
-keep class org.mozilla.geckoview.** { *; }
-keep class org.mozilla.gecko.** { *; }
-dontwarn org.mozilla.gecko.**

# === SnakeYAML (java.beans not available on Android) ===
-dontwarn java.beans.BeanInfo
-dontwarn java.beans.FeatureDescriptor
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.Introspector
-dontwarn java.beans.PropertyDescriptor
-dontwarn org.yaml.snakeyaml.**

# === NanoHTTPD ===
-keep class fi.iki.elonen.** { *; }

# === AndroidX Media / MediaSession ===
-keep class androidx.media.** { *; }

# === ExoPlayer (Media3) + FFmpeg 解码器 ===
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
# FFmpeg 扩展解码器（Jellyfin 预编译包）的 JNI 原生方法
-keep class org.jellyfin.media3.** { *; }
-keepclassmembers class androidx.media3.decoder.ffmpeg.** {
    *;
}

# === Native Bridge (accessed via GeckoView JS) ===
-keepclassmembers class com.muye.ecells.music.NativeAudioPlugin {
    public *;
}
-keepclassmembers class com.muye.ecells.music.MainActivity {
    public void evalJs(java.lang.String);
    public void setKeepScreenOn(boolean);
    public void setThemeAutoMode(java.lang.String);
}

# === Parcelable / Serializable ===
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    !static !transient <fields>;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
}

# === General Android ===
-keep public class * extends android.app.Service
-keep public class * extends android.app.Activity
-keepclassmembers class * extends android.app.Service {
    public void onCreate();
    public void onDestroy();
    public int onStartCommand(android.content.Intent, int, int);
    public android.os.IBinder onBind(android.content.Intent);
}
