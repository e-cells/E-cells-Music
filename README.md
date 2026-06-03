# 易格音乐 (E-cells-Music) ── 高颜值的酷狗概念版第三方安卓音乐播放器

## 📖 项目简介
本项目是基于开源项目 **[EchoMusic](https://github.com/hoowhoami/EchoMusic)** 的前端代码，经过跨平台二次开发、原生层重构并打包打造而成的 Android 客户端。

应用基于 **Vue 3 + Vite + TailwindCSS** 前端，结合 **GeckoView** (Mozilla Firefox 引擎) 作为 WebView，通过窗口 `prompt` 桥接实现 JavaScript ↔ Java 原生通信。其横屏界面专为安卓车机和平板等大屏设备设计，若在普通安卓手机上使用，只需在设置里切换成竖屏模式即可完美适配！

---

## ✨ 深度定制了哪些好玩的功能？

这不仅仅是一个“套壳”的网页版应用，为了让它在**复杂的驾驶环境**和**大屏硬件**上更好用，我们做了一次彻头彻尾的车机级重构：

### 1. 🎵 视觉与歌词体验拉满
- **横竖屏自适应**：横屏保留了经典排版，特制高适配度竖屏模式，手机端完美驾驭；
- **桌面歌词随心调**：开关自由，自定义字体大小、位置和宽度。支持**针对浅色和深色主题分别设置不同的歌词颜色**；
- **沉浸式动态特效**：当前播放行高亮放大，支持**卡拉 OK 般的逐字渐变填充**，配合上下行的半透明羽化效果。
- **自动适配环境光的主题与歌词**：新增“跟随光感器”选项，让APP主题与桌面歌词能随车机环境光线强弱自动切换深浅色。在导航场景下，此功能可智慧联动，确保副驾随时看清歌词，体验如高德地图般顺畅。

### 2. 🚘 极致的车载安全驾驶优化（盲操与语音）
- **全通用车机语音控制**：深度重构 Android 原生 `MediaSession` 会话层。支持车机语音助手（目前仅测试比亚迪，需配合“音乐助手”APP）：
  - **切歌**：播放下一首 / 播放上一首 等口语化表达；
  - **搜索**：”搜索林俊杰的歌” / “播放周杰伦的晴天” 等自然语言搜索。
- **物理方向盘按键完美映射**：原生级拦截 `KeyEvent` 媒体广播，完美适配绝大多数车机方向盘上的**上一曲、下一曲**物理按键；
- **断点续播**：应用在后台被杀死或重启车机后，再次打开自动恢复上次的播放进度和队列；
- **智能混音降音 (Audio Ducking)**：高德/百度地图等导航语音播报时，自动调低音乐音量或暂停，播报完毕自动恢复。

### 3. 🛡️ 车机守护：极致的内存与性能稳定性 (防 OOM)
- **高清封面内存守护机制**：通过网络流双流解析与 `inSampleSize` 采样率技术，强行将巨型封面图等比压缩至车机通知栏最佳尺寸。
- **RGB_565 硬件降维解码**：在完全不输肉眼画质的前提下，将专辑封面内存占用**直接砍掉 50% 以上**，彻底告别车机后台闪退（OOM）。

---

## 🚀 核心指南 —— 用户篇

### 📦 下载通道

> **注：** 本应用为纯前端构建版，不内置、不存储任何音频资源。

**🔗 下载链接**
* **GitHub**：[Releases 下载](https://github.com/e-cells/EchoMusic-for-Android/releases)
* **天翼云盘**：[点我下载,访问码：7km9](https://cloud.189.cn/web/share?code=qYV7NjjeYj6b)
---

**📱 架构版本选择指南**
根据您的设备类型，请下载对应的架构版本：

* **`arm64-v8a`（推荐）**：现代主流手机 / 绝大多数现代安卓车机
* **`armeabi-v7a`（兼容）**：老旧 32 位设备 / 极个别老款车机
* **`x86 / x86_64`（适配）**：PC 安卓模拟器 / 极客折腾环境

### 🛠️ 后端服务支持（必看）
运行本应用必须配合**自建**后端接口服务：
- **后端项目地址**：[MakcRe/KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)
- ⚠️ **安全警告**：本项目不提供公共后端 API，请勿随意使用他人提供的公共服务，以免造成账号信息泄露！
### 🛠️ 后端服务支持（必看）
运行本应用必须配合**自建**后端接口服务：
- **后端项目地址**：[MakcRe/KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)
⚠️ **安全警告**：本项目不提供公共后端 API，请勿随意使用他人提供的公共服务，以免造成账号信息泄露！

**部署提示：**
1. **IP 限制**：后端服务**不能使用 Vercel 或国外服务器**，出口 IP 必须是**中国大陆境内**，否则会导致登录失败或数据无法加载。
2. **部署建议**：强烈建议使用 **Docker** 快速部署。
3. **环境变量**：Docker 容器构建时需添加环境变量 `key = platform`, `Value = lite`。
4. **网页页面示范**：部署成功后，访问后端服务应显示如下页面：
   ![KuGouMusicApi 部署成功页面示范](https://github.com/user-attachments/assets/97909a7f-0d60-4957-a89e-b93b0b9e040e)
   
#### 🐳 极速部署教程 (Docker)

你可以根据实际情况，选择使用 Docker CLI 或 Docker Compose 来启动服务，启动后，API 服务将运行在宿主机的 `8542` 端口。

### 方式一：使用 Docker CLI 极速运行
使用以下命令一键启动。此命令默认启用了 （酷狗概念版数据源，兼容性更好），并将容器内的 3000 端口映射到宿主机的 3000 端口：

```bash
docker run -d \
  --name kugou-api \
  --restart unless-stopped \
  -e platform=lite \
  -p 8542:3000 \
  hly307765464/kugou-music-api:latest
```


### 方式二：使用 Docker Compose 部署 (推荐)

如果你需要更方便地管理容器，推荐使用 Compose 部署。请在服务器上新建一个 docker-compose.yml 文件，填入以下内容：
```bash
version: '3.8'
services:
  kugou-api:
    image: hly307765464/kugou-music-api:latest  # 直接拉取 Docker Hub 上的最新镜像
    container_name: kugou-music-api
    restart: unless-stopped
    environment:
      - platform=lite  # 启用酷狗概念版接口
    ports:
      - "8542:3000"    # 将宿主机的 8542 端口映射到容器内部的 3000 端口
```

### ⚙️ 初始化与登录
1. **配置接口**：首次启动会进入古风 Q 版初始化界面，填入你部署好的后端网址（如：`http://192.168.x.x:端口` 或 `http://你的域名`），点击“确认并继续”。
2. **登录建议**（用于同步歌单）：
   - **微信登录**（强烈推荐，最稳定）
   - 扫码登录 / 短信验证码登录（后端请求过多时可能提示失败）

---

## 💻 构建说明 —— 开发者篇

### 环境要求
| 工具 | 版本要求 | 说明 |
|------|---------|------|
| [Android Studio](https://developer.android.com/studio) | 最新稳定版 | IDE，自带 SDK Manager 和模拟器 |
| Android SDK | **API 36** | 在 Android Studio 中通过 SDK Manager 安装 |
| JDK | **17+** | Android Studio 自带或单独安装 |
| [Node.js](https://nodejs.org/) | **18+** | 前端构建 |

### 1. 克隆与安装依赖
```bash
git clone [https://github.com/e-cells/E-cells-Music.git](https://github.com/e-cells/E-cells-Music.git)
cd E-cells-Music
npm install --legacy-peer-deps
```

### 2. 配置 Android SDK 路径
用 Android Studio 打开 `android/` 目录会自动生成 `local.properties` 文件。如果没有，请手动创建并指定 SDK 路径：
```properties
# Windows 示例
sdk.dir=C\:\\Users\\您的电脑用户名\\AppData\\Local\\Android\\Sdk
```

### 3. 构建 Web 前端并复制到 Android
```bash
npm run build:android
```

### 4. 运行 / 调试
在 Android Studio 中：连接手机（开启 USB 调试）或启动模拟器，点击绿色 ▶ 按钮运行。

### 5. 打包 APK
- **Debug 包**: `cd android && ./gradlew assembleDebug`
- **Release 包**:
  1. 首次需生成签名：`keytool -genkey -v -keystore ecells-music-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias ecellsmusic`
  2. 在 `android/local.properties` 中追加签名信息：
     ```properties
     storePassword=你的密钥库密码
     keyAlias=ecellsmusic
     keyPassword=你的密钥密码
     ```
  3. 执行构建：`./gradlew assembleRelease`

### 核心技术栈
| 层级 | 技术 |
|------|------|
| 前端框架 | Vue 3.5 + Composition API + Pinia + Vue Router 4 |
| 样式与 UI | TailwindCSS v4 + reka-ui (Radix Vue) |
| 构建工具 | Vite 6 |
| 音频播放 | Android MediaPlayer (原生) |
| WebView | Mozilla GeckoView 128 |

---
## ❓ 常见问题 (FAQ)

**Q：Gradle sync 失败怎么办？**

**A：** 检查 `android/local.properties` 中的 `sdk.dir` 路径是否配置正确；并确认已在 SDK Manager 中安装了 **Android SDK Platform 36** 和 **Build-Tools 36**。

---

**Q：构建时提示 `proguard-android.txt` 错误？**

**A：** 请打开 `android/app/build.gradle` 文件，将其中的 `proguard-android.txt` 修改为 `proguard-android-optimize.txt`。

---

**Q：Web 前端修改后如何更新 APP？**

**A：** 重新运行命令 `npm run build:android`，然后回到 Android Studio 中重新构建（Build） APK。

---

**Q：如何修改远端 API 地址？**

**A：** 首次启动时可以在初始化页面直接输入；后续如果需要更改，可前往 `设置` → `远端服务` 中进行修改。

---

**Q：桌面歌词不显示？**

**A：** 请确保已在手机的系统设置中授予本应用 **悬浮窗权限**，并在 APP 内部的设置中开启了“桌面歌词”开关。

---

**Q：如何修改应用名称 / 包名？**

**A：** * **修改应用名称：** 请编辑 `android/app/src/main/res/values/strings.xml` 文件。
 **修改应用包名：** 请编辑 `android/app/build.gradle` 文件中的 `applicationId` 字段。

---

## 📷 界面预览

### 📺 横屏模式/车机预览
| 歌单列表 | 歌曲列表 |
| :---: | :---: |
| <img src="https://github.com/user-attachments/assets/c0876bd8-5385-4da1-ba8d-b6d604d93319" alt="横屏-歌单列表" width="100%" /> | <img src="https://github.com/user-attachments/assets/207473b6-d23b-4d25-9c52-a2464c4c8b89" alt="横屏-歌曲列表" width="100%" /> |
| **播放页面** | **设置页面** |
| <img src="https://github.com/user-attachments/assets/98841712-4a3d-456a-9c7e-bebe3c5e5e8a" alt="横屏-播放页面" width="100%" /> | <img src="https://github.com/user-attachments/assets/511d6f19-7d30-46ef-8286-23b1c4c3d9a7" alt="横屏-设置页面" width="100%" /> |

### 📱 竖屏模式预览
| 首页 | 歌单详情 | 歌手列表 |
| :---: | :---: | :---: |
| <img src="https://github.com/user-attachments/assets/0e6fc51d-86df-4c94-8189-da30d6e8e072" alt="竖屏-首页" width="100%" /> | <img src="https://github.com/user-attachments/assets/d058d7f4-2fd3-4b06-b733-1207f7cfb00b" alt="竖屏-歌单详情" width="100%" /> | <img src="https://github.com/user-attachments/assets/c5f25044-93c7-44c7-bb6d-935f68c04937" alt="竖屏-歌手列表" width="100%" /> |
| **我的** | **新碟上架** | **播放** |
| <img src="https://github.com/user-attachments/assets/e7d3be9e-e94d-45c0-a378-8bc2f226e4d5" alt="竖屏-我的" width="100%" /> | <img src="https://github.com/user-attachments/assets/84c533bd-6336-440b-952c-5b2bf0958d52" alt="竖屏-新碟上架" width="100%" /> | <img src="https://github.com/user-attachments/assets/c038f73e-890b-43e3-8aae-7daf1cd492c3" alt="竖屏-播放" width="100%" /> |

### 🎥 视频演示
[👉 点击此处跳转到B站观看功能演示视频](https://www.bilibili.com/video/BV1sjLx6pEWr/?share_source=copy_web&vd_source=30d986d27c61438dcf8b77bfa752fa62)

---

## ⚖️ 法律与申明

### 开发初衷与赞赏合作
本项目主要为解决车载前台高德导航、后台听歌，及副驾驶看桌面歌词的真实痛点，提供更纯净安全的行车娱乐体验。（如用于车机听歌，请务必注意驾驶安全！）
- 本项目为纯粹的兴趣驱动产物，**不接收任何形式的赞赏，亦不接受任何商务合作**。
- 如果您觉得本项目对您有帮助，请在 GitHub 上点亮一颗 **Star ⭐️**，这是对开发者最大的鼓励！

### 开源协议 (License)
本项目采用 **[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)** 协议。

### ⚠️ 免责声明
1. 本项目开源代码及打包后的 APK 文件仅供个人学习、研究及车机自用，任何人均可随意免费下载使用。
2. 任何个人或组织**不得将本项目及其任何构建产物用于任何形式的商业盈利目的**。
3. 若违反上述规定将其用于商业牟利或产生其他侵权行为，由此造成的一切法律后果、版权纠纷及损失由使用者自行承担，开发者不承担任何连带及法律责任。
4. 音乐平台不易，请尊重版权，支持正版。
5. 如版权方认为本项目侵犯其权益，请通过 Issues 联系，我们将积极配合处理。

**下载并安装本应用即视为你已阅读、理解并完全同意本免责声明。**