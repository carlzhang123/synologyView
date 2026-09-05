# SynologyView

SynologyView 是一个 iOS SwiftUI 项目，用来浏览 Synology File Station 文件并播放/预览媒体。

## 迁移到新电脑

### 1. 安装 Xcode

先从 App Store 安装 Xcode，并至少打开一次完成初始化。

如果命令行工具没有自动配置，执行：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

### 2. 安装 Homebrew

如果新电脑还没有 Homebrew，执行：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

安装完成后，按终端提示把 `brew` 加到 shell 环境里。Apple Silicon Mac 通常是：

```sh
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Intel Mac 通常是：

```sh
echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/usr/local/bin/brew shellenv)"
```

确认安装：

```sh
brew --version
```

### 3. 安装 CocoaPods

项目使用 CocoaPods 管理 `MobileVLCKit`。推荐用 Homebrew 安装：

```sh
brew install cocoapods
pod --version
```

当前 `Podfile.lock` 记录的 CocoaPods 版本是 `1.17.0`。如果版本略有不同通常也能工作；如果遇到依赖解析差异，再切到 lock 文件对应版本。

### 4. 拉取项目

```sh
git clone https://github.com/carlzhang123/synologyView.git
cd synologyView
```

### 5. 安装 MobileVLCKit

不要手动提交或复制 `Pods/` 目录。仓库只保存 `Podfile` 和 `Podfile.lock`，新电脑上执行：

```sh
pod install
```

这个命令会根据 `Podfile.lock` 安装：

```text
MobileVLCKit 3.7.3
```

如果下载失败，可以先更新本地 spec repo 后重试：

```sh
pod repo update
pod install
```

如果 CocoaPods 提示 sandbox/script 相关问题，确认 `Podfile` 里保留了这个配置：

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end
```

### 6. 用 workspace 打开项目

安装 Pods 后，一定打开 workspace，不要打开 `.xcodeproj`：

```sh
open SynologyView.xcworkspace
```

在 Xcode 里选择 `SynologyView` scheme，然后 build/run。

## 常见问题

### 找不到 MobileVLCKit

确认不是打开了 `SynologyView.xcodeproj`。使用 CocoaPods 后必须打开：

```text
SynologyView.xcworkspace
```

如果仍然找不到，重新执行：

```sh
pod install
```

### GitHub 不接受 Pods 里的大文件

`MobileVLCKit.xcframework` 里有超过 GitHub 普通仓库限制的大二进制文件，所以 `Pods/` 已加入 `.gitignore`。这是预期行为。

迁移电脑时使用：

```sh
pod install
```

而不是把 `Pods/` 提交到 GitHub。

### 清理并重装 Pods

如果依赖状态混乱，可以执行：

```sh
rm -rf Pods
rm -f Pods/Manifest.lock
pod install
```

然后重新打开：

```sh
open SynologyView.xcworkspace
```

## 当前依赖

- iOS deployment target: `15.0`
- CocoaPods: `1.17.0`
- MobileVLCKit: `3.7.3`

