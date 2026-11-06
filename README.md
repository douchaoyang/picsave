# picsave

iOS 通用图片下载插件。把 `picsave.dylib` 用 [TrollFools](https://github.com/Lessica/TrollFools) 注入，长按图片就能保存到应用自己的沙盒里，放在沙盒里的原因是因为作者不喜欢放在相册里。

Rootless image downloader for any iOS app. Inject the dylib with TrollFools.

## 适合这些场景

- 想在一些没有图片下载插件的应用里长按保存图片
- 只有 TrollStore / TrollFools，没有越狱
- 需要一个可注入任意应用的无根 dylib

## 下载

[Releases](../../releases) 下载后可以直接注入。

## 环境

- iOS 14 或更高版本
- 已安装 TrollStore，并用其中的 TrollFools 注入
- 已在小草、ONE 这两个应用的 iOS 17.0 上通过测试

## 注入

每个应用都要单独注入一次。注入后只在这个应用里生效。

## 使用

长按一张足够大的图片（短边至少 80pt）。屏幕底部滑出「下载 / 取消」。下载过程中点进度可以取消。同一时间只下载一张。
一些应用内已有长按事件的可能也不会弹出。

## 保存位置和文件名

文件在当前应用沙盒的 `Documents/picsave`。目录不存在时会自动创建。

## 从源码构建

需要 Xcode，并带有 iOS SDK。

```bash
make
```

## 免责声明

本项目仅供个人学习与研究。把动态库注入第三方应用可能违反该应用的服务条款，也可能引起闪退、功能异常或账号风险。作者不对因使用、注入或分发本插件造成的任何损失承担责任。保存下来的图片版权归原权利人所有，请在合法范围内使用。
