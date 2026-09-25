import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { AsyncCallback, Callback } from '@ohos.base';
import socket from '@ohos.bluetooth.socket';
import connection from '@ohos.bluetooth.connection';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

const kWatchLinkServiceUuid = 'f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a';
const kPermissionBluetooth: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

/**
 * 腕上端手表联动 SPP 传输层（ohos，客户端角色）。
 *
 * 职责边界与安卓 WatchLinkClient.kt 完全一致：只做蓝牙 SPP 字节管道
 * （connect / 读写 / 断连感知），帧编解码、CRC、分片重组、心跳
 * （3s ping / 10s 无帧判死）与重连退避全部在 Dart 侧 lib/src/link/
 * （与手机端同一份协议实现），通道名同为 'xianyu/watch_link'。
 *
 * 平台矩阵：@ohos.bluetooth.socket SPP 官方支持 Wearable 18+
 * （HarmonyOS 5.1.0，WATCH 5 系列首发）；本工程 compatibleSdkVersion
 * 即 5.1.0(18)，可安装设备必然具备该 syscap，sppSupported 恒 true。
 * WATCH 3 等 HarmonyOS 2 穿戴版用户走侧载安卓 APK，不经此文件。
 *
 * 与安卓差异（v1，待实机验证）：
 * - 仅客户端角色：startServer/acceptPair/rejectPair 不实现（反向配对仅安卓），
 *   手机侧 sppListen 主动连入由 Dart 侧 onIncomingPair 缺省忽略；
 * - sppRead 事件无 EOF/错误信号：断连感知靠 Dart 心跳 10s 判死兜底；
 * - notifyNowPlaying 无 fullScreenIntent 等价机制，不实现（Dart 侧静默）。
 */
export class WatchLinkDispatcher {
  private static channel: MethodChannel | null = null;
  private static context: common.UIAbilityContext | null = null;
  private static clientSocket: number = -1;
  private static connecting: boolean = false;
  private static readCb: Callback<ArrayBuffer> | null = null;

  /** 连接代际：connect/disconnect 各自推进，丢弃旧代回调防串扰。 */
  private static epoch: number = 0;

  /** 注册通道（configureFlutterEngine 时调用一次；重入仅刷新引用）。 */
  static attach(messenger: BinaryMessenger, context: common.UIAbilityContext): void {
    const ch = new MethodChannel(messenger, 'xianyu/watch_link');
    ch.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        WatchLinkDispatcher.onMethodCall(call, result);
      }
    });
    WatchLinkDispatcher.channel = ch;
    WatchLinkDispatcher.context = context;
  }

  private static onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'sppSupported':
        result.success(true);
        break;
      case 'pairedDevices':
        result.success(WatchLinkDispatcher.pairedDevices());
        break;
      case 'connect': {
        const address = (call.argument('address') ?? '') as string;
        WatchLinkDispatcher.connect(address);
        result.success(null);
        break;
      }
      case 'disconnect':
        WatchLinkDispatcher.disconnect();
        result.success(null);
        break;
      case 'send': {
        const bytes = call.argument('bytes') as Object | null;
        if (bytes instanceof Uint8Array) {
          WatchLinkDispatcher.send(bytes);
        }
        result.success(null);
        break;
      }
      case 'hasPermission':
        result.success(WatchLinkDispatcher.hasPermission());
        break;
      case 'requestPermission':
        WatchLinkDispatcher.requestPermission();
        result.success(null);
        break;
      default:
        // startServer/acceptPair/rejectPair/notifyNowPlaying：不实现，
        // Dart 侧 catch 后静默（反向配对与全屏通知仅安卓）。
        result.notImplemented();
        break;
    }
  }

  // ---- 连接 ----

  /** 连接指定地址（异步，单飞）。成败与断连均经 onConnection 回传。 */
  private static connect(address: string): void {
    if (address.length === 0) {
      return;
    }
    if (!WatchLinkDispatcher.hasPermission()) {
      return;
    }
    if (WatchLinkDispatcher.connecting || WatchLinkDispatcher.clientSocket >= 0) {
      return;
    }
    WatchLinkDispatcher.connecting = true;
    const epoch = ++WatchLinkDispatcher.epoch;
    const options: socket.SppOptions = {
      uuid: kWatchLinkServiceUuid,
      secure: true,
      type: socket.SppType.SPP_RFCOMM,
    };
    const cb: AsyncCallback<number> = (err, sockId) => {
      if (epoch !== WatchLinkDispatcher.epoch) {
        // 期间发生过 disconnect/重连：旧代结果一律丢弃。
        return;
      }
      WatchLinkDispatcher.connecting = false;
      if (err || sockId == null || sockId < 0) {
        WatchLinkDispatcher.emitConnection(false, '');
        return;
      }
      WatchLinkDispatcher.clientSocket = sockId;
      let name = address;
      try {
        const n = connection.getRemoteDeviceName(address);
        if (n && n.length > 0) {
          name = n;
        }
      } catch (e) {
      }
      WatchLinkDispatcher.emitConnection(true, name);
      WatchLinkDispatcher.startRead(sockId, epoch);
    };
    try {
      socket.sppConnect(address, options, cb);
    } catch (e) {
      if (epoch === WatchLinkDispatcher.epoch) {
        WatchLinkDispatcher.connecting = false;
        WatchLinkDispatcher.emitConnection(false, '');
      }
    }
  }

  /** 断开连接（幂等）。不发 onConnection：Dart 侧主动断开自知状态。 */
  private static disconnect(): void {
    WatchLinkDispatcher.epoch++;
    WatchLinkDispatcher.connecting = false;
    const sockId = WatchLinkDispatcher.clientSocket;
    WatchLinkDispatcher.clientSocket = -1;
    WatchLinkDispatcher.teardownRead(sockId);
  }

  private static startRead(sockId: number, epoch: number): void {
    const cb: Callback<ArrayBuffer> = (data) => {
      if (epoch !== WatchLinkDispatcher.epoch) {
        return;
      }
      if (data && data.byteLength > 0) {
        const ch = WatchLinkDispatcher.channel;
        if (ch != null) {
          ch.invokeMethod('onRaw', new Uint8Array(data));
        }
      }
    };
    WatchLinkDispatcher.readCb = cb;
    try {
      socket.on('sppRead', sockId, cb);
    } catch (e) {
    }
  }

  private static teardownRead(sockId: number): void {
    const cb = WatchLinkDispatcher.readCb;
    WatchLinkDispatcher.readCb = null;
    if (sockId < 0) {
      return;
    }
    if (cb != null) {
      try {
        socket.off('sppRead', sockId, cb);
      } catch (e) {
      }
    }
    try {
      socket.sppCloseClientSocket(sockId);
    } catch (e) {
    }
  }

  // ---- 收发 ----

  /** 发送原始字节（帧由 Dart 层编码；写失败静默，断连由 Dart 心跳判死）。 */
  private static send(bytes: Uint8Array): void {
    if (bytes.length === 0) {
      return;
    }
    const sockId = WatchLinkDispatcher.clientSocket;
    if (sockId < 0) {
      return;
    }
    // 拷贝一份连续 ArrayBuffer（入参可能是大缓冲上的视图）。
    const ab: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(ab).set(bytes);
    try {
      socket.sppWrite(sockId, ab);
    } catch (e) {
    }
  }

  // ---- 设备与权限 ----

  /** 已配对设备列表 [{address, name}]（无权限/蓝牙关闭返回空）。 */
  private static pairedDevices(): Array<Object> {
    const out: Array<Object> = [];
    try {
      const ids = connection.getPairedDevices();
      for (const id of ids) {
        let name = id;
        try {
          const n = connection.getRemoteDeviceName(id);
          if (n && n.length > 0) {
            name = n;
          }
        } catch (e) {
        }
        const dev = new Map<string, string>();
        dev.set('address', id);
        dev.set('name', name);
        out.push(dev);
      }
    } catch (e) {
    }
    return out;
  }

  static hasPermission(): boolean {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = info.appInfo.accessTokenId;
      const status = abilityAccessCtrl.createAtManager()
        .checkAccessTokenSync(tokenId, kPermissionBluetooth);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      return false;
    }
  }

  /** 发起 ACCESS_BLUETOOTH 运行时授权，结果经 onPermission 回传 Dart。 */
  private static async requestPermission(): Promise<void> {
    const ctx = WatchLinkDispatcher.context;
    if (ctx == null) {
      WatchLinkDispatcher.emitPermission(false);
      return;
    }
    try {
      const perms: Array<Permissions> = [kPermissionBluetooth];
      const res = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(ctx, perms);
      let granted = res.authResults.length > 0;
      for (const r of res.authResults) {
        if (r !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted = false;
        }
      }
      WatchLinkDispatcher.emitPermission(granted);
    } catch (e) {
      WatchLinkDispatcher.emitPermission(false);
    }
  }

  // ---- 回传 ----

  private static emitConnection(connected: boolean, name: string): void {
    const ch = WatchLinkDispatcher.channel;
    if (ch == null) {
      return;
    }
    const m = new Map<string, Object>();
    m.set('connected', connected);
    m.set('name', name);
    ch.invokeMethod('onConnection', m);
  }

  private static emitPermission(granted: boolean): void {
    const ch = WatchLinkDispatcher.channel;
    if (ch != null) {
      ch.invokeMethod('onPermission', granted);
    }
  }
}
