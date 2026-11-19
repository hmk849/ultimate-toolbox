import SwiftUI
import UniformTypeIdentifiers

/// 交互壁纸（.tendies）：导入安装 + GitHub 壁纸库。
/// 引擎 BQApplyTendies 已实现安装（解包、写 PosterBoard 描述符、刷新偏好、失败回滚）。
/// 诚实说明：安装后去墙纸设置里挑选；动的视频循环在锁屏上播，点按切换等交互状态在 iOS 27 上可能不生效，以真机效果为准。

extension UTType {
    static let tendies = UTType(filenameExtension: "tendies", conformingTo: .zip) ?? .zip
}

struct TendiesWallpaperView: View {
    @StateObject private var service = TendiesService.shared
    @EnvironmentObject var compat: CompatibilityService
    @State private var showImporter = false
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let report = compat.report, !report.escapeAvailable {
                    UnavailableCard(title: L10n.s("交互壁纸不可用", "Live Wallpaper unavailable"), reason: report.escapeDetail)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.wallpaper).font(.headline)
                        Text(L10n.s("把 .tendies 动态壁纸装进系统 PosterBoard，装完去墙纸设置里挑选。支持导入本地文件，或从 GitHub 壁纸库下载（CAPlayground/wallpapers，288 个）。", "Install .tendies live wallpapers into the system PosterBoard, then pick them in Wallpaper settings. Import a local file or download from the GitHub library (CAPlayground/wallpapers, 288 wallpapers)."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.s("动的视频循环在锁屏上播；点按切换等交互状态在 iOS 27 上可能不生效，以真机效果为准。单个文件上限 128 MB。", "The animated video loop plays on the Lock Screen; tap-to-switch interactive states may not work on iOS 27 — check on your phone. Single file limit is 128 MB."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(service.status).font(.caption).foregroundStyle(.secondary)
                        if service.isApplying || service.isDownloading {
                            ProgressView(value: service.isDownloading ? service.downloadProgress : nil)
                        }
                        HStack(spacing: 12) {
                            Button(L10n.s("导入 .tendies 文件", "Import .tendies file")) { showImporter = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(service.isApplying || service.isDownloading)
                            Button(L10n.s("打开墙纸设置", "Open Wallpaper settings")) { service.openPosterBoard() }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button(L10n.s("重置 PosterBoard", "Reset PosterBoard"), role: .destructive) { showResetConfirm = true }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.s("壁纸库", "Wallpaper library")).font(.headline)
                            Spacer()
                            if service.isLoadingLibrary { ProgressView() }
                            Button(L10n.s("刷新", "Refresh")) { Task { await service.fetchLibrary() } }
                                .buttonStyle(.bordered)
                                .disabled(service.isLoadingLibrary)
                        }
                        TextField(L10n.s("搜索壁纸", "Search wallpapers"), text: $service.searchText)
                            .textFieldStyle(.roundedBorder)
                        if service.packs.isEmpty && !service.isLoadingLibrary {
                            Text(L10n.s("点「刷新」加载壁纸库（公开仓库，无需登录 GitHub）。", "Tap Refresh to load the library (public repo, no GitHub login needed)."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(service.filteredPacks) { pack in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.displayName).font(.subheadline).fontWeight(.medium)
                                        Text(SystemInfoService.formatBytes(pack.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(L10n.s("下载安装", "Download & install")) {
                                        Task { await service.downloadAndApply(pack) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(service.isApplying || service.isDownloading)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(L10n.wallpaper)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.tendies, .zip], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await service.importPickedFile(url) }
        }
        .alert(L10n.s("重置 PosterBoard？", "Reset PosterBoard?"), isPresented: $showResetConfirm) {
            Button(L10n.s("取消", "Cancel"), role: .cancel) {}
            Button(L10n.s("重置", "Reset"), role: .destructive) {
                Task { await service.resetPosterBoard() }
            }
        } message: {
            Text(L10n.s("会删除已导入的壁纸描述符，系统自带壁纸不受影响。", "Removes imported wallpaper descriptors. Built-in wallpapers are not affected."))
        }
        .task {
            if service.packs.isEmpty { await service.fetchLibrary() }
        }
    }
}
