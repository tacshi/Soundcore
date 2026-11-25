import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../crypto/device_crypto.dart';
import '../protocol/models.dart';

/// Persistent BLE authentication credentials for firmware 03.56 / 03.66+
/// (`0B/03` optional email + `0B/8B` AES-256-CTR auth with HKDF binding key).
class DeviceAuthCredentials {
  const DeviceAuthCredentials({
    required this.accountId,
    required this.bindingKeyHex,
    this.email,
  });

  final String accountId;
  final String bindingKeyHex;
  final String? email;

  Uint8List? get bindingKey => DeviceCrypto.parseHex(bindingKeyHex);

  bool get isValid =>
      accountId.trim().isNotEmpty && (bindingKey?.length == 32);

  factory DeviceAuthCredentials.fromSharedSecret({
    required String accountId,
    required Uint8List sharedSecret,
    String? email,
  }) {
    final key = DeviceCrypto.deriveBindingKey(sharedSecret);
    return DeviceAuthCredentials(
      accountId: accountId.trim(),
      bindingKeyHex: DeviceCrypto.toHex(key),
      email: email?.trim().isEmpty == true ? null : email?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'accountId': accountId.trim(),
    'bindingKeyHex': bindingKeyHex.trim().toLowerCase(),
    if (email != null && email!.trim().isNotEmpty) 'email': email!.trim(),
  };

  static DeviceAuthCredentials? fromJson(Map<String, dynamic> map) {
    final accountId = (map['accountId'] as String?)?.trim() ?? '';
    final bindingKeyHex = (map['bindingKeyHex'] as String?)?.trim() ?? '';
    final email = (map['email'] as String?)?.trim();
    final creds = DeviceAuthCredentials(
      accountId: accountId,
      bindingKeyHex: bindingKeyHex,
      email: email == null || email.isEmpty ? null : email,
    );
    return creds.isValid ? creds : null;
  }
}

typedef PersistedDeviceState = ({
  bool bound,
  ScannedDevice? device,
  DeviceInfoModel? info,
});

typedef PersistedDeviceLoader = Future<PersistedDeviceState> Function();

/// Disk persistence for last-known / bound D3200 so Device tab survives
/// app restart and BLE disconnect.
class DeviceStore {
  DeviceStore._();

  static const _fileName = 'bound_device.json';
  static const _authFileName = 'device_auth.json';

  static Future<File> _file([String name = _fileName]) async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, name));
  }

  static Future<void> save({
    required bool bound,
    ScannedDevice? device,
    DeviceInfoModel? info,
  }) async {
    try {
      final f = await _file();
      final map = <String, dynamic>{
        'bound': bound,
        'savedAt': DateTime.now().toIso8601String(),
      };
      if (device != null) {
        map['device'] = {
          'id': device.id,
          'name': device.name,
          'rssi': device.rssi,
          'advName': device.advName,
          'productCode': device.productCode,
          'serviceUuid': device.serviceUuid,
          'macAddress': device.macAddress,
          'deviceColor': device.deviceColor,
          'channelId': device.channelId,
          'isBoundAdvertised': device.isBoundAdvertised || bound,
          'isD3200': device.isD3200,
          'manufacturerMark': device.manufacturerMark,
        };
      }
      if (info != null) {
        map['info'] = {
          'serialNumber': info.serialNumber,
          'firmwareVersion': info.firmwareVersion,
          'battery': info.battery,
          'boxBattery': info.boxBattery,
          'boxMac': info.boxMac,
        };
      }
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
      debugPrint('[DeviceStore] saved bound=$bound id=${device?.id}');
    } catch (e) {
      debugPrint('[DeviceStore] save failed: $e');
    }
  }

  static Future<PersistedDeviceState> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        return (bound: false, device: null, info: null);
      }
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final bound = map['bound'] == true;
      ScannedDevice? device;
      final d = map['device'];
      if (d is Map) {
        device = ScannedDevice(
          id: '${d['id'] ?? ''}',
          name: '${d['name'] ?? 'soundcore Work'}',
          rssi: (d['rssi'] as num?)?.toInt() ?? -100,
          advName: d['advName'] as String?,
          productCode: d['productCode'] as String? ?? 'D3200',
          serviceUuid: d['serviceUuid'] as String?,
          macAddress: d['macAddress'] as String?,
          deviceColor: d['deviceColor'] as String?,
          channelId: d['channelId'] as String?,
          isBoundAdvertised: d['isBoundAdvertised'] == true || bound,
          isD3200: d['isD3200'] != false,
          manufacturerMark: d['manufacturerMark'] as String?,
        );
        if (device.id.isEmpty) device = null;
      }
      DeviceInfoModel? info;
      final i = map['info'];
      if (i is Map) {
        info = DeviceInfoModel(
          serialNumber: '${i['serialNumber'] ?? ''}',
          firmwareVersion: '${i['firmwareVersion'] ?? ''}',
          battery: (i['battery'] as num?)?.toInt(),
          boxBattery: (i['boxBattery'] as num?)?.toInt(),
          boxMac: '${i['boxMac'] ?? ''}',
        );
      }
      debugPrint(
        '[DeviceStore] loaded bound=$bound id=${device?.id} name=${device?.displayName}',
      );
      return (bound: bound, device: device, info: info);
    } catch (e) {
      debugPrint('[DeviceStore] load failed: $e');
      return (bound: false, device: null, info: null);
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
      debugPrint('[DeviceStore] cleared');
    } catch (e) {
      debugPrint('[DeviceStore] clear failed: $e');
    }
  }

  static Future<void> saveAuth(DeviceAuthCredentials? auth) async {
    try {
      final f = await _file(_authFileName);
      if (auth == null || !auth.isValid) {
        if (await f.exists()) await f.delete();
        debugPrint('[DeviceStore] auth cleared');
        return;
      }
      final map = <String, dynamic>{
        ...auth.toJson(),
        'savedAt': DateTime.now().toIso8601String(),
      };
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
      debugPrint('[DeviceStore] auth saved accountId=${auth.accountId}');
    } catch (e) {
      debugPrint('[DeviceStore] saveAuth failed: $e');
    }
  }

  static Future<DeviceAuthCredentials?> loadAuth() async {
    try {
      final f = await _file(_authFileName);
      if (!await f.exists()) return null;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final auth = DeviceAuthCredentials.fromJson(map);
      debugPrint('[DeviceStore] auth loaded=${auth != null}');
      return auth;
    } catch (e) {
      debugPrint('[DeviceStore] loadAuth failed: $e');
      return null;
    }
  }

  static Future<void> clearAuth() => saveAuth(null);
}
