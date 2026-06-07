package com.muye.ecells.music;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.TextureView;

/**
 * 自定义 TextureView，不拦截任何触摸事件。
 * 所有触摸事件穿透到下层的 GeckoView，由 Web 层的 HTML/CSS 控制栏处理。
 * 仅用于渲染原生视频帧。
 */
public class PassThroughTextureView extends TextureView {

    public PassThroughTextureView(Context context) {
        super(context);
    }

    public PassThroughTextureView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public PassThroughTextureView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        // 不消费触摸事件，让事件穿透到下层的 GeckoView
        return false;
    }
}
