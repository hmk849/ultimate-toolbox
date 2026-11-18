import Foundation

/// MobileGestalt 预设表（作者自写）。
/// 键为 CacheExtra 字典的哈希键（Apple 键名的哈希值，是实现互通必需的功能性标识符；
/// 键值映射参考 KAMUI（MIT）与 GestaltEdit / Erosion 的公开资料；本表为重新整理，未复制其源码）。
/// 重要诚实说明：这些键只是向系统"宣称"具备某能力，不代表硬件/服务端一定生效。

enum MGPresetRisk {
    case normal
    case high(String)  // 高危说明
}

struct MGPresetKey {
    let key: String
    let value: PlistValue
}

struct MGPreset: Identifiable {
    let id: String
    let name: String
    let nameEn: String
    let description: String
    let keys: [MGPresetKey]
    let minOSMajor: Int
    let risk: MGPresetRisk
    /// 互斥组：同组内只能选一个（如 Liquid Glass 性能模式 开/关）。
    let conflictGroup: String?

    var displayName: String { L10n.isEnglish ? nameEn : name }
}

enum MGPresets {
    static let all: [MGPreset] = [
        MGPreset(
            id: "dynamic-island", name: "灵动岛", nameEn: "Dynamic Island",
            description: "在不支持的机型上显示灵动岛。子类型决定岛的尺寸，请按机型选择；仅宣称能力，硬件没有则无实际效果。",
            keys: [MGPresetKey(key: "YlEtTtHlNesRBMal1CqRaA", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "aod", name: "息屏显示（AOD）", nameEn: "Always-On Display",
            description: "开启息屏显示。仅宣称能力，屏幕硬件不支持则无实际效果。",
            keys: [
                MGPresetKey(key: "2OOJf1VhaM7NxfRok3HbWQ", value: .integer(1)),
                MGPresetKey(key: "j8/Omm6s1lsmTDFsXjsBfA", value: .integer(1)),
            ],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "aod-vivid", name: "AOD 鲜艳显示", nameEn: "Vivid AOD",
            description: "息屏显示更鲜艳的色彩。",
            keys: [MGPresetKey(key: "ykpu7qyhqFweVMKtxNylWA", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "aod-brighter", name: "更亮的 AOD", nameEn: "Brighter AOD",
            description: "息屏显示更亮。仅 iOS 27+。",
            keys: [MGPresetKey(key: "7brdL5xrEUWnlF9C0kdg5A", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "aod-widgets", name: "AOD 小组件", nameEn: "AOD Widgets",
            description: "在息屏显示上显示小组件。",
            keys: [MGPresetKey(key: "aoJSd/MXk7M40NgXTM6x+g", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "lg-low", name: "Liquid Glass 低性能模式", nameEn: "Liquid Glass Low Power",
            description: "降低 Liquid Glass 渲染开销。与“标准性能模式”互斥。",
            keys: [MGPresetKey(key: "SAGvsp6O6kAQ4fEfDJpC4Q", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: "liquid-glass"
        ),
        MGPreset(
            id: "lg-std", name: "Liquid Glass 标准性能模式", nameEn: "Liquid Glass Standard",
            description: "恢复 Liquid Glass 标准渲染。与“低性能模式”互斥。",
            keys: [MGPresetKey(key: "SAGvsp6O6kAQ4fEfDJpC4Q", value: .integer(0))],
            minOSMajor: 27, risk: .normal, conflictGroup: "liquid-glass"
        ),
        MGPreset(
            id: "parallax-off", name: "关闭壁纸视差", nameEn: "Disable Wallpaper Parallax",
            description: "关闭主屏幕壁纸视差效果。",
            keys: [MGPresetKey(key: "UIParallaxCapability", value: .integer(0))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "boot-chime", name: "开关机提示音", nameEn: "Boot Chime",
            description: "开机与关机时播放提示音。",
            keys: [MGPresetKey(key: "QHxt+hGLaBPbQJbXiUJX3w", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "charge-limit", name: "充电上限菜单", nameEn: "Charge Limit Menu",
            description: "在设置中显示充电上限选项。仅出菜单，真正的限流取决于硬件。",
            keys: [MGPresetKey(key: "37NVydb//GP/GrhuTN+exg", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "tap-to-wake", name: "轻点唤醒", nameEn: "Tap to Wake",
            description: "轻点屏幕唤醒设备。",
            keys: [MGPresetKey(key: "yZf3GTRMGTuwSV/lD7Cagw", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "camera-control", name: "相机控制按钮", nameEn: "Camera Control",
            description: "启用相机控制按钮相关能力。硬件没有则无实际效果。",
            keys: [
                MGPresetKey(key: "CwvKxM2cEogD3p+HYgaW0Q", value: .integer(1)),
                MGPresetKey(key: "oOV1jhJbdV3AddkcCg0AEA", value: .integer(1)),
            ],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "apple-pencil", name: "Apple Pencil 支持", nameEn: "Apple Pencil",
            description: "宣称支持 Apple Pencil。硬件没有则无实际效果。",
            keys: [MGPresetKey(key: "yhHcB0iH0d1XzPO/CFd3ow", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "action-button", name: "操作按钮", nameEn: "Action Button",
            description: "启用操作按钮相关能力。硬件没有则无实际效果。",
            keys: [MGPresetKey(key: "cT44WE1EohiwRzhsZ8xEsw", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "collision-sos", name: "碰撞检测 SOS", nameEn: "Crash Detection SOS",
            description: "启用车祸检测 SOS。硬件/传感器不支持则无实际效果。",
            keys: [MGPresetKey(key: "HCzWusHQwZDea6nNhaKndw", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "hdr-photo", name: "HDR 照片", nameEn: "HDR Photos",
            description: "启用 HDR 照片能力。",
            keys: [MGPresetKey(key: "a1r7npIrhXsZ7SmKRKC1eA", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "stage-manager", name: "台前调度（Stage Manager）", nameEn: "Stage Manager",
            description: "开启台前调度多任务。",
            keys: [MGPresetKey(key: "qeaj75wk3HF4DwQ8qbIi7g", value: .integer(1))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "ipad-apps", name: "允许 iPad 应用", nameEn: "Allow iPad Apps",
            description: "允许运行 iPad 应用。",
            keys: [MGPresetKey(key: "9MZ5AdH43csAUajl/dU+IQ", value: .array([.integer(1), .integer(2)]))],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "region-us", name: "地区切换（美区）", nameEn: "Region: US",
            description: "把地区改为美国（LL）。仅设置 RegionCode / RegionInfo 两项。",
            keys: [
                MGPresetKey(key: "h63QSdBCiT/z0WU6rdQv6Q", value: .string("LL")),
                MGPresetKey(key: "yK+xavymRGZ3xWc1tb8XDg", value: .string("LL/A")),
            ],
            minOSMajor: 27, risk: .normal, conflictGroup: nil
        ),
        MGPreset(
            id: "siri-ai", name: "Siri AI（两段式）", nameEn: "Siri AI (two-phase)",
            description: "第一步：临时伪装成 iPhone 15 Pro 并开启 Siri AI（SiriMode=2），等待模型下载；第二步：只还原身份键、保留 SiriMode。伪装期间 Face ID 与听写可能失效；A16 + 6GB 机型即使开了入口也不保证满血端侧功能。",
            keys: [
                MGPresetKey(key: "a3n5T9sFtlyQ74NEp9ESxg", value: .integer(2)),
                MGPresetKey(key: "A62OafQ85EJAiiqKn4agtg", value: .integer(1)),
                MGPresetKey(key: "h9jDsbgj7xIVeIQ8S3/X3Q", value: .string("iPhone16,1")),
                MGPresetKey(key: "oYicEKzVTz4/CxxE05pEgQ", value: .string("D83AP")),
                MGPresetKey(key: "5pYKlGnYYBzGvAlIU8RjEQ", value: .string("t8130")),
            ],
            minOSMajor: 27, risk: .high("伪装期间 Face ID 与听写可能失效；第二步必须手动还原身份键。"), conflictGroup: nil
        ),
        MGPreset(
            id: "ipados-mode", name: "iPadOS 模式（高危）", nameEn: "iPadOS Mode (risky)",
            description: "仅设置 7 个能力键，不含 CacheData 二进制补丁，效果不保证，可能导致不稳定或启动循环。请勿搭配字母数字密码使用。",
            keys: [
                MGPresetKey(key: "qeaj75wk3HF4DwQ8qbIi7g", value: .integer(1)),
                MGPresetKey(key: "9MZ5AdH43csAUajl/dU+IQ", value: .array([.integer(1), .integer(2)])),
            ],
            minOSMajor: 27, risk: .high("可能不稳定 / 启动循环；不含 CacheData 二进制补丁。"), conflictGroup: nil
        ),
        MGPreset(
            id: "internal-install", name: "内部安装 / 内部存储 / SRD（高危）", nameEn: "Internal Install / SRD (risky)",
            description: "开启内部安装、内部存储、SRD 模式相关能力位。高危，仅供研究，效果不保证。",
            keys: [
                MGPresetKey(key: "EqrsVvjcYDdxHBiQmGhAWw", value: .integer(1)),
                MGPresetKey(key: "LBJfwOEzExRxzlAnSuI7eg", value: .integer(1)),
                MGPresetKey(key: "XYlJKKkj2hztRP1NWWnhlw", value: .integer(1)),
            ],
            minOSMajor: 27, risk: .high("高危内部选项，效果不保证。"), conflictGroup: nil
        ),
    ]

    /// 灵动岛子类型（ArtworkDevice 字典内的 ArtworkDeviceSubType）。
    static let dynamicIslandSubtypes: [(label: String, subtype: Int)] = [
        ("iPhone 14 Pro（2556）", 2556),
        ("iPhone 14 Pro Max（2796）", 2796),
        ("iPhone 15 Pro（2868）", 2868),
        ("iPhone 15 Pro Max（2736）", 2736),
        ("iPhone 16 Pro（2622）", 2622),
        ("iPhone 16 Pro Max（2436）", 2436),
    ]

    /// Siri AI 第二步：只还原身份键（保留 SiriMode）。
    static let siriIdentityKeys = [
        "A62OafQ85EJAiiqKn4agtg",
        "h9jDsbgj7xIVeIQ8S3/X3Q",
        "oYicEKzVTz4/CxxE05pEgQ",
        "5pYKlGnYYBzGvAlIU8RjEQ",
    ]
}
