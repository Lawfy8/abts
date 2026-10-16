#!/usr/bin/env python3
"""为「阿B听书」生成可构建的 ios/ 工程。

设计原则：**绝不改动项目已有文件**。

1. 用 `flutter create` 在临时目录里生成一份与当前 Flutter 版本完全匹配的
   iOS 脚手架（而不是把某个版本的 project.pbxproj 硬编码进仓库——那样
   Flutter 一升级就会失配），只把它产出的 `ios/` 拷进来；
2. 再叠加 `ios_override/` 里的 iOS 定制文件；
3. Info.plist 用 plistlib 做**合并**而不是覆盖，保留 Flutter 必需键；
4. Podfile 若已存在则做**定点注入**，避免覆盖掉新版 Flutter 模板的改动。

在 Mac 上与在 GitHub Actions 上用法一致：

    python3 tool/ios_bootstrap.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OVERRIDE_DIR = PROJECT_ROOT / "ios_override"
IOS_DIR = PROJECT_ROOT / "ios"
RUNNER_DIR = IOS_DIR / "Runner"

# 与 android/app/build.gradle.kts 的 applicationId 保持一致
ORG = "dev.pages"
PROJECT_NAME = "abts"

# Flutter 3.38 的 iOS 下限；实际值会从生成的工程里探测后取较大者
FALLBACK_DEPLOYMENT_TARGET = "13.0"

# permission_handler 的编译期开关。不显式打开对应宏时，插件会**静默返回
# denied**（不报错），很容易被误判成「用户拒绝了权限」，所以必须写死。
PERMISSION_MACROS = [
    "'$(inherited)'",
    "'PERMISSION_PHOTOS=1'",  # 保存登录二维码到相册
    "'PERMISSION_EVENTS=0'",
    "'PERMISSION_EVENTS_FULL_ACCESS=0'",
    "'PERMISSION_REMINDERS=0'",
    "'PERMISSION_CONTACTS=0'",
    "'PERMISSION_CAMERA=0'",
    "'PERMISSION_MICROPHONE=0'",
    "'PERMISSION_SPEECH_RECOGNIZER=0'",
    "'PERMISSION_LOCATION=0'",
    "'PERMISSION_NOTIFICATIONS=0'",
    "'PERMISSION_MEDIA_LIBRARY=0'",
    "'PERMISSION_SENSORS=0'",
    "'PERMISSION_BLUETOOTH=0'",
    "'PERMISSION_APP_TRACKING_TRANSPARENCY=0'",
    "'PERMISSION_CRITICAL_ALERTS=0'",
    "'PERMISSION_ASSISTANT=0'",
]

DEPLOYMENT_TARGET_RE = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)\s*;")
PLATFORM_LINE_RE = re.compile(r"^\s*platform\s+:ios\s*,.*$", re.MULTILINE)


def log(message: str) -> None:
    print(f"\033[1;36m==>\033[0m {message}", flush=True)


def warn(message: str) -> None:
    print(f"\033[1;33m[!]\033[0m {message}", flush=True)


def die(message: str) -> None:
    print(f"\033[1;31m[x]\033[0m {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(args: list[str], cwd: Path | None = None) -> None:
    log(" ".join(args))
    subprocess.run(args, cwd=cwd, check=True)


# ---------------------------------------------------------------- 脚手架


def scaffold_if_needed() -> None:
    """ios/ 不存在时，用临时工程生成一份版本匹配的脚手架。"""
    if (IOS_DIR / "Runner.xcodeproj").exists():
        log("ios/Runner.xcodeproj 已存在，跳过脚手架生成")
        return

    tmp_root = Path(tempfile.mkdtemp(prefix="abts-ios-scaffold-"))
    try:
        run(
            [
                "flutter",
                "create",
                "--platforms=ios",
                "--org",
                ORG,
                "--project-name",
                PROJECT_NAME,
                "--template=app",
                str(tmp_root),
            ]
        )
        generated = tmp_root / "ios"
        if not (generated / "Runner.xcodeproj").exists():
            die(f"flutter create 未生成 ios 工程：{generated}")
        shutil.copytree(generated, IOS_DIR)
        log(f"已生成 ios/（{ORG}.{PROJECT_NAME}）")
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)


# ---------------------------------------------------------------- 覆盖层


def overlay_runner_files() -> None:
    """叠加 AppDelegate / 启动屏 / 图标。"""
    log("叠加 iOS 定制文件")

    app_delegate_src = OVERRIDE_DIR / "Runner" / "AppDelegate.swift"
    if not app_delegate_src.exists():
        die(f"缺少 {app_delegate_src}")
    shutil.copy2(app_delegate_src, RUNNER_DIR / "AppDelegate.swift")

    storyboard_src = OVERRIDE_DIR / "Runner" / "Base.lproj" / "LaunchScreen.storyboard"
    storyboard_dst = RUNNER_DIR / "Base.lproj" / "LaunchScreen.storyboard"
    storyboard_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(storyboard_src, storyboard_dst)

    assets_src = OVERRIDE_DIR / "Runner" / "Assets.xcassets"
    assets_dst = RUNNER_DIR / "Assets.xcassets"
    copied = 0
    for src in sorted(assets_src.rglob("*")):
        if not src.is_file():
            continue
        dst = assets_dst / src.relative_to(assets_src)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1
    log(f"  AppDelegate.swift / LaunchScreen.storyboard / {copied} 个图标资源")


def merge_info_plist() -> None:
    """把定制键合并进生成的 Info.plist，保留 Flutter 必需键。"""
    import plistlib

    log("合并 Info.plist")

    target = RUNNER_DIR / "Info.plist"
    overlay = OVERRIDE_DIR / "Runner" / "Info.plist"
    if not target.exists():
        die(f"未找到 {target}")

    with target.open("rb") as fh:
        merged = plistlib.load(fh)
    with overlay.open("rb") as fh:
        custom = plistlib.load(fh)

    before = set(merged)
    merged.update(custom)

    # 兜底：只补「对应文件确实存在」的键。
    # 若模板改用 UIScene 生命周期而不再提供 Main.storyboard，硬塞
    # UIMainStoryboardFile 会让 App 启动即崩溃——所以按文件存在性决定。
    # LaunchScreen.storyboard 由本脚本自己铺上，因此总是安全。
    defaults = {"LSRequiresIPhoneOS": True}
    if (RUNNER_DIR / "Base.lproj" / "LaunchScreen.storyboard").exists():
        defaults["UILaunchStoryboardName"] = "LaunchScreen"
    if (RUNNER_DIR / "Base.lproj" / "Main.storyboard").exists():
        defaults["UIMainStoryboardFile"] = "Main"

    restored = []
    for key, value in defaults.items():
        if key not in merged:
            merged[key] = value
            restored.append(key)

    # 反向清理：模板若不再带 Main.storyboard，删掉可能残留的失效键
    if not (RUNNER_DIR / "Base.lproj" / "Main.storyboard").exists():
        if merged.pop("UIMainStoryboardFile", None) is not None:
            warn("  模板无 Main.storyboard，已移除 UIMainStoryboardFile（否则启动崩溃）")

    with target.open("wb") as fh:
        plistlib.dump(merged, fh)

    added = sorted(set(custom) - before)
    log(f"  新增 {len(added)} 个键，覆盖 {len(set(custom) & before)} 个：{', '.join(added)}")
    if restored:
        warn(f"  模板缺少 {', '.join(restored)}，已补回默认值")

    if merged.get("UIBackgroundModes") != ["audio"]:
        warn("UIBackgroundModes 不含 audio，锁屏/后台播放会失效")


# ---------------------------------------------------------------- Podfile


def detect_deployment_target() -> str:
    """从生成的工程里读出 iOS 部署目标，取它与下限中的较大者。"""
    pbxproj = IOS_DIR / "Runner.xcodeproj" / "project.pbxproj"
    found = [float(v) for v in DEPLOYMENT_TARGET_RE.findall(pbxproj.read_text(encoding="utf-8"))]
    project_value = max(found) if found else float(FALLBACK_DEPLOYMENT_TARGET)
    target = max(project_value, float(FALLBACK_DEPLOYMENT_TARGET))
    # 保持 "13.0" 这种形式，避免出现 13 或 13.00
    return f"{target:.1f}"


def permission_block(indent: str) -> str:
    lines = [f"{indent}config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ["]
    lines += [f"{indent}  {macro}," for macro in PERMISSION_MACROS]
    lines.append(f"{indent}]")
    return "\n".join(lines) + "\n"


def ensure_podfile() -> None:
    """注入权限宏；若 Podfile 非标准则整份写入。"""
    target = IOS_DIR / "Podfile"
    deployment = detect_deployment_target()
    log(f"配置 Podfile（iOS 部署目标 {deployment}）")

    if not target.exists():
        log("  未生成 Podfile，写入标准模板")
        _write_podfile_from_template(target, deployment)
        return

    content = target.read_text(encoding="utf-8")

    # 模板异常时整份替换，避免在未知结构上做正则
    if "flutter_additional_ios_build_settings" not in content:
        warn("  生成的 Podfile 结构不符合预期，改用标准模板")
        _write_podfile_from_template(target, deployment)
        return

    if PLATFORM_LINE_RE.search(content):
        content = PLATFORM_LINE_RE.sub(f"platform :ios, '{deployment}'", content, count=1)
    else:
        content = f"platform :ios, '{deployment}'\n" + content

    if "PERMISSION_PHOTOS" in content:
        log("  权限宏已存在，跳过注入")
    else:
        anchor = "flutter_additional_ios_build_settings(target)"
        idx = content.index(anchor) + len(anchor)
        # 缩进对齐锚点所在行，纯为可读性；Ruby 不关心
        line_start = content.rfind("\n", 0, content.index(anchor)) + 1
        indent = re.match(r"[ \t]*", content[line_start:]).group(0)
        content = content[:idx] + "\n" + permission_block(indent) + content[idx:]
        log(f"  已注入 {len(PERMISSION_MACROS)} 条权限宏")

    target.write_text(content, encoding="utf-8")


def _write_podfile_from_template(target: Path, deployment: str) -> None:
    template = (OVERRIDE_DIR / "Podfile").read_text(encoding="utf-8")
    template = PLATFORM_LINE_RE.sub(f"platform :ios, '{deployment}'", template, count=1)
    target.write_text(template, encoding="utf-8")


# ---------------------------------------------------------------- 友盟瘦身


def patch_umeng_podspec() -> None:
    """修正 umeng 插件在 iOS 上的两处问题。

    插件的 `ios/Classes/` 下同时存在三个文件：

        UmengCommonSdkPlugin.h      声明 @interface UmengCommonSdkPlugin
        UmengCommonSdkPlugin.m      实现该类（initCommon / onEvent /
                                    onPageStart / onPageEnd / reportError
                                    等全部逻辑都在这里）
        UmengCommonSdkPlugin.swift  又声明了同名的 Swift 类

    **问题 1：不能移除原生依赖。**
    `.m` 开头就是 `#import <UMCommon/UMConfigure.h>`，把 podspec 里的
    UMCommon / UMDevice 去掉会让 Xcode 报：
        'UMCommon/UMConfigure.h' file not found
    -> 保持依赖原样。

    **问题 2：Swift 存根与 ObjC 实现重名。**
    Swift 类继承 NSObject 且遵循 @objc 的 FlutterPlugin 协议，因此对
    ObjC 可见，与 `.h` 里的 @interface 冲突，Xcode 报：
        Semantic Issue (Xcode):
        Duplicate interface definition for class 'UmengCommonSdkPlugin'
    -> 把 source_files 收窄为 .h/.m 并排除 .swift。
       `.m` 已覆盖 Dart 侧用到的全部方法，不会丢功能；Flutter 生成的
       registrant 调用的 `registerWithRegistrar:` 也在 `.m` 里。
    """
    deps_json = PROJECT_ROOT / ".flutter-plugins-dependencies"
    if not deps_json.exists():
        warn("未找到 .flutter-plugins-dependencies，跳过 umeng podspec 修正")
        return

    import json

    try:
        data = json.loads(deps_json.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        warn(f"解析 .flutter-plugins-dependencies 失败，跳过：{exc}")
        return

    plugin_root: Path | None = None
    for plugin in data.get("plugins", {}).get("ios", []):
        if plugin.get("name") == "umeng_common_sdk":
            path = plugin.get("path")
            if path:
                plugin_root = Path(path)
            break

    if plugin_root is None:
        log("  iOS 插件列表中没有 umeng_common_sdk，跳过")
        return

    podspec = plugin_root / "ios" / "umeng_common_sdk.podspec"
    if not podspec.exists():
        warn(f"未找到 {podspec}，跳过")
        return

    content = podspec.read_text(encoding="utf-8")

    if "[abts-ios]" in content:
        log("  umeng podspec 已修正过，跳过")
        return

    # 只在确认「同名冲突」真实存在时才动手，避免又一次误判
    swift_file = plugin_root / "ios" / "Classes" / "UmengCommonSdkPlugin.swift"
    objc_header = plugin_root / "ios" / "Classes" / "UmengCommonSdkPlugin.h"
    objc_impl = plugin_root / "ios" / "Classes" / "UmengCommonSdkPlugin.m"

    if not (swift_file.exists() and objc_header.exists() and objc_impl.exists()):
        log("  umeng 插件结构与预期不同（缺少 .swift/.h/.m 之一），不做改动")
        return

    header_text = objc_header.read_text(encoding="utf-8", errors="replace")
    swift_text = swift_file.read_text(encoding="utf-8", errors="replace")
    if "UmengCommonSdkPlugin" not in header_text or "UmengCommonSdkPlugin" not in swift_text:
        log("  未确认到同名类，不做改动")
        return

    old_line = "  s.source_files = 'Classes/**/*'"
    if old_line not in content:
        warn("  podspec 的 source_files 行与预期不符，未做改动")
        warn(f"    期望: {old_line!r}")
        return

    new_block = (
        "  s.source_files = 'Classes/**/*.{h,m}'\n"
        "  # [abts-ios] Exclude the Swift stub. It declares the same class as\n"
        "  # UmengCommonSdkPlugin.h/.m, and Swift classes deriving from NSObject\n"
        "  # that conform to the @objc FlutterPlugin protocol are visible to\n"
        "  # Objective-C, so Xcode fails with:\n"
        "  #   Duplicate interface definition for class 'UmengCommonSdkPlugin'\n"
        "  # The .m implementation covers every method the Dart side uses.\n"
        "  s.exclude_files = 'Classes/**/*.swift'"
    )

    podspec.write_text(content.replace(old_line, new_block, 1), encoding="utf-8")
    log("  已排除 umeng 的 Swift 存根（与 .h 同名导致 Xcode 重复定义）")
    log(f"    {podspec}")


# ---------------------------------------------------------------- 主流程


def verify() -> None:
    """收尾自检：关键文件与关键配置是否都到位。"""
    log("自检")
    problems: list[str] = []

    required = [
        IOS_DIR / "Runner.xcodeproj" / "project.pbxproj",
        RUNNER_DIR / "AppDelegate.swift",
        RUNNER_DIR / "Info.plist",
        RUNNER_DIR / "Base.lproj" / "LaunchScreen.storyboard",
        RUNNER_DIR / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json",
        IOS_DIR / "Podfile",
    ]
    for path in required:
        if not path.exists():
            problems.append(f"缺少 {path.relative_to(PROJECT_ROOT)}")

    app_delegate = (RUNNER_DIR / "AppDelegate.swift").read_text(encoding="utf-8")
    for channel in (
        "abts/audio_focus",
        "abts/audio_focus_events",
        "abts/gallery",
        "abts/browser",
        "abts/cache_notify",
        "abts/storage",
        "abts/battery",
    ):
        if channel not in app_delegate:
            problems.append(f"AppDelegate 未实现通道 {channel}")

    podfile = (IOS_DIR / "Podfile").read_text(encoding="utf-8")
    if "PERMISSION_PHOTOS=1" not in podfile:
        problems.append("Podfile 缺少 PERMISSION_PHOTOS=1")

    import plistlib

    with (RUNNER_DIR / "Info.plist").open("rb") as fh:
        plist = plistlib.load(fh)
    if plist.get("UIBackgroundModes") != ["audio"]:
        problems.append("Info.plist 的 UIBackgroundModes 不是 audio")
    if "NSPhotoLibraryAddUsageDescription" not in plist:
        problems.append("Info.plist 缺少 NSPhotoLibraryAddUsageDescription")
    if plist.get("CFBundleDisplayName") != "阿B听书":
        problems.append("Info.plist 的 CFBundleDisplayName 不是「阿B听书」")

    if problems:
        for problem in problems:
            warn(problem)
        die(f"自检未通过（{len(problems)} 项）")

    log("自检通过")


def main() -> None:
    if shutil.which("flutter") is None:
        die("PATH 中找不到 flutter，请先安装 Flutter SDK")

    log(f"项目根目录 {PROJECT_ROOT}")
    scaffold_if_needed()
    overlay_runner_files()
    merge_info_plist()
    ensure_podfile()
    patch_umeng_podspec()
    verify()

    print()
    log("iOS 工程就绪。后续步骤：")
    print("    flutter pub get")
    print("    flutter build ios --release --no-codesign")
    print()
    print("  产物：build/ios/iphoneos/Runner.app")
    print("  打包未签名 ipa：")
    print("    mkdir -p Payload && cp -R build/ios/iphoneos/Runner.app Payload/")
    print("    zip -qry abts-unsigned.ipa Payload")


if __name__ == "__main__":
    main()
