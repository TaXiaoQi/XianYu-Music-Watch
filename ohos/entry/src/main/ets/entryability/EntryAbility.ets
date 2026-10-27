
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FlutterAbility, FlutterEngine, MethodChannel, EventChannel, EventSink, Any } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { dispatchBackToFlutter } from './BackDispatcher';
import { attachRotarySink } from './RotaryDispatcher';
import { WatchLinkDispatcher } from './WatchLinkDispatcher';

interface MusicSummary {
  folder: string
  count: number
}

interface PickSummary {
  folder: string
  imported: number
  total: number
}

export default class EntryAbility extends FlutterAbility {
  private systemNavChannel: MethodChannel | null = null;
  private keepAliveChannel: MethodChannel | null = null;
  private screenShapeChannel: MethodChannel | null = null;
  private keepScreenChannel: MethodChannel | null = null;
  private mediaChannel: MethodChannel | null = null;
  private keepAliveStarted = false;
  private appMainWindow: window.Window | null = null;
  private keepScreenPending: boolean | null = null;

  onBackPressed(): boolean {
    dispatchBackToFlutter(this.context)
    return true
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    super.onWindowStageCreate(windowStage)
    windowStage.getMainWindow()
      .then((w: window.Window) => {
        this.appMainWindow = w
        if (this.keepScreenPending !== null) {
          w.setWindowKeepScreenOn(this.keepScreenPending).catch(() => {})
          this.keepScreenPending = null
        }
      })
      .catch((err: Error) => hilog.error(0x0100, 'xianyu', `getMainWindow failed: ${String(err)}`))
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.systemNavChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/system_nav');
    this.systemNavChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'moveTaskToBack') {
          hilog.info(0x0100, 'xianyu', 'MOVE_TASK_TO_BACK CALLED (from Dart)')
          this.context.moveAbilityToBackground()
            .then(() => result.success(null))
            .catch(() => result.error('move_failed', 'moveAbilityToBackground failed', null))
        } else if (call.method === 'restartApp') {
          const appContext = this.context.getApplicationContext() as common.ApplicationContext
          try {
            const want: Want = {
              bundleName: 'com.xianyumusic.watch.next',
              abilityName: 'EntryAbility'
            }
            appContext.restartApp(want)
            result.success(null)
          } catch (err) {
            result.error('restart_failed', `restartApp failed: ${(err as Error).message}`,
              null)
          }
        } else {
          result.notImplemented()
        }
      }
    });

    this.screenShapeChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/screen_shape');
    this.screenShapeChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'isRound') {
          // getDefaultDisplay 已弃用（API 18），同步接口读屏幕参数即可
          const d = display.getDefaultDisplaySync()
          const w = d.width
          const h = d.height
          const isRound = w > 0 && h > 0 &&
            Math.abs(w - h) / Math.max(w, h) < 0.1
          result.success(isRound)
        } else {
          result.notImplemented()
        }
      }
    });

    this.keepAliveChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/keep_alive');
    this.keepAliveChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'start') {
          this.startKeepAlive()
            .then(() => result.success(true))
            .catch((err: Error) => result.error('keepalive_failed', String(err), null))
        } else {
          result.notImplemented()
        }
      }
    });

    const rotaryChannel = new EventChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/rotary');
    rotaryChannel.setStreamHandler({
      onListen: (args: Any, events: EventSink) => {
        attachRotarySink(events)
      },
      onCancel: (args: Any) => {
        attachRotarySink(null)
      }
    });

    this.keepScreenChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/keep_screen');
    this.keepScreenChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'set') {
          const enable: boolean = (call.args as ESObject)?.enable !== false
          if (this.appMainWindow === null) {
            this.keepScreenPending = enable
            result.success(null)
            return
          }
          this.appMainWindow.setWindowKeepScreenOn(enable)
            .then(() => result.success(null))
            .catch((err: Error) => result.error('keep_screen_failed', String(err), null))
        } else {
          result.notImplemented()
        }
      }
    });

    // 本地音乐导入通道：API 21 SDK 上普通应用无音频枚举 API（mediaLibrary 已移除、
    // photoAccessHelper 仅图片视频），唯一官方途径是免权限 AudioViewPicker；
    // 导入到应用沙箱 filesDir/music 后由 Dart 侧复用现有 Rust 扫描管线。
    this.mediaChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/media');
    this.mediaChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'musicDir') {
          this.ensureMusicDir()
            .then((dir: string): MusicSummary => this.musicSummary(dir))
            .then((summary: MusicSummary) => result.success(summary))
            .catch((err: Error) => result.error('music_dir_failed', String(err), null))
        } else if (call.method === 'pickAudio') {
          this.pickAndImportAudio()
            .then((summary: PickSummary) => result.success(summary))
            .catch((err: Error) => result.error('picker_failed', String(err), null))
        } else {
          result.notImplemented()
        }
      }
    });

    // 手表联动 SPP 通道（ohos 客户端角色）：协议与安卓 WatchLinkClient.kt
    // 一致（字节管道 + Dart 侧帧/心跳/重连），实机矩阵见 WatchLinkDispatcher。
    WatchLinkDispatcher.attach(
      flutterEngine.dartExecutor.getBinaryMessenger(), this.context)
  }

  private async startKeepAlive(): Promise<void> {
    if (this.keepAliveStarted) {
      return
    }
    // backgroundTaskManager 非所有设备支持（syscap 检查警告），守卫后直接跳过，
    // 避免在不支持设备上运行期抛错（此前未捕获 rejection）
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.LongTimeRunning')) {
      return
    }
    try {
      const wa = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'com.xianyumusic.watch.next', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      } as wantAgent.WantAgentInfo)
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        wa
      )
      this.keepAliveStarted = true
    } catch (err) {
      // 常驻失败仅记录，不影响 UI（消除 may-throw 警告，也避免未处理 rejection）
      hilog.error(0x0100, 'xianyu', `startKeepAlive failed: ${String(err)}`)
    }
  }

  // ─── 本地音乐导入（xianyu/media）──────────────────────────────

  private musicDirPath(): string {
    return `${this.context.filesDir}/music`
  }

  private async ensureMusicDir(): Promise<string> {
    const dir = this.musicDirPath()
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true)
    }
    return dir
  }

  private musicSummary(dir: string): MusicSummary {
    let count = 0
    try {
      count = fs.listFileSync(dir).length
    } catch (err) {
      count = 0
    }
    return { folder: dir, count: count }
  }

  // 拉起系统音频选择器（免权限），逐个把选中 URI 拷入沙箱 music 目录
  private async pickAndImportAudio(): Promise<PickSummary> {
    const dir = await this.ensureMusicDir()
    const audioPicker = new picker.AudioViewPicker(this.context)
    const opts = new picker.AudioSelectOptions()
    opts.maxSelectNumber = 100
    const uris: Array<string> = await audioPicker.select(opts)
    let imported = 0
    for (const uri of uris) {
      try {
        if (await this.importOneAudio(uri, dir)) {
          imported++
        }
      } catch (err) {
        hilog.error(0x0100, 'xianyu', `import audio failed: ${String(err)}`)
      }
    }
    return { folder: dir, imported: imported, total: this.musicFileCount(dir) }
  }

  private musicFileCount(dir: string): number {
    try {
      return fs.listFileSync(dir).length
    } catch (err) {
      return 0
    }
  }

  private async importOneAudio(uri: string, dir: string): Promise<boolean> {
    const ext = this.sniffAudioExt(uri)
    const dest = `${dir}/audio_${this.uriHash(uri)}${ext}`
    if (fs.accessSync(dest)) {
      return false // 同 URI 已导入，去重
    }
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY)
    const dst = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    try {
      // picker URI 为临时授权，立即以 fd 顺序读写拷入沙箱（拷到 EOF，无需预知大小）
      const chunkSize = 512 * 1024
      const buf = new ArrayBuffer(chunkSize)
      for (;;) {
        const n = fs.readSync(src.fd, buf)
        if (n <= 0) {
          break
        }
        const w = fs.writeSync(dst.fd, buf, { length: n })
        if (w < n) {
          throw new Error(`short write: ${w}/${n}`)
        }
      }
    } catch (err) {
      try {
        fs.unlinkSync(dest)
      } catch (e) {
        // 清理失败忽略，下次导入同 URI 会因 accessSync 命中而跳过
      }
      throw err as Error
    } finally {
      fs.closeSync(dst)
      fs.closeSync(src)
    }
    return true
  }

  // djb2 字符串哈希：媒体库音频 URI（file://media/Audio/<id>）稳定，可作去重键
  private uriHash(uri: string): string {
    let h = 5381
    for (let i = 0; i < uri.length; i++) {
      h = ((h << 5) + h + uri.charCodeAt(i)) & 0x7FFFFFFF
    }
    return `${h}`
  }

  // 依据文件头魔数推断音频容器扩展名；扫描器按扩展名过滤，识别失败兜底 mp3。
  // 用独立 fd 顺序读，规避 ReadOptions.offset「filePointer 加偏移」的歧义语义。
  private sniffAudioExt(uri: string): string {
    const buf = new ArrayBuffer(16)
    let n = 0
    let f: fs.File | null = null
    try {
      f = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      n = fs.readSync(f.fd, buf)
    } catch (err) {
      return '.mp3'
    } finally {
      if (f !== null) {
        fs.closeSync(f)
      }
    }
    if (n < 4) {
      return '.mp3'
    }
    const b = new Uint8Array(buf)
    const ascii = (from: number, len: number): string => {
      let s = ''
      for (let i = from; i < from + len && i < n; i++) {
        s += String.fromCharCode(b[i])
      }
      return s
    }
    if (ascii(0, 4) === 'fLaC') return '.flac'
    if (ascii(0, 3) === 'ID3') return '.mp3'
    if (b[0] === 0xFF && (b[1] & 0xE0) === 0xE0) return '.mp3' // MPEG 帧同步
    if (ascii(0, 4) === 'OggS') return '.ogg'
    if (ascii(0, 4) === 'RIFF' && ascii(8, 4) === 'WAVE') return '.wav'
    if (ascii(4, 4) === 'ftyp') return '.m4a'
    if (ascii(0, 4) === 'wvpk') return '.wv'
    if (ascii(0, 4) === 'MAC ') return '.ape'
    if (ascii(0, 4) === 'FRM8') return '.dsf'
    return '.mp3'
  }
}
