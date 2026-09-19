<div align="center">
  <img src="logo.png" width="120" height="120" alt="XianYu Logo" style="border-radius: 24px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

# 弦予音乐 · 腕上端
## (XianYu-Music-Watch)

弦予音乐的腕上端（Wear OS / 鸿蒙手表）：联动手机时是**外置控制器**——抬腕控歌、表冠调音量、逐字歌词同步；独立时是**完整播放器**，本地曲库随处可听。软件不内置音乐内容，插件由用户自行安装。

 [](https://flutter.dev/)
 [](https://www.rust-lang.org/)
 [](https://dart.dev/)

</div>

## ✨ 功能亮点

- ⌚ **双形态一体**

  - **联动模式**：蓝牙 RFCOMM 远程控制手机播放——播放/暂停、上下曲、进度 seek、喜欢、播放模式、表冠调音量；手机开播自动经通知拉起手表 App（IMPORTANCE_HIGH + fullScreenIntent，规避 Wear OS 3 后台启动限制）。
  - **独立模式**：断连状态下完整本地播放（Rust 并行扫描 / 标签解析 / 封面提取）+ 插件音源扩展，与手机互不干扰；两模式底部一键切换、可共存。

- 🔗 **自研腕上链路协议**

  - **XYW1 二进制帧**：`magic + ver + type + seq + len + CRC16` 帧格式，payload 4KB 上限自动分片重组，CRC 损坏帧丢弃、粘包/半包容错。
  - **可靠连接**：配对地址持久化自动连接、3s 心跳、10s 无帧判死、1→30s 指数退避重连、本地 1s 进度插值。
  - **云端兜底**：蓝牙不可达时自动切换服务器 WebSocket 中继（XYW1 帧原样转发），密钥仅经蓝牙安全信道下发。

- 🎵 **网易云手表式播放 UI**

  - **圆屏三页横移**：选择页（彩色圆图入口）↔ 播放页 ↔ 歌词页，左右滑动切换 + 底部圆点指示，联动控制页同款两页形态。
  - **圆屏交互**：环形进度拖拽 seek、长按 ±10s 连续跳、表冠旋转调音量（本地 HUD + 250ms 节流下发）。
  - **歌词双通道**：本地/插件播放开箱即得（Rust API 读 LRC / 插件歌词）；联动模式由手机推送归一化歌词（协议 type 0x13），当前行高亮 + 自动滚动 + 点行 seek。

- 🌐 **插件音源扩展（与移动端同栈）**

  - **双格式插件**：兼容 MusicFree / LX 落雪插件，QuickJS 沙箱执行，HTTP 请求经 Rust 代理无 CORS 限制；URL 一键安装。
  - **插件取流播放**：插件取流 + 防盗链 headers，音质偏好持久化。

- 🔋 **腕上功耗与体积优化**

  - **Wear OS 环境模式**：系统 ambient 下全局压暗 60% + 冻结动画直跳目标行，OLED 防烧屏省电；非 Wear 设备自动降级不崩溃。
  - **极致体积**：v8 单架构包仅 **~15.3MB**（`.so` 包内压缩 + Dart AOT 混淆 + R8 收缩）；支持按表选 v8/v7 单架构出包，也支持双 ABI 全量包。

---

## 🛠️ 使用源码构建运行

### 环境要求

| 依赖项 | 要求 |
| --- | --- |
| **Flutter** | `3.47.0+`（Dart `3.13.0`） |
| **Rust** | Stable（构建钩子自动编译） |
| **JDK** | **必须 21**（22+ 会让 Kotlin daemon 崩溃，`~/.gradle/gradle.properties` 配 `org.gradle.java.home`） |
| **Android** | SDK + NDK（compileSdk 36 / targetSdk 34 / minSdk 28），真机开 USB 调试 |
| **鸿蒙** | DevEco Studio 6+（先「自动生成签名」一次）、`rustup target add aarch64-unknown-linux-ohos` |

### 运行与调试

```bash
git clone https://github.com/TaXiaoQi/XianYu-Music-Watch.git
cd XianYu-Music-Watch
flutter pub get

flutter run          # 开发调试（热重载 r / 热重启 R）
flutter test         # 单测（协议编解码 / 分片重组 / CRC 容错）
```

> `flutter run` / `flutter build` 均自动检测并编译 Rust（`XIANMU_SKIP_RUST=1` 跳过）；改 Rust API 时首次构建会中止，重跑一次即可。

### 构建安装包

```bash
# Android（.apk，Rust 自动编译）
flutter build apk --v8       # 64 位表（Wear OS 3+：三星 GW4/GW5/GW6、小米 S、OPPO Watch 等）
flutter build apk --v7       # 32 位国表（华为 GLL-AL00 等 armeabi-v7a）
flutter build apk --release  # 全量双 ABI（单包兼容 32/64 位，体积更大）

# 鸿蒙（.hap / .app，腕上端根目录内执行）
flutter hap                  # 调试运行
flutter build hap            # 安装包（release，仅 ohos-arm64）
flutter build app            # 商店包（AppGallery 上架用）
.\scripts\ohos\build-ohos.ps1            # 全自动：编 Rust + 构建 + 归档 releases\ohos
```

- `--v7`/`--v8` 由本机 PowerShell profile 的 flutter 包装函数注入 ABI 参数（等价 `$env:XIANMU_RUST_ABI='v8'; flutter build apk --release --target-platform android-arm64`）
- 产物自动归档到 `releases/android/` 与 `releases/ohos/`：`弦予音乐v<版本>-Watch-<架构>.apk/.hap`（版本号取自 `version.ts`）
- 正式签名 alias `xianyu_watch`，`key.properties` 缺失时回退 debug 签名；鸿蒙构建期间必须**完全关闭 DevEco Studio**；装机 `hdc install -r <HAP>`

---

## 📐 技术架构

腕上端与手机端组成「主从播放」体系：手机是播放事实源（手机端 App 或其后台服务），手表既远程操控也可独立播放。通信走自研 XYW1 二进制协议，传输层双通道（蓝牙 RFCOMM 优先，云端 WebSocket 兜底）。

```mermaid
graph LR
    A[腕上端 · Flutter + Rust<br/>外置控制器 / 独立播放器] <-->|XYW1 二进制协议<br/>蓝牙 RFCOMM 优先 · WebSocket 中继兜底| B[手机端 · XianYu-Music-Mobile<br/>播放事实源]
    B -. 推送 state / now_playing / lyric .-> A
    A -. 播控 / seek / 音量 .-> B

    style A fill:#fff0f6,stroke:#eb2f96;
    style B fill:#f6ffed,stroke:#52c41a;
```

### 模块划分

| 模块 | 路径 | 职责 |
| --- | --- | --- |
| **链路状态机** | `lib/src/link/` | `link_provider`（自动连接 / 3s ping / 10s 判死 / 指数退避重连 / 本地进度插值 / 表冠音量）、`rfcomm_client`（蓝牙通道）、`cloud_client`（云兜底）、`protocol`（XYW1 帧编解码 + 分片重组，与手机端严格镜像） |
| **共享播放 UI** | `lib/src/ui/player/` | `play_page_body`（圆屏大封面 + 环形进度 seek + 五键控制）、`lyrics_view`（逐行高亮 + 自动滚动 + 点行 seek）、`page_dots`、`player_source`（联动/本地双数据源抽象） |
| **联动控制页** | `lib/src/ui/controller/` | 手机播放的延伸控制（播放 ↔ 歌词两页横移），歌词经链路接收 + LRU 解析缓存 |
| **独立模式** | `lib/src/ui/local/`、`lib/src/library/` | `LocalMusicHub` 三页主壳（网易云手表式）、本地库扫描列表、插件搜索页 |
| **插件扩展** | `lib/src/plugin/` | 从移动端移植的插件引擎（MusicFree / LX 双格式，去云同步等移动端专属逻辑） |
| **歌词** | `lib/src/lyrics/` | 与移动端镜像的歌词模型 + 仓库（本地 Rust API / 链路推送双通道） |
| **Rust 底座** | `rust/` | 与移动端同源 `libxianyu_core`：本地音乐扫描 / 元数据解析 / 设置持久化 |
| **原生层** | `android/` | `WatchLinkClient`（RFCOMM 客户端 + 读线程 + 后台拉起通知）、ambient 生命周期观察（非 Wear 设备自动降级） |

### 关键机制速记

- **握手**：手表连接成功发 `hello{role:'watch'}`；手机回 hello 并立即推送 `now_playing + state + position` 快照；ping 由手表发起，手机只回 pong。
- **拉起（高德腕上式）**：手表后台收到 `now_playing` → 原生层发 fullScreenIntent 高优通知拉起 App；前台时按连接状态自动切页，不发通知。
- **音量**：表冠旋转本地即时 ±0.05 并 250ms 节流下发 `cmd{action:'volume'}`；手机回推 state 校准。
- **歌词**：本地模式 Rust API 直读；联动模式手机在切歌时推送归一化歌词 payload（0x13 帧，超限自动分片），手表校验歌曲 id 一致才展示。

### 技术栈

| 层级 | 技术 |
| --- | --- |
| **UI** | Flutter 3.47（圆屏适配 `SteppedListView` 阶梯列表、表冠 `RotaryQuantizer` 量化、ambient 环境模式） |
| **状态** | Riverpod（连接状态即路由、link/player/local 多 Provider） |
| **本地播放** | just_audio + Rust 扫描库（`libxianyu_core.so` 同源核心） |
| **腕上链路** | 自研 XYW1 二进制协议（蓝牙 RFCOMM 优先 / 云端 WebSocket 中继兜底） |
| **插件扩展** | 从移动端移植的 QuickJS 双格式引擎（MusicFree / LX）+ Rust HTTP 代理 |
| **原生层** | Android：RFCOMM 客户端、后台拉起通知、ambient 生命周期；鸿蒙：表冠分发、屏形探测、连续任务保活 |

---

*更新日期：2026-09-17*
