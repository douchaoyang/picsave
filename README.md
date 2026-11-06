# picsave

免越狱、无根的 iOS 通用图片下载插件。把 `picsave.dylib` 用 [TrollFools](https://github.com/Lessica/TrollFools) 注入任意 App 后，长按图片就能保存到这个 App 自己的沙盒里。不需要越狱，也不依赖 CydiaSubstrate 或 ElleKit。

Rootless image downloader for any iOS app. Inject the dylib with TrollFools on TrollStore. No jailbreak.

## 适合这些场景

- 想在微信、微博、小红书、浏览器或其他 App 里长按保存图片
- 只有 TrollStore / TrollFools，没有越狱
- 需要一个可注入任意 App 的无根 dylib，而不是只对某一个 App 生效的越狱插件

## 下载

发布文件在 [Releases](../../releases)，只有 `picsave.dylib`，下载后可以直接注入。

自己发布：打开 GitHub 的 Actions，选择「构建并发布」，点击 Run workflow。版本号读取仓库里的 `VERSION`，不需要手填。完成后 Release 里会有 `picsave.dylib`，标签形如 `picsave_1.0.0#12`。

## 环境

- iOS 14 或更高版本
- 已安装 TrollStore，并用其中的 TrollFools 注入
- 不需要越狱，也不要把它装进 MobileSubstrate / ElleKit

## 注入

1. 用 TrollFools 选择要注入的 App。
2. 选择 `picsave.dylib` 注入。
3. 完全退出并重新打开该 App。

每个 App 都要单独注入一次。注入后只在这个 App 里生效。

## 使用

长按一张足够大的图片（短边至少 80pt）。屏幕底部滑出「下载 / 取消」。点「下载」后卡片收起，状态栏下方出现黑色圆角胶囊，带一圈浅灰边框，里面是绿色圆环和白色百分数。下载完成后圆环变成绿色实心圆，中间是对号，文字显示「完成」，停留 1.5 秒，再用 0.5 秒淡出。下载过程中点进度可以取消。同一时间只下载一张。

能拿到图片地址时，按原始文件保存，动图不会被压成静图。地址来自 SDWebImage、YYWebImage，或网页里的 `img` 和 CSS 背景图。没有地址时，保存的是这张 `UIImageView` 里已经显示的图片：有透明通道存成 PNG，否则存成 JPEG。这不是屏幕截图。

图标、头像和短边小于 80pt 的小图不会弹出下载卡片。

## 保存位置和文件名

文件在当前 App 沙盒的 `Documents/picsave`。目录不存在时会自动创建。

有原始名称时，名称和 6 位随机字母数字之间用 `-` 连接，例如 `banner-K7m2Qx.jpg`。没有可用的原始名称时，只有随机串和扩展名，例如 `K7m2Qx.jpg`。

用「文件」App 或文件管理工具进入该 App 的文稿目录，即可找到 `picsave`。目标 App 如果没有打开文件共享，系统「文件」App 里可能看不到这个目录，但文件仍然在沙盒中。

## 从源码构建

需要 Xcode，并带有 iOS SDK。

```bash
make
```

产物是 arm64 动态库，最低系统 iOS 14，安装名为 `@rpath/picsave.dylib`。
