package com.muye.ecells.music;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public class ApkUpdateManager {

    private static final String TAG = "ApkUpdate";
    private static final String UPDATE_DIR_NAME = "updates";

    private static ApkUpdateManager instance;

    private final Context context;
    private final File updateDir;
    private final ExecutorService downloadExecutor = Executors.newSingleThreadExecutor();
    private Future<?> activeDownload;
    private volatile boolean isDownloading = false;
    private NativeAudioPlugin plugin;

    private ApkUpdateManager(Context context) {
        this.context = context.getApplicationContext();
        this.updateDir = new File(context.getCacheDir(), UPDATE_DIR_NAME);
        if (!updateDir.exists()) updateDir.mkdirs();
    }

    public static void initialize(Context context) {
        if (instance == null) {
            instance = new ApkUpdateManager(context);
        }
    }

    public static ApkUpdateManager getInstance() {
        return instance;
    }

    public void setPlugin(NativeAudioPlugin plugin) {
        this.plugin = plugin;
    }

    public String getDeviceAbiInfo() {
        String[] supportedAbis = Build.SUPPORTED_ABIS;
        String bestMatch = "arm64-v8a";
        java.util.Set<String> known = java.util.Set.of("arm64-v8a", "armeabi-v7a", "x86", "x86_64");
        for (String abi : supportedAbis) {
            if (known.contains(abi)) {
                bestMatch = abi;
                break;
            }
        }
        StringBuilder abisArray = new StringBuilder("[");
        for (int i = 0; i < supportedAbis.length; i++) {
            if (i > 0) abisArray.append(",");
            abisArray.append("\"").append(supportedAbis[i]).append("\"");
        }
        abisArray.append("]");
        return "{\"abis\":" + abisArray + ",\"primary\":\"" + supportedAbis[0] + "\",\"bestMatch\":\"" + bestMatch + "\"}";
    }

    public void startDownloadApk(String downloadUrl, String fileName) {
        if (isDownloading) return;
        isDownloading = true;
        activeDownload = downloadExecutor.submit(() -> {
            File tempFile = null;
            HttpURLConnection conn = null;
            InputStream is = null;
            FileOutputStream fos = null;
            try {
                tempFile = new File(updateDir, fileName + ".tmp");
                Log.i(TAG, "Starting APK download: " + fileName);

                URL url = new URL(downloadUrl);
                conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(30000);
                conn.setReadTimeout(60000);
                conn.setRequestProperty("User-Agent", "EcellsMusic/1.0");
                conn.setInstanceFollowRedirects(true);
                conn.connect();

                int responseCode = conn.getResponseCode();
                if (responseCode != HttpURLConnection.HTTP_OK) {
                    throw new Exception("HTTP " + responseCode);
                }

                long contentLength = conn.getContentLengthLong();
                is = conn.getInputStream();
                fos = new FileOutputStream(tempFile);

                byte[] buffer = new byte[32768];
                int bytesRead;
                long totalBytes = 0;
                long lastReportBytes = 0;

                while ((bytesRead = is.read(buffer)) != -1) {
                    if (!isDownloading) {
                        Log.i(TAG, "Download cancelled");
                        throw new Exception("Download cancelled");
                    }
                    fos.write(buffer, 0, bytesRead);
                    totalBytes += bytesRead;
                    if (plugin != null && contentLength > 0 && totalBytes - lastReportBytes >= 32768) {
                        float percent = (float) totalBytes / contentLength;
                        lastReportBytes = totalBytes;
                        plugin.emitEvent("updateDownloadProgress",
                            "{\"percent\":" + String.format("%.4f", percent)
                            + ",\"downloadedBytes\":" + totalBytes
                            + ",\"totalBytes\":" + contentLength
                            + ",\"fileName\":\"" + fileName + "\"}");
                    }
                }
                fos.flush();

                File finalFile = new File(updateDir, fileName);
                if (tempFile.renameTo(finalFile)) {
                    tempFile = null;
                    Log.i(TAG, "APK download complete: " + finalFile.getAbsolutePath());
                    if (plugin != null) {
                        plugin.emitEvent("updateDownloadComplete",
                            "{\"filePath\":\"" + finalFile.getAbsolutePath()
                            + "\",\"fileName\":\"" + fileName + "\"}");
                    }
                } else {
                    throw new Exception("Failed to rename temp file");
                }
            } catch (Exception e) {
                Log.e(TAG, "APK download failed", e);
                if (tempFile != null && tempFile.exists()) tempFile.delete();
                if (plugin != null) {
                    plugin.emitEvent("updateDownloadError",
                        "{\"error\":\"" + e.getMessage().replace("\"", "'")
                        + "\",\"fileName\":\"" + fileName + "\"}");
                }
            } finally {
                isDownloading = false;
                if (is != null) try { is.close(); } catch (Exception ignored) {}
                if (fos != null) try { fos.close(); } catch (Exception ignored) {}
                if (conn != null) conn.disconnect();
            }
        });
    }

    public void cancelDownload() {
        isDownloading = false;
        if (activeDownload != null) {
            activeDownload.cancel(true);
            activeDownload = null;
        }
    }

    public String installApk(String apkFilePath) {
        File apkFile = new File(apkFilePath);
        if (!apkFile.exists()) return "APK file not found";
        if (apkFile.length() < 1024) return "APK file too small, likely corrupted";

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!context.getPackageManager().canRequestPackageInstalls()) {
                return "missing_install_permission";
            }
        }

        try {
            Uri apkUri = FileProvider.getUriForFile(
                context,
                context.getPackageName() + ".fileprovider",
                apkFile
            );
            Intent installIntent = new Intent(Intent.ACTION_VIEW);
            installIntent.setDataAndType(apkUri, "application/vnd.android.package-archive");
            installIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            installIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(installIntent);
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    public boolean canInstallApk() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return context.getPackageManager().canRequestPackageInstalls();
        }
        return true;
    }

    public Intent buildInstallPermissionIntent() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
            intent.setData(Uri.parse("package:" + context.getPackageName()));
            return intent;
        }
        return null;
    }

    public void cleanupOldApks() {
        if (updateDir == null || !updateDir.exists()) return;
        File[] files = updateDir.listFiles();
        if (files == null) return;
        for (File f : files) {
            if (f.isFile() && (f.getName().endsWith(".tmp") || f.getName().endsWith(".apk"))) {
                f.delete();
            }
        }
    }

    public void release() {
        cancelDownload();
        downloadExecutor.shutdownNow();
        instance = null;
    }
}
