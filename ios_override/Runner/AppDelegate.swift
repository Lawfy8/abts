import AVFoundation
import Flutter
import Photos
import UIKit

/// iOS 宿主：为 Dart 侧那 6 个 Android 原生通道提供 iOS 等价实现。
///
/// 通道名与参数契约和 `android/app/src/main/kotlin/dev/pages/abts/MainActivity.kt`
/// 完全一致，因此 Dart 层不需要按平台分叉调用点：
///
/// | 通道 | Android 实现 | 这里的 iOS 实现 |
/// | --- | --- | --- |
/// | `abts/audio_focus` | AudioManager 抢占焦点 | AVAudioSession 激活/释放 |
/// | `abts/audio_focus_events` | 焦点回调 + 拔耳机广播 | 中断通知 + 路由变更通知 |
/// | `abts/gallery` | MediaStore 写入相册 | PHPhotoLibrary 写入相册 |
/// | `abts/browser` | Intent.ACTION_VIEW | UIApplication.open |
/// | `abts/storage` | StatFs | volumeAvailableCapacityForImportantUsage |
/// | `abts/battery` | 电池优化豁免 | 无此概念，恒为已豁免 |
/// | `abts/cache_notify` | 前台服务通知栏进度 | 无等价能力，安全空操作 |
@main
@objc class AppDelegate: FlutterAppDelegate {

  private enum Channel {
    static let audioFocus = "abts/audio_focus"
    static let audioFocusEvents = "abts/audio_focus_events"
    static let gallery = "abts/gallery"
    static let browser = "abts/browser"
    static let cacheNotify = "abts/cache_notify"
    static let storage = "abts/storage"
    static let battery = "abts/battery"
  }

  /// 音频焦点事件回传 Dart（与 Android EventChannel 同名同值）
  private var focusSink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 通过 registrar 拿 messenger，而不是 `window?.rootViewController`：
    // 新版 Flutter 模板改用 UIScene 生命周期，启动时 window 可能还是 nil，
    // 那样基于 window 的写法会让下面所有通道静默注册不上。
    //
    // 显式标注成 Optional 再解包：`registrarForPlugin:` 在不同 Flutter 版本里
    // 可能被标注为 nullable 也可能没有，这样写两种签名都能编译。
    let maybeRegistrar: FlutterPluginRegistrar? = self.registrar(forPlugin: "AbtsChannels")
    if let registrar = maybeRegistrar {
      let messenger = registrar.messenger()
      registerAudioFocus(messenger)
      registerAudioFocusEvents(messenger)
      registerGallery(messenger)
      registerBrowser(messenger)
      registerCacheNotify(messenger)
      registerStorage(messenger)
      registerBattery(messenger)
    } else {
      NSLog("[abts] 未能取得 plugin registrar，原生通道未注册")
    }

    // 启动即声明「后台播放」，否则退到后台或锁屏会立刻静音
    configureAudioSession()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - 音频会话

  /// 有声书场景：`.playback` + `.spokenAudio`，允许后台出声、不静音开关机键。
  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, options: [])
    } catch {
      // 个别机型不接受 .spokenAudio，退回默认模式
      try? session.setCategory(.playback, mode: .default, options: [])
    }
  }

  private func activateSession() -> Bool {
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      return true
    } catch {
      return false
    }
  }

  private func deactivateSession() {
    // notifyOthersOnDeactivation：把被我们抢占的音乐 App 交还回去，
    // 对应 Android 的 abandonAudioFocus
    try? AVAudioSession.sharedInstance()
      .setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func registerAudioFocus(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.audioFocus, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "request":
        result(self?.activateSession() ?? false)
      case "abandon":
        self?.deactivateSession()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerAudioFocusEvents(_ messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: Channel.audioFocusEvents, binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  fileprivate func startObservingAudioSession() {
    stopObservingAudioSession()
    let center = NotificationCenter.default

    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
      ) { [weak self] note in
        self?.handleInterruption(note)
      })

    // 拔耳机 / 断开蓝牙：对应 Android 的 ACTION_AUDIO_BECOMING_NOISY
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] note in
        self?.handleRouteChange(note)
      })
  }

  fileprivate func stopObservingAudioSession() {
    let center = NotificationCenter.default
    observers.forEach { center.removeObserver($0) }
    observers.removeAll()
  }

  /// 来电/其它 App 抢占 → `interrupted`；恢复 → `gained`；不恢复 → `lost`。
  ///
  /// iOS 没有 Android 那种「短暂闪避」回调，所以不会发出 `ducked`；
  /// Dart 侧的音量压低逻辑在 iOS 上自然不触发（系统自己会 duck）。
  private func handleInterruption(_ note: Notification) {
    guard let info = note.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }

    switch type {
    case .began:
      focusSink?("interrupted")
    case .ended:
      let rawOptions = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
      focusSink?(options.contains(.shouldResume) ? "gained" : "lost")
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ note: Notification) {
    guard let info = note.userInfo,
      let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
    else { return }

    if reason == .oldDeviceUnavailable {
      focusSink?("noisy")
    }
  }

  // MARK: - 相册

  private func registerGallery(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.gallery, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "sdkInt":
        // iOS 没有 API 等级概念；返回 0 让 Dart 侧跳过「Android 9 存储权限」分支
        result(0)
      case "saveImage":
        guard let args = call.arguments as? [String: Any],
          let base64 = args["base64"] as? String,
          let data = Data(base64Encoded: base64)
        else {
          result(nil)
          return
        }
        let name = (args["name"] as? String) ?? "image"
        AppDelegate.saveImageToAlbum(data: data, name: name, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 写入系统相册。
  ///
  /// `authorizationStatus(for:)` / `requestAuthorization(for:)` 是 iOS 14+ API，
  /// 而本工程部署目标是 13.0，直接调用会编译失败，因此按版本分支：
  /// iOS 14+ 只申请 add-only 权限（不需要读取整个照片库）；
  /// iOS 13 没有 add-only 概念，退回旧的全量授权接口。
  private static func saveImageToAlbum(
    data: Data,
    name: String,
    result: @escaping FlutterResult
  ) {
    let performSave = {
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name.hasSuffix(".png") ? name : "\(name).png"
        request.addResource(with: .photo, data: data, options: options)
      } completionHandler: { success, _ in
        DispatchQueue.main.async {
          // Dart 侧只判断「非空即成功」，返回占位标识即可。
          // 不用三元表达式，避免 Swift 在 Any? 上下文里对 nil 分支推断歧义。
          if success {
            result("saved")
          } else {
            result(nil)
          }
        }
      }
    }

    if #available(iOS 14, *) {
      switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
      case .authorized, .limited:
        performSave()
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          DispatchQueue.main.async {
            if status == .authorized || status == .limited {
              performSave()
            } else {
              result(nil)
            }
          }
        }
      default:
        result(nil)
      }
    } else {
      switch PHPhotoLibrary.authorizationStatus() {
      case .authorized:
        performSave()
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization { status in
          DispatchQueue.main.async {
            if status == .authorized {
              performSave()
            } else {
              result(nil)
            }
          }
        }
      default:
        result(nil)
      }
    }
  }

  // MARK: - 外部链接

  private func registerBrowser(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.browser, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let urlString = args["url"] as? String,
        let url = URL(string: urlString),
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
      else {
        result(false)
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
      }
    }
  }

  // MARK: - 离线缓存通知

  /// iOS 没有「前台服务 + 常驻进度通知」这种能力：
  /// 下载进度由 App 内 UI 与 Now Playing 承担。这里保持空操作，
  /// 让 Dart 侧同一套调用在 iOS 上安全退化为无提示。
  private func registerCacheNotify(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.cacheNotify, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update", "cancel":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - 存储空间

  private func registerStorage(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.storage, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "freeBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(AppDelegate.freeBytes())
    }
  }

  private static func freeBytes() -> Int64 {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let capacity = values.volumeAvailableCapacityForImportantUsage
    {
      return Int64(capacity)
    }
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
      let size = attrs[.systemFreeSize] as? NSNumber
    {
      return size.int64Value
    }
    return -1
  }

  // MARK: - 电池优化

  /// iOS 没有「电池优化白名单」概念，也禁止 App 申请常驻后台。
  /// 恒返回「已豁免」，避免 Dart 侧弹出无意义的引导页。
  private func registerBattery(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Channel.battery, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isIgnoring":
        result(true)
      case "requestIgnore":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - EventChannel

extension AppDelegate: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    focusSink = events
    startObservingAudioSession()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    focusSink = nil
    stopObservingAudioSession()
    return nil
  }
}
