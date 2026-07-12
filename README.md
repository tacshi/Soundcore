# Soundcore Manager（安克录音豆）

Local management app for **soundcore Work** (安克 AI 录音豆 / **D3200**), built from the protocol notes in [`../PROTOCOL.md`](../PROTOCOL.md).

## Platforms

| Platform | Status |
|----------|--------|
| Android  | BLE scan / GATT |
| iOS      | BLE scan / GATT |
| macOS    | BLE scan / GATT (requires Bluetooth entitlement) |

## Features

- **首页**: live AI transcription while recording, otherwise on-device + local file list
- **设备**: battery, record controls, bind / unbind, factory reset
- **设置**: STT provider (xAI / Soniox), language, auto-transfer, API keys, logs
- **扫描**: button + bottom sheet (not a tab) to find & connect BLE devices
- SoftAP Wi‑Fi batch export + AES decrypt; local playback of exports

## Run

```bash
cd anker_recorder

# macOS (via scripts)
./scripts/debug-mac.sh              # flutter run -d macos --debug
./scripts/debug-mac.sh --build-only # debug .app only
./scripts/debug-mac.sh --open       # build debug .app and open it

# Other platforms
flutter run -d ios
flutter run -d android
```

## Build

```bash
# macOS release + DMG → dist/soundcore-manager-<version>-macos.dmg
./scripts/build-dmg.sh
./scripts/build-dmg.sh --open       # also reveal DMG in Finder
./scripts/build-dmg.sh --skip-build # package existing Release .app

flutter build ios
flutter build apk   # or appbundle
```

## Notes

- **AI transcription** (optional): pick **xAI** or **Soniox** in the transcript panel.
  - Live path: BLE Opus → PCM16 → provider WebSocket STT.
  - Batch path: Ogg file upload (xAI multipart / Soniox async Files API).
  - Keys: `export XAI_API_KEY=…` and/or `export SONIOX_API_KEY=…` then restart the app.
- **Wi‑Fi SoftAP batch export + decrypt**: after BLE connect, ECDH handshake (`0x2E/0x01`)
  builds a session key. Export opens SoftAP → join → WebSocket pull; each 160-B slice is
  AES-CTR decrypted with the per-file key from the `1A07` header (`soundcored3200` magic).
  Saved under `Documents/AnkerRecorder/exports` as `{fileId}.opus` (or `.opus.bin` if
  handshake failed). Local **Play** uses `just_audio` on exported files.
- Keep Bluetooth on; grant location on older Android for scan.
