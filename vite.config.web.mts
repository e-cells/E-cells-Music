import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'path';

export default defineConfig({
  base: './',
  build: {
    target: 'es2015',
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
      },
      output: {
        // 细粒度手动分包：将启动时不需要的大型依赖拆分为独立 chunk
        // 减小主 chunk 体积，加速 JS 解析和首屏加载
        manualChunks(id) {
          if (!id.includes('node_modules')) return;

          // 核心框架 — 首屏必需
          if (
            id.includes('node_modules/vue/') ||
            id.includes('node_modules/@vue/') ||
            id.includes('node_modules/vue-router/') ||
            id.includes('node_modules/pinia/') ||
            id.includes('node_modules/pinia-plugin-persistedstate/')
          ) {
            return 'vendor-vue';
          }

          // Reka UI 组件库 — 被多个页面使用，但首屏不需要
          if (id.includes('node_modules/reka-ui/')) {
            return 'vendor-reka-ui';
          }

          // Iconify 图标 — 按需加载，体积分离
          if (id.includes('node_modules/@iconify/')) {
            return 'vendor-iconify';
          }

          // Howler 音频库 — 仅播放时需要
          if (id.includes('node_modules/howler/')) {
            return 'vendor-howler';
          }

          // VueUse 工具库 — 被多个组件使用但体积可控
          if (id.includes('node_modules/@vueuse/')) {
            return 'vendor-vueuse';
          }

          // SortableJS — 仅播放列表面板使用
          if (id.includes('node_modules/sortablejs/')) {
            return 'vendor-sortable';
          }

          // CryptoJS — 仅 API 请求时需要
          if (id.includes('node_modules/crypto-js/')) {
            return 'vendor-crypto';
          }

          // Marked — 仅 Markdown 渲染时需要
          if (id.includes('node_modules/marked/')) {
            return 'vendor-marked';
          }

          // Axios — HTTP 请求库
          if (id.includes('node_modules/axios/')) {
            return 'vendor-axios';
          }
        },
      },
    },
  },
  plugins: [vue(), tailwindcss()],
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src/renderer'),
    },
    extensions: ['.ts', '.tsx', '.mts', '.js', '.jsx', '.mjs', '.json', '.vue'],
  },
  server: {
    port: 5173,
  },
});
