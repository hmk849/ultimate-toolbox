# iOS Ultimate Toolbox

专业级原生 iOS 系统工具箱（Swift 6 + SwiftUI，iOS 26.0+，面向 iOS 27）。

四个主页面：主页（实时运行日志）、工具（缓存清理 / 文件管理 / 系统信息 / Plist 编辑 / MobileGestalt 检测 / 备份恢复）、GitHub（OAuth 登录、仓库 / Issues / PR / Releases / Actions）、设置（浅色 / 深色 / 跟随系统、强调色、语言、备份、开发者）。

## 诚实范围

- 只实现公开 API 能够真实做到的功能；做不到的模块显示真实的权限限制说明，不用假数据、模拟进度或空按钮冒充。
- MobileGestalt / 跨 App 文件访问依赖 worse_query 沙盒逃逸：iOS 27.0.1 上逃逸仍可用，27.3 beta 2 已被 Apple 修补。v1.0.0 内置兼容性检测，逃逸不可用时对应模块明确标为不可用，不强行执行。
- 备份与恢复只操作本 App 可访问范围内的真实文件，备份真实生成文件并校验完整性。

## 参考项目

- GestaltEdit — https://github.com/frs0n/GestaltEdit
- WQ Files — https://github.com/kolbicz/WQFiles
- Erosion — https://github.com/jailbreakdotparty/Erosion
- FeatureFlagEdit — https://github.com/Andytyyy383/FeatureFlagEdit
- KAMUI — https://github.com/murk-sus/kamui-escape
- LiquidGlass — https://github.com/metneo/LiquidGlass
- LiquidGlassKit — https://github.com/muhittincamdali/LiquidGlassKit

各项目的许可证见 `LICENSES.md`（待补）。

## 云编译

GitHub Actions（macos-26，自动选最新 Xcode）推送到 main 即编译，产物为未签名 IPA，LCSign 自签。

- 包名：`com.hmk849.ultimatetoolbox`
- 最低 iOS：26.0
- 签名：LCSign 须用带 App Groups 的证书（`group.com.hmk849.ultimatetoolbox`）

## 本地生成工程

```sh
brew install xcodegen
xcodegen generate
```
