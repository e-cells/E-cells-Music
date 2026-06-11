package com.muye.ecells.music;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public class AudioCacheManager {

    private static final String TAG = "AudioCache";
    private static final String CACHE_DIR_NAME = "audio";
    private static final String INDEX_FILE = "cache_index.json";

    private static AudioCacheManager instance;

    private final File cacheDir;
    private long maxSizeBytes = 500L * 1024 * 1024; // default 500MB
    private final Context context;

    private final Map<String, CacheEntry> index = new HashMap<>();
    private final Map<String, Future<?>> activeDownloads = new ConcurrentHashMap<>();
    private final ExecutorService downloadExecutor = Executors.newFixedThreadPool(2);
    private final ExecutorService preloadExecutor = Executors.newFixedThreadPool(1);

    public interface DownloadProgressCallback {
        void onProgress(String cacheKey, float percent);
        void onComplete(String cacheKey);
    }

    static class CacheEntry {
        String cacheKey;
        String fileName;
        long fileSize;
        long lastAccessTime;
        boolean complete;
    }

    public static synchronized AudioCacheManager getInstance() {
        if (instance == null) {
            throw new IllegalStateException("AudioCacheManager not initialized. Call initialize(context) first.");
        }
        return instance;
    }

    public static synchronized void initialize(Context ctx) {
        if (instance != null) return;
        instance = new AudioCacheManager(ctx);
    }

    private AudioCacheManager(Context ctx) {
        this.context = ctx.getApplicationContext();
        File baseCacheDir = new File(this.context.getCacheDir(), "EcellsMusic_cache");
        this.cacheDir = new File(baseCacheDir, CACHE_DIR_NAME);
        if (!this.cacheDir.exists()) {
            this.cacheDir.mkdirs();
        }
        loadIndex();
        cleanupIncomplete();
        Log.i(TAG, "AudioCacheManager initialized, cache dir: " + cacheDir.getAbsolutePath());
    }

    public String buildCacheKey(String hash, String quality) {
        if (hash == null || hash.isEmpty()) return null;
        String q = (quality != null && !quality.isEmpty()) ? quality : "default";
        return hash + "_" + q;
    }

    public synchronized boolean isCached(String cacheKey) {
        if (cacheKey == null) return false;
        CacheEntry entry = index.get(cacheKey);
        if (entry == null || !entry.complete) return false;
        File file = new File(cacheDir, entry.fileName);
        return file.exists() && file.length() > 0;
    }

    public synchronized File getCachedFile(String cacheKey) {
        if (cacheKey == null) return null;
        CacheEntry entry = index.get(cacheKey);
        if (entry == null || !entry.complete) return null;
        File file = new File(cacheDir, entry.fileName);
        if (!file.exists() || file.length() == 0) return null;
        entry.lastAccessTime = System.currentTimeMillis();
        saveIndex();
        return file;
    }

    public synchronized void markAccessed(String cacheKey) {
        CacheEntry entry = index.get(cacheKey);
        if (entry != null) {
            entry.lastAccessTime = System.currentTimeMillis();
            saveIndex();
        }
    }

    public void startDownload(String cacheKey, String url) {
        startDownload(cacheKey, url, null);
    }

    public void startDownload(String cacheKey, String url, DownloadProgressCallback callback) {
        if (cacheKey == null || url == null || url.isEmpty()) return;
        synchronized (this) {
            CacheEntry existing = index.get(cacheKey);
            if (existing != null && existing.complete) {
                if (callback != null) callback.onComplete(cacheKey);
                return;
            }
            if (activeDownloads.containsKey(cacheKey)) return;
        }

        Future<?> future = downloadExecutor.submit(() -> {
            try {
                downloadToFile(cacheKey, url, callback);
            } catch (Exception e) {
                Log.e(TAG, "Download failed for " + cacheKey, e);
            } finally {
                activeDownloads.remove(cacheKey);
            }
        });
        activeDownloads.put(cacheKey, future);
    }

    /**
     * Pre-load a song into cache on a low-priority thread.
     * Used to pre-cache the next song in the playlist.
     */
    public void preloadCache(String cacheKey, String url) {
        if (cacheKey == null || url == null || url.isEmpty()) return;
        synchronized (this) {
            CacheEntry existing = index.get(cacheKey);
            if (existing != null && existing.complete) return;
            if (activeDownloads.containsKey(cacheKey)) return;
        }
        preloadExecutor.submit(() -> {
            try {
                downloadToFile(cacheKey, url, null);
                Log.i(TAG, "Preload complete: " + cacheKey);
            } catch (Exception e) {
                Log.d(TAG, "Preload skipped: " + cacheKey + " - " + e.getMessage());
            }
        });
    }

    private void downloadToFile(String cacheKey, String urlStr, DownloadProgressCallback callback) throws Exception {
        String fileName = cacheKey + ".audio";
        File tempFile = new File(cacheDir, fileName + ".tmp");
        File finalFile = new File(cacheDir, fileName);

        Log.i(TAG, "Starting download: " + cacheKey + " from " + urlStr);

        HttpURLConnection conn = null;
        InputStream is = null;
        FileOutputStream fos = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(30000);
            conn.setRequestProperty("User-Agent", "EcellsMusic/1.0");
            conn.connect();

            int responseCode = conn.getResponseCode();
            if (responseCode != HttpURLConnection.HTTP_OK && responseCode != HttpURLConnection.HTTP_PARTIAL) {
                throw new Exception("HTTP " + responseCode);
            }

            is = conn.getInputStream();
            fos = new FileOutputStream(tempFile);

            long contentLength = conn.getContentLengthLong();
            byte[] buffer = new byte[8192];
            int bytesRead;
            long totalBytes = 0;
            long lastReportBytes = 0;
            float lastReportPercent = 0;
            while ((bytesRead = is.read(buffer)) != -1) {
                fos.write(buffer, 0, bytesRead);
                totalBytes += bytesRead;
                if (callback != null && contentLength > 0 && totalBytes - lastReportBytes >= 131072) {
                    float percent = (float) totalBytes / contentLength;
                    if (percent - lastReportPercent >= 0.05f) {
                        lastReportPercent = percent;
                        lastReportBytes = totalBytes;
                        float finalPercent = percent;
                        callback.onProgress(cacheKey, finalPercent);
                    }
                }
            }
            fos.flush();
            fos.close();
            fos = null;

            if (!tempFile.renameTo(finalFile)) {
                tempFile.delete();
                throw new Exception("Failed to rename temp file");
            }

            synchronized (this) {
                CacheEntry entry = index.get(cacheKey);
                if (entry == null) {
                    entry = new CacheEntry();
                    entry.cacheKey = cacheKey;
                }
                entry.fileName = fileName;
                entry.fileSize = finalFile.length();
                entry.lastAccessTime = System.currentTimeMillis();
                entry.complete = true;
                index.put(cacheKey, entry);
                saveIndex();
                evictIfNeeded();
            }

            Log.i(TAG, "Download complete: " + cacheKey + " size=" + totalBytes);
            if (callback != null) callback.onComplete(cacheKey);
        } finally {
            if (is != null) try { is.close(); } catch (Exception ignored) {}
            if (fos != null) try { fos.close(); } catch (Exception ignored) {}
            if (conn != null) conn.disconnect();
            if (tempFile.exists()) tempFile.delete();
        }
    }

    public synchronized void evictIfNeeded() {
        long totalSize = calculateTotalSize();
        if (totalSize <= maxSizeBytes) return;

        Log.i(TAG, "Cache over limit: " + (totalSize / 1024 / 1024) + "MB / " + (maxSizeBytes / 1024 / 1024) + "MB, evicting...");

        List<CacheEntry> sorted = new ArrayList<>(index.values());
        Collections.sort(sorted, Comparator.comparingLong(e -> e.lastAccessTime));

        for (CacheEntry entry : sorted) {
            if (totalSize <= maxSizeBytes * 0.8) break; // evict to 80% of limit
            if (activeDownloads.containsKey(entry.cacheKey)) continue;

            File file = new File(cacheDir, entry.fileName);
            if (file.exists()) {
                totalSize -= file.length();
                file.delete();
                Log.i(TAG, "Evicted: " + entry.cacheKey);
            }
            index.remove(entry.cacheKey);
        }
        saveIndex();
    }

    private long calculateTotalSize() {
        long total = 0;
        for (CacheEntry entry : index.values()) {
            File file = new File(cacheDir, entry.fileName);
            if (file.exists()) {
                total += file.length();
            }
        }
        return total;
    }

    public synchronized long getCacheSize() {
        return calculateTotalSize();
    }

    public synchronized int getCacheFileCount() {
        return (int) index.values().stream().filter(e -> e.complete).count();
    }

    public synchronized long getMaxSizeBytes() {
        return maxSizeBytes;
    }

    public synchronized void clearCache() {
        for (Future<?> f : activeDownloads.values()) {
            f.cancel(true);
        }
        activeDownloads.clear();

        for (CacheEntry entry : index.values()) {
            File file = new File(cacheDir, entry.fileName);
            if (file.exists()) file.delete();
            File tmp = new File(cacheDir, entry.fileName + ".tmp");
            if (tmp.exists()) tmp.delete();
        }
        index.clear();
        saveIndex();
        Log.i(TAG, "Cache cleared");
    }

    public synchronized void deleteCacheEntry(String cacheKey) {
        CacheEntry entry = index.remove(cacheKey);
        if (entry != null) {
            new File(cacheDir, entry.fileName).delete();
            new File(cacheDir, entry.fileName + ".tmp").delete();
        }
    }

    public synchronized void setMaxSize(long mb) {
        this.maxSizeBytes = Math.max(100, mb) * 1024L * 1024L;
        evictIfNeeded();
        Log.i(TAG, "Max cache size set to " + mb + "MB");
    }

    private void cleanupIncomplete() {
        Iterator<Map.Entry<String, CacheEntry>> it = index.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, CacheEntry> mapEntry = it.next();
            CacheEntry entry = mapEntry.getValue();
            if (!entry.complete) {
                new File(cacheDir, entry.fileName).delete();
                new File(cacheDir, entry.fileName + ".tmp").delete();
                it.remove();
            } else {
                File file = new File(cacheDir, entry.fileName);
                if (!file.exists()) {
                    it.remove();
                } else {
                    entry.fileSize = file.length();
                }
            }
        }
        saveIndex();
    }

    private void loadIndex() {
        File indexFile = new File(cacheDir, INDEX_FILE);
        if (!indexFile.exists()) return;

        try (BufferedReader reader = new BufferedReader(new FileReader(indexFile))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line);
            }
            JSONObject root = new JSONObject(sb.toString());
            JSONArray entries = root.optJSONArray("entries");
            if (entries == null) return;

            for (int i = 0; i < entries.length(); i++) {
                JSONObject obj = entries.getJSONObject(i);
                CacheEntry entry = new CacheEntry();
                entry.cacheKey = obj.getString("key");
                entry.fileName = obj.optString("file", entry.cacheKey + ".audio");
                entry.fileSize = obj.optLong("size", 0);
                entry.lastAccessTime = obj.optLong("lastAccess", 0);
                entry.complete = obj.optBoolean("complete", false);
                index.put(entry.cacheKey, entry);
            }
            Log.i(TAG, "Loaded " + index.size() + " cache entries");
        } catch (Exception e) {
            Log.e(TAG, "Failed to load cache index", e);
            index.clear();
        }
    }

    private void saveIndex() {
        File indexFile = new File(cacheDir, INDEX_FILE);
        try (FileWriter writer = new FileWriter(indexFile)) {
            JSONObject root = new JSONObject();
            JSONArray entries = new JSONArray();
            for (CacheEntry entry : index.values()) {
                JSONObject obj = new JSONObject();
                obj.put("key", entry.cacheKey);
                obj.put("file", entry.fileName);
                obj.put("size", entry.fileSize);
                obj.put("lastAccess", entry.lastAccessTime);
                obj.put("complete", entry.complete);
                entries.put(obj);
            }
            root.put("entries", entries);
            writer.write(root.toString());
        } catch (Exception e) {
            Log.e(TAG, "Failed to save cache index", e);
        }
    }
}
