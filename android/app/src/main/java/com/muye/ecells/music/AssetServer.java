package com.muye.ecells.music;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.HashMap;

import fi.iki.elonen.NanoHTTPD;

public class AssetServer extends NanoHTTPD {

    private static final String TAG = "AssetServer";
    private static final String ASSET_PREFIX = "public/";
    private static final int PORT = 18387;

    private final AssetManager assetManager;

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
            InputStream is = assetManager.open(assetPath);
            byte[] bytes = readAll(is);
            is.close();

            if (uri.equals("index.html") || uri.isEmpty()) {
                bytes = injectGeckoViewInit(bytes);
            }

            String ext = getExtension(uri);
            String mime = MIME_TYPES.getOrDefault(ext, "application/octet-stream");

            return newFixedLengthResponse(Response.Status.OK, mime, new ByteArrayInputStream(bytes), bytes.length);

        } catch (IOException e) {
            // Not found
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not found: " + uri);
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
        byte[] buffer = new byte[8192];
        int total = 0;
        byte[] result = new byte[0];
        int read;
        while ((read = is.read(buffer)) != -1) {
            byte[] newResult = new byte[total + read];
            System.arraycopy(result, 0, newResult, 0, total);
            System.arraycopy(buffer, 0, newResult, total, read);
            result = newResult;
            total += read;
        }
        return result;
    }
}
