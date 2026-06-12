package com.muye.ecells.music;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.HashMap;
import java.util.zip.GZIPOutputStream;

import fi.iki.elonen.NanoHTTPD;

public class AssetServer extends NanoHTTPD {

    private static final String TAG = "AssetServer";
    private static final String ASSET_PREFIX = "public/";
    private static final int PORT = 18387;
    private static final int GZIP_THRESHOLD = 256; // 最小压缩阈值（字节）

    private final AssetManager assetManager;
    private byte[] cachedIndexHtml;
    private byte[] cachedIndexHtmlGzip;

    private static final Map<String, String> MIME_TYPES = new HashMap<>();
    static {
        MIME_TYPES.put("html", "text/html");
        MIME_TYPES.put("js", "application/javascript");
        MIME_TYPES.put("mjs", "application/javascript");
        MIME_TYPES.put("css", "text/css");
        MIME_TYPES.put("json", "application/json");
        MIME_TYPES.put("png", "image/png");
        MIME_TYPES.put("jpg", "image/jpeg");
        MIME_TYPES.put("jpeg", "image/jpeg");
        MIME_TYPES.put("gif", "image/gif");
        MIME_TYPES.put("svg", "image/svg+xml");
        MIME_TYPES.put("ico", "image/x-icon");
        MIME_TYPES.put("woff", "font/woff");
        MIME_TYPES.put("woff2", "font/woff2");
        MIME_TYPES.put("ttf", "font/ttf");
        MIME_TYPES.put("webp", "image/webp");
        MIME_TYPES.put("webm", "video/webm");
        MIME_TYPES.put("mp3", "audio/mpeg");
        MIME_TYPES.put("mp4", "video/mp4");
        MIME_TYPES.put("wasm", "application/wasm");
        MIME_TYPES.put("map", "application/json");
    }

    public AssetServer(Context context) {
        super(PORT);
        this.assetManager = context.getAssets();
    }

    public String getBaseUrl() {
        return "http://localhost:" + PORT + "/";
    }

    public void startServer() throws IOException {
        start(NanoHTTPD.SOCKET_READ_TIMEOUT, false);
        Log.i(TAG, "Asset server started at " + getBaseUrl());
    }

    @Override
    public Response serve(IHTTPSession session) {
        String uri = session.getUri();
        if (uri.startsWith("/")) {
            uri = uri.substring(1);
        }
        if (uri.isEmpty()) {
            uri = "index.html";
        }

        String assetPath = ASSET_PREFIX + uri;

        try {
            byte[] bytes;
            boolean isHtml = uri.equals("index.html");

            if (isHtml && cachedIndexHtml != null) {
                bytes = cachedIndexHtml;
            } else {
                InputStream is = assetManager.open(assetPath);
                bytes = readAll(is);
                is.close();

                if (isHtml) {
                    bytes = injectGeckoViewInit(bytes);
                    cachedIndexHtml = bytes;
                    // 预生成 GZIP 版本的 index.html
                    cachedIndexHtmlGzip = gzipBytes(bytes);
                }
            }

            String ext = getExtension(uri);
            String mime = MIME_TYPES.getOrDefault(ext, "application/octet-stream");

            // 检测客户端是否支持 GZIP
            boolean acceptGzip = false;
            String acceptEncoding = session.getHeaders().get("accept-encoding");
            if (acceptEncoding != null && acceptEncoding.contains("gzip")) {
                acceptGzip = true;
            }

            // 对可压缩内容进行 GZIP 压缩
            if (acceptGzip && isCompressible(mime) && bytes.length > GZIP_THRESHOLD) {
                byte[] gzipBytes;
                // index.html 使用预缓存的 GZIP 版本
                if (isHtml && cachedIndexHtmlGzip != null) {
                    gzipBytes = cachedIndexHtmlGzip;
                } else {
                    gzipBytes = gzipBytes(bytes);
                }

                if (gzipBytes != null && gzipBytes.length < bytes.length) {
                    Response response = newFixedLengthResponse(Response.Status.OK, mime,
                        new ByteArrayInputStream(gzipBytes), gzipBytes.length);
                    response.addHeader("Content-Encoding", "gzip");
                    response.addHeader("Vary", "Accept-Encoding");
                    addCacheHeaders(response, uri, isHtml);
                    Log.d(TAG, "GZIP: " + uri + " " + bytes.length + " -> " + gzipBytes.length + " bytes");
                    return response;
                }
            }

            // 未压缩的响应路径
            Response response = newFixedLengthResponse(Response.Status.OK, mime, new ByteArrayInputStream(bytes), bytes.length);
            addCacheHeaders(response, uri, isHtml);
            return response;

        } catch (IOException e) {
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not found: " + uri);
        }
    }

    /**
     * 添加缓存头。
     * - index.html: no-cache（每次都需要最新版本）
     * - 带 Hash 的静态资源: public, max-age=31536000, immutable（1年强缓存，文件名即版本）
     * - 其他资源: public, max-age=604800（7天缓存）
     */
    private void addCacheHeaders(Response response, String uri, boolean isHtml) {
        if (isHtml) {
            response.addHeader("Cache-Control", "no-cache");
            return;
        }
        if (isHashedAsset(uri)) {
            response.addHeader("Cache-Control", "public, max-age=31536000, immutable");
        } else {
            response.addHeader("Cache-Control", "public, max-age=604800");
        }
    }

    /**
     * 判断 URI 是否指向带 Hash 的不可变静态资源。
     * Vite 构建的文件名格式：name-[hash].ext，其中 hash 为 7-12 位字母数字字符。
     * 示例：vendor-vue-DxvQVFli.js, Home-lzgzOaUb.js, AlbumDetail-ByQCX-wa.css
     */
    private boolean isHashedAsset(String uri) {
        int lastSlash = uri.lastIndexOf('/');
        String fileName = lastSlash >= 0 ? uri.substring(lastSlash + 1) : uri;
        int lastDot = fileName.lastIndexOf('.');
        if (lastDot <= 0) return false;
        String baseName = fileName.substring(0, lastDot);
        int lastDash = baseName.lastIndexOf('-');
        if (lastDash <= 0 || lastDash >= baseName.length() - 6) return false;
        String hashPart = baseName.substring(lastDash + 1);
        // Hash 应为 7-16 位字母数字或下划线
        if (hashPart.length() < 7 || hashPart.length() > 16) return false;
        for (int i = 0; i < hashPart.length(); i++) {
            char c = hashPart.charAt(i);
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-')) {
                return false;
            }
        }
        return true;
    }

    /**
     * 判断 MIME 类型是否适合 GZIP 压缩。
     * 排除已压缩的二进制格式（图片、视频、字体、音频）。
     */
    private boolean isCompressible(String mime) {
        return mime.startsWith("text/")
            || mime.equals("application/javascript")
            || mime.equals("application/json")
            || mime.equals("application/wasm")
            || mime.equals("image/svg+xml");
    }

    /**
     * 对字节数组进行 GZIP 压缩
     */
    private byte[] gzipBytes(byte[] data) {
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream(data.length);
            GZIPOutputStream gzipOut = new GZIPOutputStream(baos);
            gzipOut.write(data);
            gzipOut.close();
            return baos.toByteArray();
        } catch (IOException e) {
            Log.w(TAG, "GZIP compression failed", e);
            return null;
        }
    }

    private byte[] injectGeckoViewInit(byte[] htmlBytes) {
        String html = new String(htmlBytes, java.nio.charset.StandardCharsets.UTF_8);
        String injection = "<script>window.__GECKOVIEW__=true;window.NativeBridge={_callbacks:{},_listeners:{}};</script>";
        int scriptPos = html.indexOf("<script");
        if (scriptPos >= 0) {
            html = html.substring(0, scriptPos) + injection + html.substring(scriptPos);
        } else {
            int headEnd = html.indexOf("</head>");
            if (headEnd >= 0) {
                html = html.substring(0, headEnd) + injection + html.substring(headEnd);
            }
        }
        return html.getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    private String getExtension(String path) {
        int dot = path.lastIndexOf('.');
        if (dot >= 0 && dot < path.length() - 1) {
            return path.substring(dot + 1).toLowerCase();
        }
        return "";
    }

    private byte[] readAll(InputStream is) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int read;
        while ((read = is.read(buffer)) != -1) {
            baos.write(buffer, 0, read);
        }
        return baos.toByteArray();
    }
}
