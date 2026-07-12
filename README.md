# Soundcore Manager（安克录音豆）

**soundcore Work**（安克 AI 录音豆 / **D3200**）本地管理 App，基于逆向出的设备协议（见 [`PROTOCOL.md`](PROTOCOL.md)）用 Flutter 实现，脱离飞书 App 独立使用：BLE 配对连接、录音管理、AI 实时/批量转写、Wi‑Fi SoftAP 批量导出。

## 支持平台

| 平台 | 状态 |
|------|------|
| Android | BLE 扫描 / GATT |
| iOS | BLE 扫描 / GATT |
| macOS | BLE 扫描 / GATT（需 Bluetooth entitlement） |

## 功能

- **首页**：录音中显示 AI 实时转写字幕，非录音时显示设备端离线文件列表
- **设备**：电量（耳机 + 充电盒）、录音控制、配对绑定 / 解绑、恢复出厂设置
- **设置**：STT 服务商（xAI / Soniox）切换、语言提示、自动转写开关、API Key 管理、诊断日志
- **扫描**：首页顶部按钮触发底部弹窗（非独立 Tab）搜索并连接 BLE 设备
- **Wi‑Fi 批量导出**：SoftAP 直连 + AES 解密，导出文件本地播放

## 项目结构

```
lib/
├── ai/          # xAI / Soniox STT（实时流式 + 批量文件）
├── audio/       # Ogg/Opus 封装、Opus→PCM 解码
├── ble/         # 扫描广播解析、GATT 服务、离线文件拉取、实时音频流
├── crypto/      # 设备端 ECDH / AES 会话加解密
├── protocol/    # 帧格式、命令字、数据模型
├── state/       # Provider 状态：设备连接、录音、转写、导出目录、App 设置
├── theme/       # 主题与配色
├── ui/          # 首页 / 设备 / 设置页面与组件
└── wifi/        # SoftAP 连接与批量导出服务
```

## 运行

```bash
# macOS（推荐用脚本）
./scripts/debug-mac.sh              # flutter run -d macos --debug
./scripts/debug-mac.sh --build-only # 仅构建 debug .app
./scripts/debug-mac.sh --open       # 构建 debug .app 并打开

# 其他平台
flutter run -d ios
flutter run -d android
```

## 构建

```bash
# macOS release + DMG → dist/soundcore-manager-<version>-macos.dmg
./scripts/build-dmg.sh
./scripts/build-dmg.sh --open       # 构建后在 Finder 中显示 DMG
./scripts/build-dmg.sh --skip-build # 打包已有的 Release .app

# iOS 真机安装（Xcode 签名）
./scripts/install-ios.sh

flutter build ios
flutter build apk   # 或 appbundle
```

## 测试

```bash
flutter test
```

覆盖协议帧编解码、设备加解密、Opus/Ogg 处理、导出目录、STT 数据模型等核心逻辑（`test/`）。

## 说明

- **AI 转写**（可选）：在转写面板中选择 **xAI** 或 **Soniox**。
  - 实时路径：BLE Opus → PCM16 → 对应服务商 WebSocket STT。
  - 批量路径：上传 Ogg 文件（xAI multipart / Soniox 异步 Files API）。
  - Key 配置：`export XAI_API_KEY=…` 和/或 `export SONIOX_API_KEY=…` 后重启 App，或在设置页粘贴保存。
- **Wi‑Fi SoftAP 批量导出 + 解密**：BLE 连接后先做 ECDH 握手（`0x2E/0x01`）生成会话密钥；导出时打开设备 SoftAP → 加入 → WebSocket 拉取，每 160 字节分片用 `1A07` 头（`soundcored3200` magic）中的单文件密钥做 AES‑CTR 解密。导出文件保存在 `Documents/AnkerRecorder/exports` 下，命名为 `{fileId}.opus`（握手失败则为 `.opus.bin`）。本地**播放**使用 `just_audio` 播放已导出文件。
- 设备协议细节（服务/特征 UUID、命令字、加密流程等）见 [`PROTOCOL.md`](PROTOCOL.md)。
- 请保持蓝牙开启；旧版 Android 扫描需授予定位权限。
