import SwiftUI

/// 我的 → 片源管理. Built-in sources (红果/黄果) are always on; long-video sites are opt-in and can be
/// hidden behind Face ID (`SourceGate`).
struct SourcesView: View {
    private let gate = SourceGate.shared
    @State private var message: String?
    @State private var bufferMB = BufferSettings.megabytes
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if gate.lockEnabled && !gate.unlocked {
                    lockedCard
                } else {
                    group("内置") {
                        builtinRow(.hongguo, "play.rectangle.on.rectangle")
                        builtinRow(.huangguo, "film.stack")
                    }
                    group("长视频片源（默认隐藏）") {
                        ForEach(Sites.all.filter(\.isAdult)) { s in siteRow(s) }
                    }
                    group("插件与采集站") {
                        NavigationLink(value: Route.plugins) {
                            HStack { label("插件管理", "puzzlepiece.extension", sub: "JS 插件、订阅、苹果 CMS 采集站；成人插件在这里解锁后才显示"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain).accessibilityIdentifier("sources.plugins")
                    }
                    group("频道与漫画（默认隐藏）") {
                        Toggle(isOn: Binding(get: { gate.adultChannels }, set: { gate.setAdultChannels($0) })) {
                            label("成人 Telegram 频道", "paperplane", sub: "预置 @bhg1232 / @NudefilmsTV 及你标记为成人的频道；开启后才出现在「频道」")
                        }.padding(14).accessibilityIdentifier("sources.adultChannels")
                        Toggle(isOn: Binding(get: { gate.adultManga }, set: { gate.setAdultManga($0) })) {
                            label("成人漫画源", "book.closed", sub: "控制成人漫画插件（内置推荐：Manga18fx / Komikindo / 18comic）；插件结果一律过滤未成年人相关标签")
                        }.padding(14)
                    }
                    Text("开启后，该站会出现在「发现」顶部标签和「搜索」结果来源里；关闭后收藏、观看记录仍保留在本机，只是不再显示。所有请求由本机直连站点，部分站点需要先在内置浏览器完成一次 Cloudflare 验证。")
                        .font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
                    group("播放设置") {
                        VStack(alignment: .leading, spacing: 10) {
                            label("长视频预缓冲", "arrow.down.circle", sub: "播放时从当前位置向后预先下载到本机，弱网下拖动/连续观看更流畅；短剧仍按预加载后续 3–4 集")
                            Picker("长视频预缓冲", selection: $bufferMB) {
                                ForEach(BufferSettings.options, id: \.self) { Text(BufferSettings.label($0)).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("settings.prebuffer")
                            .onChange(of: bufferMB) { _, v in BufferSettings.megabytes = v }
                        }.padding(14)
                        actionRow("清空预缓冲缓存（\(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))，上限 2GB）", "externaldrive.badge.xmark") {
                            PrefetchStore.shared.clearAll()
                            cacheBytes = PrefetchStore.shared.totalBytes()
                            message = "已清空预缓冲缓存"
                        }
                    }
                    group("隐私") {
                        Toggle(isOn: Binding(get: { gate.lockEnabled }, set: { on in Task { await gate.setLock(on) } })) {
                            label("隐藏片源锁（Face ID）", "faceid", sub: "每次启动后需验证才显示长视频片源")
                        }.padding(14)
                        actionRow("清除站点验证 Cookie", "trash") {
                            await CFCookies.clearAll()
                            message = "已清除站点 Cookie"
                        }
                        NavigationLink { SiteLogView() } label: {
                            HStack { label("站点诊断日志", "stethoscope", sub: "Cloudflare 验证 / Cookie / UA 记录，可复制给开发者"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain)
                        NavigationLink(value: Route.licenses) {
                            HStack { label("开源许可", "doc.text"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent).padding(.horizontal, 16) }
                }
            }.padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("片源管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { if gate.lockEnabled { await gate.unlock() } }
        .task { cacheBytes = await Task.detached { PrefetchStore.shared.totalBytes() }.value }
    }

    static func rootDomain(_ s: DramaSource) -> String {
        let parts = s.siteHost.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : s.siteHost
    }

    private var lockedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(STVTheme.accent)
            Text("长视频片源已锁定").font(.headline).foregroundStyle(STVTheme.text)
            Button("用 Face ID 解锁") { Task { await gate.unlock() } }
                .buttonStyle(.borderedProminent).tint(STVTheme.accent)
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    private func builtinRow(_ s: DramaSource, _ icon: String) -> some View {
        HStack {
            label(s.label, icon)
            Spacer()
            Text("内置").font(.caption.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3).background(STVTheme.glass, in: Capsule())
        }.padding(14)
    }

    private func siteRow(_ s: DramaSource) -> some View {
        Toggle(isOn: Binding(get: { gate.enabled.contains(s) }, set: { gate.set(s, on: $0) })) {
            label(s.label, "globe", sub: Self.note(s))
        }.padding(14)
    }

    static func note(_ s: DramaSource) -> String {
        switch s {
        case .jable: "HLS 直连 · 镜像 jable.tv / fs1.app"
        case .missav: "HLS 1080P/720P/480P/360P · 5 个镜像自动探测（.fans/.media 免验证）"
        case .hanime1: "MP4 直链（带签名）· 常需 Cloudflare 验证"
        case .supjav: "多线路（FST/VOE/TV/ST…，不含 LUC）· HLS 经本机代理去伪装头"
        case .eporner: "官方公开 API · HLS + MP4 多画质 · 大陆直连可达"
        case .xvideos: "HLS 自适应 + MP4 · 需代理"
        case .xnxx: "HLS 自适应 + MP4 · 需代理"
        case .pornhub: "HLS 1080P/720P/480P · 需代理"
        default: s.pluginID != nil ? "JS 插件 · " + (PluginStore.snapshot(s.pluginID!)?.manifest.httpDomains.first ?? "") :
                 s.cmsKey != nil ? "苹果 CMS 采集站 · " + (CMSStore.site(s.cmsKey!).flatMap { URL(string: $0.api)?.host } ?? "") : s.siteHost
        }
    }

    private func label(_ t: String, _ icon: String, sub: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(STVTheme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).foregroundStyle(STVTheme.text)
                if let sub { Text(sub).font(.caption).foregroundStyle(STVTheme.secondary) }
            }
        }
    }

    private var chevron: some View { Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary) }

    private func actionRow(_ t: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { HStack { label(t, icon); Spacer(); chevron }.padding(14) }.buttonStyle(.plain)
    }
}

/// 开源许可 — third-party code this app ports.
struct LicensesView: View {
    @State private var expanded = false
    @State private var qjsExpanded = false
    private var licenseText: String {
        Bundle.main.url(forResource: "UAV-Downloader-LICENSE", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Apache License 2.0 — https://www.apache.org/licenses/LICENSE-2.0"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("UAV-Downloader").font(.headline).foregroundStyle(STVTheme.text)
                    Text("Copyright © ALOS (github.com/Alos21750)\nLicensed under the Apache License, Version 2.0")
                        .font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/Alos21750/UAV-Downloader", destination: URL(string: "https://github.com/Alos21750/UAV-Downloader")!)
                        .font(.subheadline).tint(STVTheme.accent)
                    Text("i短剧 的 MissAV / Jable / SupJav / Hanime1 解析逻辑移植并改写自该项目（基于 commit de92300（2026-11-10 复查仍为最新），Python → Swift，HTML 解析改为正则）。修改内容：站点列表、详情与播放地址解析的 Swift 重写，以及与 i短剧 播放器的对接。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                    Button(expanded ? "收起许可证全文" : "查看 Apache-2.0 全文") { withAnimation { expanded.toggle() } }
                        .font(.subheadline.weight(.semibold)).tint(STVTheme.accent)
                    if expanded {
                        Text(licenseText).font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("yt-dlp").font(.headline).foregroundStyle(STVTheme.text)
                    Text("The Unlicense（公共领域）").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/yt-dlp/yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                        .font(.subheadline).tint(STVTheme.accent)
                    Text("Eporner / XVideos / XNXX / Pornhub 的页面结构与接口（Eporner xhr 哈希、html5player、mediaDefinitions）参考了 yt-dlp 的对应 extractor，代码为独立的 Swift 实现。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("TDLibKit / TDLib").font(.headline).foregroundStyle(STVTheme.text)
                    Text("TDLibKit：MIT · TDLib：Boost Software License 1.0").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/Swiftgram/TDLibKit", destination: URL(string: "https://github.com/Swiftgram/TDLibKit")!).font(.subheadline).tint(STVTheme.accent)
                    Link("github.com/tdlib/td", destination: URL(string: "https://github.com/tdlib/td")!).font(.subheadline).tint(STVTheme.accent)
                    Text("用于频道 TDLib 登录（私有频道、频道内搜索、机器人 /start）。只使用你自己填写的 api_id / api_hash。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("QuickJS-ng").font(.headline).foregroundStyle(STVTheme.text)
                    Text("MIT License · Copyright © 2017-2024 Fabrice Bellard, Charlie Gordon; © 2023-2025 Ben Noordhuis, Saúl Ibarra Corretgé").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/quickjs-ng/quickjs", destination: URL(string: "https://github.com/quickjs-ng/quickjs")!).font(.subheadline).tint(STVTheme.accent)
                    Text("插件运行时（v0.10.1，源码内置于 Packages/QuickJS，未修改；沙箱封装 idj_sandbox.c 为本应用代码）。").font(.caption).foregroundStyle(STVTheme.secondary)
                    Button(qjsExpanded ? "收起许可证全文" : "查看 MIT 全文") { withAnimation { qjsExpanded.toggle() } }
                        .font(.subheadline.weight(.semibold)).tint(STVTheme.accent)
                    if qjsExpanded {
                        Text(Bundle.main.url(forResource: "quickjs-ng-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT")
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("JMComic-Crawler-Python").font(.headline).foregroundStyle(STVTheme.text)
                    Text("MIT License · Copyright © hect0x7").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/hect0x7/JMComic-Crawler-Python", destination: URL(string: "https://github.com/hect0x7/JMComic-Crawler-Python")!).font(.subheadline).tint(STVTheme.accent)
                    Text("18comic 插件的图片分段还原（get_num / decode）参考该项目公开的算法，代码为独立的 Swift/JS 实现。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("MangaDex API · 包子漫画 · Telegram 网页预览").font(.headline).foregroundStyle(STVTheme.text)
                    Text("漫画与频道解析均为本应用独立实现；MangaDex 只请求全年龄/轻度分级内容。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }.padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 站点诊断日志 — what the app knows per site (UA, cookie names, cf_clearance expiry) + the CF event log.
struct SiteLogView: View {
    @State private var lines: [String] = SiteLog.all()
    @State private var copied = false

    private var summary: [String] {
        let jar = HTTPCookieStorage.shared.cookies ?? []
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return Sites.all.map { s in
            let hosts = s.siteHosts
            let cookies = jar.filter { c in hosts.contains { CFCookies.domain(c.domain, matches: $0) } }
            let cf = cookies.filter { $0.name == "cf_clearance" }
                .map { "\($0.domain) 至 \($0.expiresDate.map(f.string) ?? "会话")" }
            return "\(s.label)\n  UA：\(SiteLog.shortUA(s.userAgent))\(SiteUA.learned(s) == nil ? "（默认）" : "（验证页学到）")\n  Cookie：\(cookies.isEmpty ? "无" : Set(cookies.map(\.name)).sorted().joined(separator: ", "))\n  cf_clearance：\(cf.isEmpty ? "无" : cf.joined(separator: "；"))"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(summary, id: \.self) { s in
                    Text(s).font(.caption.monospaced()).foregroundStyle(STVTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("事件（最新在下）").font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.secondary).padding(.top, 6)
                if lines.isEmpty { Text("暂无记录").font(.caption).foregroundStyle(STVTheme.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption2.monospaced()).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                }
            }.padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("站点诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = (summary + [""] + lines).joined(separator: "\n"); copied = true
                }
                Button("清空") { SiteLog.clear(); lines = [] }
            }
        }
        .refreshable { lines = SiteLog.all() }
        .onAppear { lines = SiteLog.all() }
    }
}
