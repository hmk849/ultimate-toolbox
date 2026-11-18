# 开源许可说明

## 本 App：MIT

Ultimate Toolbox 本体（Swift 代码、UI、服务层、预设表）采用 MIT 许可证，见仓库根目录 `LICENSE`。

## 逃逸引擎：KAMUI（MIT）

`Sources/UltimateToolbox/Engine/BQCore.h`、`BQCore.m`、`respring.html` 源自
[murk-sus/kamui-escape](https://github.com/murk-sus/kamui-escape)（MIT License，
Copyright (c) 2026 KAMUI contributors），按原许可证保留使用。

对上游代码的唯一改动：`BQCore.m` 第 2 行把 `#import "BQUI.h"` 换成自写的最小桩
`BQStub.h`（只提供 `BQLocalizedString`，KAMUI 的 `BQUI.m` 未使用）。

## 预设键表

`Models/MGPreset.swift` 为作者自写整理。表中的哈希键是 MobileGestalt 缓存键名
经哈希得到的标识符（实现互通必需的功能性数据）；键值映射参考了 KAMUI（MIT）
与 GestaltEdit / Erosion 的公开资料，未复制其源码。

## 启发来源（代码未直接使用）

- GestaltEdit（GPL-3.0）— https://github.com/frs0n/GestaltEdit
- WQ Files（GPL-3.0）— https://github.com/kolbicz/WQFiles
- Erosion（GPL-3.0）— https://github.com/jailbreakdotparty/Erosion
- FeatureFlagEdit（MIT）— https://github.com/Andytyyy383/FeatureFlagEdit
- LiquidGlass（MIT）— https://github.com/metneo/LiquidGlass
- LiquidGlassKit（MIT）— https://github.com/muhittincamdali/LiquidGlassKit

上述 GPL 项目的代码没有直接复制进本 App，因此本 App 不受 GPL 约束。
若日后直接引入其中任何一家的源码，须按其许可证要求同步开源并标注。
