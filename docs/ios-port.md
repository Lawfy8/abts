# iOS 移植说明

「阿B听书」原本只有 Android 目标。本目录下的改动让同一份 Dart 代码可以在
iOS 上构建，并产出一个可用 AltStore / Sideloadly 自签安装的 `.ipa`。

## 为什么必须重新编译

Android 和 iOS 的可执行代码、UI 框架、系统 API 完全不同，改名或转换格式都
不可能得到能跑的应用。唯一可行的路径是用同一份 Flutter 源码重新构建 iOS 产物。

## 怎么出包

本机是 Windows，**无法编译 iOS**（`flutter build ios` 只能在 macOS + Xcode 上跑）。
所以走 GitHub Actions 的 macOS runner：

```bash
# 1. 把项目推到 GitHub
git add -A && git commit -m "add iOS port" && git push

# 2. 触发构建：Actions → Build iOS IPA → Run workflow
#    或者打 tag 自动构建并附到 Release
git tag v1.2.0 && git push origin v1.2.0

# 3. 下载 abts-unsigned-ipa 产物（abts-unsigned.ipa）
# 4. 用 AltStore / Sideloadly + 免费 Apple ID 自签安装
```

若你有 Mac，等价的手动流程：

```bash
flutter pub get
python3 tool/ios_bootstrap.py     # 生成 ios/ 并叠加 iOS 定制层
cd ios && pod install && cd ..
flutter build ios --release --no-codesign
# 打包
mkdir -p Payload && cp -R build/ios/iphoneos/Runner.app Payload/ && zip -qry abts-unsigned.ipa Payload
```

## 为什么用脚本生成 ios/ 而不是直接提交

`ios/Runner.xcodeproj/project.pbxproj` 与 Flutter 版本强绑定。把某个版本的
pbxproj 硬编码进仓库，Flutter 一升级就会出现难以排查的失配。

`tool/ios_bootstrap.py` 改为在构建时用 `flutter create --platforms=ios` 生成
一份**与当前 Flutter 版本完全匹配**的脚手架，再叠加 `ios_override/` 里的定制
文件。脚本是幂等的，重复运行不会叠加改动。

它做的四件事：

1. **生成脚手架** —— 仅当 `ios/Runner.xcodeproj` 不存在时；
2. **叠加定制文件** —— AppDelegate、启动屏、18 个图标条目；
3. **合并 Info.plist** —— 用 `plistlib` 合并而非覆盖，保留 Flutter 必需键
   （`UILaunchStoryboardName`、`UIApplicationSceneManifest` 等）；
4. **注入 Podfile 权限宏** —— 定点插入，不覆盖模板主体。

## Android 原生通道的 iOS 实现

原项目有 6 个走 Android 原生代码的 MethodChannel。通道名与参数契约保持不变，
由 `ios_override/Runner/AppDelegate.swift` 翻译成 iOS 等价能力，因此 Dart 侧
调用点无需按平台分叉。

| 通道 | Android | iOS 实现 | 说明 |
| --- | --- | --- | --- |
| `abts/audio_focus` | AudioManager 抢占焦点 | `AVAudioSession` setActive | 释放时 `notifyOthersOnDeactivation` 交还其他 App |
| `abts/audio_focus_events` | 焦点回调 + 拔耳机广播 | 中断通知 + 路由变更通知 | 见下方映射表 |
| `abts/gallery` | MediaStore | `PHPhotoLibrary` | 只申请 add-only 权限 |
| `abts/browser` | `Intent.ACTION_VIEW` | `UIApplication.open` | |
| `abts/storage` | `StatFs` | `volumeAvailableCapacityForImportantUsage` | |
| `abts/battery` | 电池优化豁免 | 恒返回已豁免 | iOS 无此概念，也禁止申请常驻后台 |
| `abts/cache_notify` | 前台服务通知栏进度 | 空操作 | iOS 无等价能力，安全降级 |

### 音频焦点事件映射

| 事件 | Android | iOS |
| --- | --- | --- |
| `interrupted` | `AUDIOFOCUS_LOSS_TRANSIENT` | `interruption .began` |
| `gained` | `AUDIOFOCUS_GAIN` | `interruption .ended` + `shouldResume` |
| `lost` | `AUDIOFOCUS_LOSS` | `interruption .ended` 不带 `shouldResume` |
| `ducked` | `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` | **无对应回调** |
| `noisy` | `ACTION_AUDIO_BECOMING_NOISY` | `routeChange .oldDeviceUnavailable` |

iOS 不会发出 `ducked`，音量闪避由系统完成，因此 `BookPlayer._duckVolume()`
在 iOS 上不触发——这是正确行为，不是缺失。

## 对 Dart 代码的改动

只改了 4 个文件，都是把「仅 Android」放宽为「Android + iOS」：

| 文件 | 改动 |
| --- | --- |
| `lib/services/audio_focus.dart` | `_isAndroid` → `_supported`（含 iOS） |
| `lib/services/gallery_service.dart` | 移除 `if (!Platform.isAndroid) return false`，iOS 相册写入不再被拦 |
| `lib/services/browser.dart` | 非 Android 判断放宽为「非 Android 且非 iOS」 |
| `lib/services/umeng_analytics.dart` | iOS 上显式短路（见下） |

`device_service.dart` 与 `cache_store.dart` 无需改动：它们在非 Android 平台
已经会安全降级（返回 `true` / `-1`）。

## 已处理的坑

**1. 友盟的原生依赖不能移除（一个踩过的坑）**

`umeng_common_sdk` 1.3.1 里有两个 iOS 实现文件：

- `UmengCommonSdkPlugin.swift` —— 只处理 `getPlatformVersion`，看着像空壳；
- `UmengCommonSdkPlugin.m` —— **真正参与编译的 Objective-C 实现**，开头就
  `#import <UMCommon/UMConfigure.h>` 与 `#import <UMCommon/MobClick.h>`。

最初只看了 `.swift`，误判为「iOS 端是空壳」，于是把 podspec 里的 `UMCommon`、
`UMDevice` 两条依赖注释掉了。结果 CI 的 Xcode 编译直接失败：

```
Lexical or Preprocessor Issue (Xcode):
'UMCommon/UMConfigure.h' file not found
.../umeng_common_sdk-1.3.1/ios/Classes/UmengCommonSdkPlugin.m:1:8
```

顺带发现同一个插件还有第二个问题：`.swift` 存根声明了与 `.h` **同名的类**
（`UmengCommonSdkPlugin`）。Swift 类继承 `NSObject` 且遵循 `@objc` 的
`FlutterPlugin` 协议，因此对 Objective-C 可见，Xcode 于是报：

```
Semantic Issue (Xcode):
Duplicate interface definition for class 'UmengCommonSdkPlugin'
```

**处理方式**（bootstrap 自动完成，均已在 CI 验证）：

1. 保留 `UMCommon` / `UMDevice` 两条依赖不动；
2. 把 podspec 的 `source_files` 收窄为 `Classes/**/*.{h,m}`，并
   `s.exclude_files = 'Classes/**/*.swift'` 排除那个存根。
   `.m` 覆盖了 Dart 侧用到的全部方法（含 `registerWithRegistrar:`），
   不会丢功能。

**2. iOS 图标不允许带 alpha 通道**

`assets/logo.png` 是 RGBA。生成脚本把 logo 合成到它自身的深蓝底色上并压平成
RGB，否则 App Store 校验会直接拒绝。

**3. `permission_handler` 的宏必须显式打开**

不打开对应宏时插件**静默返回 denied**（不报错），很容易被误判成用户拒绝授权。
Podfile 里显式写了 `PERMISSION_PHOTOS=1`，其余全部 `=0`。

**4. 启动时 `window` 可能为 nil**

新版 Flutter 的 iOS 模板改用 UIScene 生命周期，启动时 `window` 尚未就绪。
AppDelegate 改为通过 `registrar(forPlugin:)` 取 messenger，不依赖 window。

**5. 部署目标**

`permission_handler` 与 Flutter 3.38 都要求 iOS 13+；脚本会从生成的工程里
探测 `IPHONEOS_DEPLOYMENT_TARGET` 并取与 13.0 的较大者。

## 功能在 iOS 上的差异

| 功能 | iOS 表现 |
| --- | --- |
| 后台播放 / 锁屏控制 / 耳机按键 | ✅ 由 `audio_service` 提供 |
| 来电打断暂停并自动续播 | ✅ |
| 拔耳机自动暂停 | ✅ |
| 倍速、连播、断点续播、睡眠定时 | ✅ 纯 Dart，与平台无关 |
| 离线缓存（文件） | ✅ 文件下载在 Dart 层 |
| **缓存进度通知栏** | ❌ iOS 无前台服务通知，降级为 App 内 UI |
| **电池优化豁免引导** | ❌ 恒返回已豁免，不显示引导 |
| **友盟统计** | ❌ iOS 上跳过初始化（代码里的 AppKey 是 Android 专用的） |
| 保存二维码到相册 | ✅ 需用户授权相册写入 |

## 自签安装须知

- CI 产出的是**未签名** ipa，无法直接装到未越狱设备，这是 iOS 的机制限制。
- 免费 Apple ID 签名的有效期是 **7 天**，到期需重新签名。
- 免费账号同时最多签 3 个 App。
- 应用名显示为「阿B听书」，Bundle ID 为 `dev.pages.abts`（与 Android 一致）。

## 自检

`tool/ios_bootstrap.py` 末尾带自检：确认工程文件齐全、7 个通道都已实现、
Podfile 权限宏到位、`UIBackgroundModes` 含 `audio`、显示名正确。任一不满足
即以非零码退出，CI 会直接失败而不会产出一个装不上的包。
