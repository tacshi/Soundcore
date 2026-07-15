# soundcore Work (安克 AI 录音豆) Protocol Notes

Reverse-engineered from the Feishu Android APK (`lark_feishu.apk`) embedded Anker SDK.

| Item | Value |
|------|--------|
| Product name | 安克 AI 录音豆 / soundcore Work |
| Product code | **D3200** |
| Example SN | `007F1D04CCA3` |
| Example firmware | `4.92.3.06` |
| SDK package | `com.oceanwing.soundcore.spplink` |
| Decompiled sources | `java_src/com/oceanwing/soundcore/spplink/` |
| Extracted DEX | `_re/dex/classes6.dex`, `classes22.dex`, `classes26.dex` |

**Scope:** device pairing, control, offline audio pull, OTA, binding.  
**Out of scope of this SDK:** Feishu 妙记 cloud AI (transcription / 智能纪要) — that is Feishu-side after upload.

---

## 1. Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Feishu 妙记 / 设备管理 UI                               │
└──────────────────────────┬───────────────────────────────┘
                           │ SoundcoreSDK / D3200Device
┌──────────────────────────▼───────────────────────────────┐
│  Anker spplink SDK (oceanwing.soundcore)                 │
│  · BLE control · Classic SPP bulk · Wi‑Fi SoftAP + WS    │
│  · Auth/license · OTA · encrypt · bind                   │
└──────────────────────────┬───────────────────────────────┘
                           │ BLE / BT Classic / Wi‑Fi
┌──────────────────────────▼───────────────────────────────┐
│  Hardware: mic “豆” + charge case (D3200)                │
└──────────────────────────────────────────────────────────┘
```

Also present: product family stubs for **D1301** (`D1301Device`).

---

## 2. Transports

| Transport | Role | When used |
|-----------|------|-----------|
| **BLE GATT** | Primary control channel | Preferred when `isSupportBLE=true` |
| **Classic BT SPP** | Bulk file transfer, handshake | Fallback; also OTA SPP link |
| **Wi‑Fi SoftAP + WebSocket** | Fast file transfer (“快速传输”) | Phone joins device AP, then WS to IP:port |
| **HTTPS** | SDK license / auth | Anker cloud (not Feishu) |

Branch selection (from SDK logs):

- Prefer SPP if already connected and `preferSpp=true`
- Else BLE if supported
- Else SPP fallback

---

## 3. BLE discovery & GATT (how Feishu finds the 录音豆)

### 3.0 No classic Bluetooth pairing for scan/connect

Feishu does **not** require the user to pair the device in system Settings first.

| Step | What Feishu does | Pairing? |
|------|------------------|----------|
| Discover | BLE LE scan only (`BluetoothLeScanner` + `ScanFilter`) | No |
| Identify | Advertisement service UUID + manufacturer data | No |
| Connect (dock tap) | GATT `connectGatt` to MAC + service UUID | No classic bond required for control |
| Optional later | SPP / Wi‑Fi may involve extra BT links | Separate from discovery |

Source: `DeviceFoundManagerImp` (scan filters), `BlueDeviceModelHelper.transferBle` (parse ads), `SDKManagerImp.connect` (GATT).

### 3.1 Advertisement identity (D3200)

| Field | Value / rule |
|-------|----------------|
| **Service UUID** | `020cf5da-0000-1000-8000-00805f9b34fb` → product code **D3200** |
| **preUUID** | First UUID segment; must end with `F5DA` (if starts with `DAF5`, reverse hex pairs) |
| **Manufacturer data** | `companyId (u16 LE) ‖ payload`; first **6 bytes** of combined buffer = **MAC** `AA:BB:CC:DD:EE:FF` |
| **Flags @ byte 6** | color (`& 0x70 == 0x10`), bind bit (`& 0x80`), channel (`& 0x0F`) |
| **Mark @ bytes 8–13** | ASCII may be `soundc` (lot filter in SDK) |
| **Local name** | `ScanRecord.getDeviceName()` when present (often empty on macOS/iOS privacy) |

Feishu UI shows a friendly name from adv local name when available; product is always known from the service UUID even if the OS only shows a UUID remoteId.

SPP MAC (for classic bulk transfer later): BLE MAC last octet **minus 1** (`convertBleMacToSppMac`).

### 3.2 GATT after connect

Source: `service/ble/BleBluetoothImp.java`

| Role | UUID |
|------|------|
| Service UUID | From advertisement (`020cf5da-…` for D3200) |
| **WRITE** characteristic | `00007777-0000-1000-8000-00805F9B34FB` |
| **READ / notify** characteristic | `00008888-0000-1000-8000-00805F9B34FB` |
| CCCD (notifications) | `00002902-0000-1000-8000-00805f9b34fb` |
| OTA service | `66666666-6666-6666-6666-666666666666` |
| OTA characteristic | `77777777-7777-7777-7777-777777777777` |

Commands are written (queued) to the WRITE char; responses arrive as notifications on READ.

Helpers: `helper/BlueDeviceModelHelper.java`, `utils/AndroidUtils.java`.

---

## 4. Binary frame format

### 4.1 TX — phone → device

Built by `getHeaderByCmdTypeID` + `BaseLink.assemblyCommand` / `commandDataHasCheckSum`.

```
Offset  Size  Field
------  ----  ------------------------------------------
0       5     Magic prefix: 08 EE 00 00 00
5       1     cmdType
6       1     cmdId
7       2     total_length (uint16 little-endian)  // includes whole packet
9       N     payload (optional)
9+N     1     checksum
```

Header constructor (everywhere in EventSend managers):

```java
new byte[]{ 0x08, 0xEE, 0x00, 0x00, 0x00, cmdType, cmdId };
// Java signed form: { 8, -18, 0, 0, 0, cmdType, cmdId }
```

**Checksum** (`CheckSumUtil`): sum of all bytes before the checksum, **mod 256** (low 8 bits).

```text
checksum = (Σ packet[0 .. len-2]) & 0xFF
```

**Length field:** total packet size in bytes (header + length field + payload + checksum), uint16 LE at offset 7.

`LENGTH_COUNT = 2`, `CHECKSUM_COUNT = 1`, default send spacing ~500 ms (`mSendNextCmdDelayTime`).

### 4.2 RX — device → phone

Parser: `PacketBufferComplete`, validator: `CommonUtils.isValidPacket`.

```
Offset  Size  Field
------  ----  ------------------------------------------
0       4     Magic: 09 FF 00 00
4       1     flags / status nibble field (see §4.3)
5       1     cmdType
6       1     cmdId
7       2     total_length (uint16 LE)
9       N     payload
...     1     checksum (same additive scheme)
```

- Valid header check: `data[0]==0x09 && data[1]==0xFF` (and often `data[2]==0 && data[3]==0`)
- Minimum frame size: **10** bytes
- Length at offset **7** must be ≥ 10; frame is `data[start : start+length]`

High-volume frames with `cmdType==0x1A && cmdId==0x08` (file slices) are not fully hex-logged.

### 4.3 Status byte at offset 4

```text
low  nibble  = getLowFour(data[4])  = data[4] & 0x0F   // often successFlag (1 = ok)
high nibble  = getHighFour(data[4]) = (data[4] & 0xF0) >> 4
```

Many handlers treat `successFlag == 1` as success.  
For some device-info ops, `data[4] == 1` means success boolean.

### 4.4 Framing pipeline

```
BLE notify / SPP read
    → CMDDispatch.dispatchMsg
    → PacketBufferMulti / PacketBufferComplete.processPackets
    → isNewLegallyCmd (checksum)
    → OnReceiveFullPackage listeners (DeviceInfo, Audio, Binding, WiFi, OTA, …)
```

---

## 5. Command catalog (TX)

All values **unsigned hex**. Java sources use signed bytes (e.g. `-126` → `0x82`, `-72` → `0xB8`).

### 5.1 Device info — `cmdType = 0x01`

Source: `DeviceEventSendManager`, RX: `DeviceInfoDispatch`

| cmdId | Name | Payload |
|-------|------|---------|
| `0x01` | getDeviceInfo | empty |
| `0xA6` | syncTime | 4B UTC timestamp LE + 1B timezone (`getTimeZoneData`) |
| `0xB8` | resetDevice | empty |

**RX cmdIds (type 0x01):**

| cmdId | Handler |
|-------|---------|
| `0x01` | device info body (see §6.1) |
| `0x03` | battery info |
| `0x04` | charging status |
| `0xA6` | sync time result |
| `0xB8` | reset result |

### 5.2 Audio control — `cmdType = 0x18`

Source: `AudioEventSendManager`  
Static header `AUDIO_CONTROL = {08 EE 00 00 00 18 82}`

| cmdId | Name | Payload |
|-------|------|---------|
| `0x82` | startRecord | `01` |
| `0x82` | pauseRecord | `02` |

### 5.3 Audio / file transport — `cmdType = 0x1A` / `0x1B`

| type,id | Name | Payload |
|---------|------|---------|
| `1A 0E` | getAllAudioRecordFiles | page `uint16` LE |
| `1B 0E` | getAllAudioRecordFilesWithEndTime | page `uint16` LE |
| `1A 07` | startTransportAudioFile | see below |
| `1A 0F` | startBTTransport (SPP) | `00` Android / `01` iOS |
| `1A 11` | stopBTTransport | platform flag |
| `1A 10` | deleteFile | fileID `uint32` LE |

**startTransportAudioFile payload (9 bytes):**

```
0..3  already_transferred_size  uint32 LE
4..7  fileId / fileName         uint32 LE  (often timestamp-like id)
8     realtimeFlag              0 = offline, 1 = realtime
```

When `realtimeFlag == 1`, transfer prefers non-SPP path (`preferSpp=false`).

**RX (type 0x1A) — `FileTransportDispatch` / `AudioMessageDispatch`:**

| cmdId | Meaning |
|-------|---------|
| `0x01`–`0x05` | Wi‑Fi related (handled by WifiMessageDispatch / skipped in audio) |
| `0x05` | Wi‑Fi config response (IP + port) |
| `0x06` | audio / transfer status while recording |
| `0x07` | file head info → start transferring |
| `0x08` | file slice data |
| `0x0A` | file transfer finished |
| `0x0E` | offline file list |
| `0x0F` | BT transport status |
| `0x10` | delete file response |
| `0x12` | file slice (mark/variant) |
| `0x13` | (ignored / reserved) |

Type `0x1B` / id `0x0E`: offline file list **with end time** per entry.

### 5.4 Binding — `cmdType = 0x0B`

Source: `BindingEventSendManager`, RX: `BindingMessageDispatch`

| cmdId | Name | Payload (Feishu / Anker SDK) |
|-------|------|------------------------------|
| `0x87` | bind | `01` only |
| `0x87` | unbind | `00` only |

SDK code is fixed one-byte payloads:

```java
// BindingEventSendManager
bindingDevice()   → payload { 1 }
unBindingDevice() → payload { 0 }
```

Public API is only `bindingDevice(mac, uuid, boolean binding)` — **no** clear-files
or broadcast-tone arguments. Feishu wrapper (`SoundCoreAudioDevice.bindDevice` /
`unBindDevice`) just calls that boolean.

**RX:**

| cmdId | Meaning |
|-------|---------|
| `0x87` | binding result (`successFlag` low nibble) |
| `0x88` | device confirm bind (bind path; not used for unbind) |

**Observed behavior (stock 1-byte):**

- Unbind ACK → SDK disconnects BLE; offline files are **not** wiped by the command
  itself (app comment / Feishu path). Factory wipe is separate: type `0x01` id `0xB8`.
- Bind ACK → optional device-side 0x88 confirm; user press on device may be required.
- Advertisement bind bit (`flags & 0x80`) reflects bound state for scan filtering.

**Experimental multi-byte probe (not in Feishu SDK):**

Firmware may accept a longer payload; untested in production SDK:

| Op | Payload | Hypothesis |
|----|---------|------------|
| bind | `01 01` | 2nd byte = play tone / 播报 after bind |
| bind | `01 00` or `01` | silent bind (stock) |
| unbind | `00 01` | 2nd byte = clear offline recordings on unbind |
| unbind | `00 00` or `00` | keep files (stock) |

How to verify on device:

1. Note `freeMemoryKB` + file list before action.
2. Send extended payload via app toggles (设备 → 配对绑定).
3. After ACK: list files again / listen for tone / re-scan adv bind bit.
4. If freeMemory + file count unchanged, firmware likely ignores byte 2.

Related but **not** bind flags: `resetDevice` (`0x01/0xB8`) clears device state;
per-file delete is `0x1A/0x10`. DeviceInfo also exposes read-only
`autoPowerOff*` / `pickupIndicatorLightStatus` with **no** TX setters in this SDK.

### 5.5 More settings — `cmdType = 0x10`

| cmdId | Name | Payload |
|-------|------|---------|
| `0xA2` | Find-my / related toggle (`setFindMyEnable` style) | `00` / `01` |

RX: type must be `0x10` (`MoreSettingMessageDispatch`).

### 5.6 Encrypt — `cmdType = 0x2E`

| cmdId | Name | Payload |
|-------|------|---------|
| `0x01` | notifyEncryptFileData | app ECDH public key (P-256 uncompressed, 65 B) |

**RX `0x2E/0x01` (full frame ≥ 106 B):**

| Offset | Size | Field |
|--------|------|--------|
| 9 | 65 | device public key (uncompressed) |
| 74 | 32 | device ECDH shared secret (must match app) |

**Session key** (`CryptoManager.generateSessionKeyAndSave`):

```
shared = ECDH(appPrivate, devicePublic)   // X coordinate, 32 B
sessionKey = HKDF-SHA256(shared, salt={1,2,3}, info={1,2,3}, len=32)
```

**Per-file key** (`initDevDecrypt` on `1A07` head ≥ 97 B):

```
@9  fileId u32, @13 size u32
@17 nonce 16 B
@33 encryptedFileKey 46 B
@79 sessionNonce 16 B
@95 errorCode u8

fileKeyMaterial = AES-CTR-256(sessionKey, sessionNonce, encryptedFileKey)
// must start with ASCII "soundcored3200" (14 B); rest = file AES key (32 B)
```

**Chunk decrypt** (`AesCtrStreamDecrypt`): AES-CTR with IV =
`nonce[0..12) ‖ BE_u32(seq * 10)` on each 160-B payload (seq from slice).

Audio files can be encrypted; secret material in `service/audio/model/AudioFileSecretKey`.

### 5.7 Device log — `cmdType = 0xFF`

| cmdId | Notes |
|-------|--------|
| `0x20` | enable/encrypt/level/module flags (4 bytes) |
| `0x21` | log list / start |
| `0x22` | … |
| `0x27` | log by fileID (`uint32` LE) |

### 5.8 OTA — various under `OtaEventSendManager`

- Same `08 EE` header family; OTA often uses dedicated SPP UUID (`SPP_OTA_UUID` / `TYPE_SPP_OTA`) and OTA BLE chars.
- Enter/leave OTA-related mode: type `0x01`, id `0xBB`, payload `00`/`01`.
- Segment transfer uses CRC32 (LE), magic blobs, and command byte `0x82` in segment path.
- Wi‑Fi OTA mode flag: `OtaEventSendManager.getCurrentWifiMode()`.

The dedicated OTA characteristic carries raw BES messages (no normal `08 EE`
frame/checksum): `command u8 | payloadLength u32 LE | payload`. D3200 BT OTA
uses `BEST` (`42 45 53 54`) as its user magic and follows this sequence:

```text
99 protocol version → 9A
97 set OTA user     → 98
8E hardware info    → 8F
9D upgrade type     → 9E
9B role random id   → 9C
90 select side      → 91
8C breakpoint       → 8D
80 image size+CRC32 → 81
86 config block     → 87
85 image chunks; 82 segment CRC every 32768 bytes → 83
88 whole-image CRC  → 84
92 apply image      → 93
```

CRC is standard reflected CRC-32 (`0xEDB88320`), encoded little-endian. With a
512-byte MTU, the SDK sends up to 504 firmware bytes per `0x85` command so the
5-byte BES header fits the 509-byte ATT value limit.

---

## 6. Response payloads (parsed layouts)

### 6.1 Device info (`09 FF … type=01 id=01`)

Source: `DeviceInfoDispatch.onParseDeviceInfo` — parse from **full frame**, index starts at **9**:

| Field | Size | Notes |
|-------|------|--------|
| connectStatus | 1 | |
| **deviceBattery (mic)** | 1 | D3200 battery bucket `0…9`, displayed as `(wire + 1) × 10%`. Feishu SDK stores the wire bucket as-is / also mirrors left/right. Values above `9` should be treated as literal percentages for forward compatibility. |
| chargingStatus (mic) | 1 | `1` = charging |
| firmwareVersion | 5 | ASCII (e.g. `04.92`) |
| serialNumber | 16 | ASCII, lowercased |
| totalMemoryKB | 4 | uint32 LE, kilobytes. Display total using KB-based scaling. |
| freeMemoryKB | 4 | uint32 LE, kilobytes. Display used as `totalMemoryKB − freeMemoryKB`. |
| boxChargingStatus | 1 | `1` = case charging |
| boxFirmware | 5 | ASCII |
| **boxBattery (case)** | 1 | Same 0…9 battery-bucket encoding as mic |
| box MAC | 6 | `AA:BB:…` (reject all-identical padding) |
| deviceColor | 1 | |
| autoPowerOffSwitch | 1 | |
| autoPowerOffIndex | 1 | |
| pickupIndicatorLight | 1 | |
| boxIndicatorLight | 1 | |
| recording | 1 | |
| wifiFirmware | 5 | ASCII |

**Live battery push** (`type=0x01 id=0x03`): payload `micBattery, caseBattery`.  
**Live charging push** (`type=0x01 id=0x04`): payload `micCharging, caseCharging`.

### 6.2 Offline file list (`type=0x1A id=0x0E`)

Min length 19. Payload from offset 9:

| Field | Size | Notes |
|-------|------|--------|
| fileCount | 2 | uint16 LE |
| repeated × fileCount | 8 | `fileId` u32 LE + `size` u32 LE |
| currTransportFileTimestamp | 4 | u32 LE |
| currTransportFileDuration | 4 | i32 LE |

Duration heuristic in app: `size/20*166` (approximate ms/time units).

### 6.3 Offline file list with end time (`type=0x1B id=0x0E`)

Same as above but each file entry is **12 bytes**:  
`fileId u32` + `endTime u32` + `size u32`.

### 6.4 Wi‑Fi SoftAP open (TX `type=0x1A id=0x05`) + response

**TX payload** (`WiFiSendManager.sendWiFiConfig`):

```
[ssid_len u8][ssid utf8][pwd_len u8][password utf8]
```

App-chosen credentials (Feishu default when none provided):

```
ssid     = "WiFi-" + currentTimeMillis
password = String.valueOf(currentTimeMillis)
```

Close SoftAP: TX `type=0x1A id=0x02` empty payload (`closeWiFiMode`).

**RX on success** (`successFlag==1`), full frame ≥ 15 bytes:

```
offset 9..12  IP as 4 bytes  (parsed as data[12].data[11].data[10].data[9]  — reverse order in code)
offset 13..14 port uint16 LE
```

Code:

```text
ip   = data[12].data[11].data[10].data[9]
port = data[13] | (data[14] << 8)
```

Then phone joins SoftAP (`ssid`/`password` just sent) and opens WebSocket to `ip:port` (`WiFiWebSocketManager`).

### 6.5 Wi‑Fi WebSocket (fast transfer)

Sources: `WiFiWebSocketManager`, `WiFiTransportDispatch`, `WifiFileTransferHandler`.

- URL: `wss://ip:port` (default `useSSL=true`) or `ws://…` fallback; TLS trust-all for local device.
- **Control TX as WebSocket text** (hex string, not binary):
  - File header request (18 bytes, no trailing checksum; last payload byte `0x1B`):
    `08 EE 00 00 00 1A 07 12 00 | transferredSize u32 LE | fileId u32 LE | 1B`
  - Transfer complete `1A0A`: `08 EE 00 00 00 1A 0A 0B 00 01 | csum`
  - Session end: text `"FINISH"` (ACK/`OK` text replies possible)
  - App ping text: `"ping"`
- **RX binary** reuses BLE framing (`09 FF …`):
  - `1A 07` file head (≥97 B when encrypted: fileId@9, size@13, key material…)
  - `1A 08` / `1A 12` slices: from offset 9, 166-byte units = `seq u32 | flags u8 | 160 data | pad`
  - `1A 0A` transfer finished
- Chunks may be AES-CTR encrypted (`CryptoManager.decryptDataChunk`); raw 160-B units can still be saved without keys.
- UDP keepalive: dest `ip:32003`, payload ASCII `soundcore-keep-alive-unicast` (~2 s).

---

## 7. Auth / cloud (Anker)

Source: `service/auth/SDKConfig.java`, `AuthRemoteService.java`

| Environment | Base URL |
|-------------|----------|
| DEVELOPMENT | `https://speaker-api-ci.anker-in.com` |
| PRODUCTION | `https://speaker-api.anker-in.com` |
| Legacy default | `https://speaker-ci.eufylife.com` |

`SDKInitConfig` fields of interest:

- `userId`, `deviceId`, `token`
- `licenseJson`, `license_signature`
- `environment`, `commandTimeOut`, `fileTransferInterval`
- `isSPPSingleThread`, `androidUDPPingTimeIntval`, `androidWIFIReceiveThreadSwitch`

License: offline RSA verify with embedded public keys in `SDKConfig` (dev/prod differ).

`AuthHttpClient.authenticate(baseUrl, endpoint, userId, deviceId, token, productCode, sdkVersion, …)`.

**Note:** Feishu account pairing identity may be required for full cloud features; local BLE control may work with reduced/offline license depending on firmware policy.

---

## 8. SDK entry points (for reading code)

| Class | Role |
|-------|------|
| `SoundcoreSDK` | Public API facade |
| `base/SDKManagerImp` | Init / lifecycle |
| `device/D3200Device` | Full product state machine (~3k lines) |
| `device/SoundcoreDevice` | Connect, `sendCommand`, SPP/BLE routing |
| `service/link/BaseLink` | TX frame assembly |
| `service/link/ble/BleLink` / `spp/SPPLink` | Link impls |
| `service/dispatch/CMDDispatch` | RX reassembly |
| `service/audio/*` | Record, file list, SPP/WiFi transfer |
| `service/wifi/*` | SoftAP connect, UDP, file transfer orchestration |
| `service/ble/BleBluetoothImp` | GATT UUIDs, write queue |
| `service/auth/*` | License + HTTP |
| `service/ota/*` | Firmware upgrade |
| `service/encrypt/*` | File encryption key exchange |
| `service/binding/*` | Bind / unbind |

---

## 9. Typical session flow (management tool)

```
1. BLE scan → filter Soundcore / D3200 advertisement
2. GATT connect → discover service → enable notify on …8888…
3. getDeviceInfo          (01 01)
4. syncTime               (01 A6 + ts/tz)
5. bind                   (0B 87 01)     // if required
6. Local ops:
     start/pause record   (18 82 01/02)
     list files           (1A 0E page)
     delete file          (1A 10 id)
7. Pull file (BT):
     startBTTransport     (1A 0F)
     startTransportFile   (1A 07 …)
     receive 1A 07 head → 1A 08 slices → 1A 0A done
8. Pull file (Wi‑Fi fast):
     BLE 1A05 send SSID/password (app generates WiFi-{ms} / {ms})
     parse RX 1A05 → IP:port
     join SoftAP (manual on desktop; system Wi‑Fi join)
     WebSocket wss/ws://ip:port + UDP :32003 keepalive
     hex text 1A07 file request → 1A07/08/0A binary RX
     text FINISH + BLE 1A02 close
9. Optional: OTA via OTA BLE/SPP path
```

---

## 10. Live validation tips

```bash
# While using official Feishu + device
adb logcat | grep -iE 'Soundcore|spplink|filedata|BleBluetooth|WifiMessage|AudioTransport|DeviceInfo'

# Or HCI snoop / nRF Connect:
# - Confirm WRITE/READ UUIDs
# - Capture 08 EE … TX and 09 FF … RX
```

Useful log tags from decompiled code:

- `DeviceInfoImp`, `AudioTransportImp`, `BindingMessageDispatch`
- `WifiMessageDispatch`, `SoundcoreDevice filedata`
- `BleBluetoothImp`, `BaseLink`, `CMDDispatch`, `PacketBufferComplete`

---

## 11. Workspace layout

```
lark_feishu/
├── PROTOCOL.md                          ← this file
├── java_src/com/oceanwing/soundcore/    ← decompiled SDK
├── _re/
│   ├── dex/classes{6,22,26}.dex
│   ├── PROTOCOL_MAP.md                  ← earlier draft (see this file as canonical)
│   ├── protocol_strings.txt
│   └── logs/jadx_*.log
└── (optional) full APK: ../lark_feishu.apk
```

### How this was decompiled

Full APK (~33 DEX, 344 MB) OOMs jadx on 16 GB RAM; apktool also crashes on resource XML NPE.  
Targeted approach:

```bash
unzip -j lark_feishu.apk 'classes*.dex' -d _re/dex
# find oceanwing in classes6/22/26
JAVA_OPTS='-Xmx5g' jadx -r -j 2 -ds java_src _re/dex/classes6.dex
# … same for classes22.dex, classes26.dex
```

---

## 12. Building your own management tool (suggested phases)

1. **Read-only status** — BLE connect, getDeviceInfo, battery, SN, FW, storage  
2. **Control** — record start/pause, bind, settings toggles  
3. **File inventory** — list offline files (0x1A/0x0E)  
4. **BT file pull** — SPP or BLE stream path (0x1A/0x07–0x0A)  
5. **Wi‑Fi fast pull** — SoftAP + WebSocket  
6. **OTA / encrypt** — only if needed  
7. **Feishu AI** — separate; use Feishu open APIs after you own the audio files  

---

## 13. Legal / ethics

Intended for **interoperability with hardware you own**.  
Do not redistribute proprietary firmware, license private keys, or bypass paid cloud services unlawfully. Respect Anker and Feishu terms for cloud features.

---

## 14. Open questions (not fully resolved from static RE)

- Exact BLE **service UUID** advertised by D3200 (filled from live scan / `BlueDeviceModel`)
- Full SoftAP **SSID/password derivation** when Feishu supplies non-generated creds
- File slice packet layout (0x1A/0x08) field-by-field — partial: 166-B units, 160-B payload
- AES file-key exchange for playable decrypt (`CryptoManager` / encrypt 0x2E)
- Audio container codec after decode (`DecodeAudioFileManager`)
- Whether bind is mandatory for local-only operation on current firmware

Capture live traffic to fill these gaps.

---

*Generated from static analysis of Feishu APK / Anker `spplink` module. Update this file as live captures refine layouts.*
