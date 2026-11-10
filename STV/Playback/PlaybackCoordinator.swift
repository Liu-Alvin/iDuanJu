import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/// Drives the vertical episode feed: one shared AVPlayer, per-episode prepared sources,
/// neighbour preloading, resume and local progress persistence.
@MainActor @Observable
final class PlaybackCoordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    /// `.remote`: upstream MP4 played by AVFoundation directly (proxy fallback).
    enum Source { case file(URL), stream(HLSPlayback, String), direct(URL), remote(URL, [String: String]) }

    /// AVPlayerItem for a source. Progressive MP4s get an explicit out-of-band MIME type so AVFoundation
    /// never has to guess the container from an extensionless / query-string URL.
    static func makeItem(_ src: Source) -> AVPlayerItem? {
        switch src {
        case .file(let u): return AVPlayerItem(url: u)
        case .direct(let u):
            let mp4 = u.path.hasSuffix(".mp4") || u.path.hasPrefix("/tg/")
            return AVPlayerItem(asset: AVURLAsset(url: u, options: mp4 ? [AVURLAssetOverrideMIMETypeKey: "video/mp4"] : nil))
        case .remote(let u, let headers):
            var o: [String: Any] = [AVURLAssetOverrideMIMETypeKey: "video/mp4"]
            if !headers.isEmpty { o["AVURLAssetHTTPHeaderFieldsKey"] = headers }
            return AVPlayerItem(asset: AVURLAsset(url: u, options: o))
        case .stream(let loader, let url):
            return loader.makeAsset(url: url).map { AVPlayerItem(asset: $0) }
        }
    }

    /// A loopback-proxied item that failed gets one retry straight from the CDN (fresh resolve → fresh token).
    static func canBypassProxy(_ src: Source?, stream: HGStream?) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_NO_FALLBACK"] == "1" { return false }
        #endif
        guard case .direct(let u)? = src, u.host == "127.0.0.1", let stream else { return false }
        return !stream.url.hasPrefix("tdfile://") && !stream.url.hasPrefix("file://") && LocalHLSProxy.token(of: stream.url) == nil
    }

    /// User-facing failure text with the AVFoundation code (so a device report pins the cause).
    static func failureText(_ e: Error?) -> String {
        guard let ns = e as NSError? else { return "播放失败，请重试" }
        let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.code)" } ?? ""
        return "\(ns.localizedDescription)（\(ns.code)\(under)）"
    }

    static let rateSteps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    let series: HGSeries
    var detail: HGSeriesDetail?
    private(set) var current: Int?
    private(set) var readyIndex: Int?
    private(set) var errors: [Int: String] = [:]
    /// Set when an episode failed on a Cloudflare interstitial (player shows 去验证).
    private(set) var verifyTargets: [Int: VerifyTarget] = [:]
    private(set) var streams: [Int: [HGStream]] = [:]
    private(set) var chosen: [Int: HGStream] = [:]
    var time: Double = 0
    var duration: Double = 0
    /// Furthest playable position buffered by AVPlayer around the playhead (seconds).
    private(set) var loadedUntil: Double = 0
    /// Buffered position for the progress bar: AVPlayer buffer or the byte pre-buffer, whichever is ahead.
    var bufferedUntil: Double { max(loadedUntil, prebuffer?.until ?? 0) }
    private(set) var paused = false
    /// Active playback rate (1.0 default). Locked rate persists after speed-gesture ends.
    private(set) var playbackRate: Double = 1.0
    /// Non-nil when user locked a non-1x rate via speed gesture.
    private(set) var lockedRate: Double? = nil
    private(set) var pipPossible = false
    /// Design v3 chrome: rendered video size, tech strip, audio / subtitle options, auto-advance.
    private(set) var videoSize: CGSize = .zero
    private(set) var tech: PlayerTech?
    private(set) var audioOptions: [AVMediaSelectionOption] = []
    private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private(set) var audioSelected: AVMediaSelectionOption?
    private(set) var subtitleSelected: AVMediaSelectionOption?
    var autoNext: Bool = UserDefaults.standard.object(forKey: "stv.player.autoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "stv.player.autoNext") }
    }
    @ObservationIgnored let thumbnails = PlayerThumbnailer()
    /// Time under the finger while the progress bar is dragged (time row follows it).
    var scrubPreview: Double?
    #if DEBUG
    /// Screenshot hook: frozen drag fraction (STV_SCRUB_DEMO), shared by whichever bar instance is on screen.
    var scrubDemo: Double?
    #endif
    @ObservationIgnored private var lastTech = Date.distantPast
    /// Long-video byte pre-buffer: bytes cached ahead of the playhead and the time the contiguous run reaches.
    private(set) var prebuffer: (bytes: Int, until: Double, lowStorage: Bool)?
    @ObservationIgnored private var prefetchTokens: [Int: String] = [:]
    /// Episodes whose proxied playback failed once → played straight from the CDN.
    @ObservationIgnored private var bypassProxy: Set<Int> = []
    @ObservationIgnored private var lastPrefetchPoll = Date.distantPast

    @ObservationIgnored private(set) lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }()
    private var prepared: [Int: Source] = [:]
    private var tasks: [Int: Task<Source, Error>] = [:]
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSave = Date.distantPast
    private var activation = UUID()
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private(set) var waitingForMedia = false
    private var audioObservers: [NSObjectProtocol] = []
    private var nowPlaying: MPNowPlayingSession?
    private(set) var pipActive = false
    var pipError: String?
    private var restoringPiP = false
    private var backgrounded = false
    private var interrupted = false
    private var audioSessionActive = false

    init(series: HGSeries) {
        self.series = series
        super.init()
    }

    func start() {
        guard observer == nil else { return }
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        nowPlaying = session
        let commands = session.remoteCommandCenter
        commands.playCommand.addTarget(self, action: #selector(remotePlay))
        commands.pauseCommand.addTarget(self, action: #selector(remotePause))
        commands.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                MainActor.assumeIsolated { self?.setPaused(true) }
            }
        })
        audioObservers.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self] note in
            // PiP controls target AVPlayer directly. System background/interruption pauses must not erase play intent.
            guard note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String == AVPlayer.RateDidChangeReason.setRateCalled.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.pipActive, !self.restoringPiP, !self.interrupted, self.readyIndex != nil else { return }
                self.paused = self.player.rate == 0
            }
        })
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            Task { @MainActor in self?.waitingForMedia = player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    private func activateAudioSession() {
        guard !audioSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            // Best-effort; playback still works without background continuity.
        }
    }

    func teardown() {
        activation = UUID()
        save(force: true)
        pip?.delegate = nil
        pipObservation = nil
        statusObservation = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        audioObservers.removeAll()
        if let commands = nowPlaying?.remoteCommandCenter {
            [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand].forEach { $0.removeTarget(self) }
        }
        nowPlaying = nil
        if pip?.isPictureInPictureActive == true {
            pip?.stopPictureInPicture()
        }
        pip = nil
        pipActive = false
        pipPossible = false
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        readyIndex = nil
        current = nil
        backgrounded = false
        interrupted = false
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        prefetchTokens.values.forEach { LocalHLSProxy.shared.release($0) }
        prefetchTokens.removeAll()
        prebuffer = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    var episodes: [HGEpisode] { detail?.episodes ?? [] }

    // MARK: PiP

    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pip?.playerLayer !== layer,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        pipObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor in
                guard self?.pip === controller else { return }
                self?.pipPossible = controller.isPictureInPicturePossible
            }
        }
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            restoringPiP = true
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipActive = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipActive = false
        if !backgrounded { pipError = error.localizedDescription }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        restoringPiP = true
        completion(controller === pip && observer != nil)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipActive = false
        if !restoringPiP { setPaused(true) }
        else if !backgrounded, !paused, !interrupted, readyIndex != nil, player.timeControlStatus == .paused { play() }
        restoringPiP = false
    }

    func didEnterBackground() {
        backgrounded = true
        save(force: true)
    }

    func didBecomeActive() {
        guard backgrounded else { return }
        backgrounded = false
        if pip?.isPictureInPictureActive == true {
            restoringPiP = true
            pip?.stopPictureInPicture()
        }
        if !paused, !interrupted, readyIndex != nil, player.timeControlStatus == .paused { play() }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue {
            audioSessionActive = false
            interrupted = true
            save(force: true)
        } else {
            interrupted = false
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { setPaused(true) }
            else if !paused, readyIndex != nil { play() }
        }
    }

    @objc private func remotePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        setPaused(false)
        return .success
    }

    @objc private func remotePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        setPaused(true)
        return .success
    }

    @objc private func remoteToggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        togglePause()
        return .success
    }

    // MARK: Rate

    func applyRate(_ rate: Double) {
        let r = Self.nearestStep(rate)
        playbackRate = r
        player.defaultRate = Float(r)
        if !paused, !interrupted, readyIndex != nil { player.rate = Float(r) }
    }

    func lockRate(_ rate: Double) {
        let r = Self.nearestStep(rate)
        lockedRate = r == 1.0 ? nil : r
        applyRate(r)
    }

    func unlockRate() {
        lockedRate = nil
        applyRate(1.0)
    }

    func restoreLockedOrNormal() {
        applyRate(lockedRate ?? 1.0)
    }

    static func nearestStep(_ rate: Double) -> Double {
        rateSteps.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }

    static func stepIndex(of rate: Double) -> Int {
        let r = nearestStep(rate)
        return rateSteps.firstIndex(of: r) ?? rateSteps.firstIndex(of: 1.0) ?? 0
    }

    static func formatRate(_ rate: Double) -> String {
        if rate == Double(Int(rate)) { return "\(Int(rate))x" }
        let s = String(format: "%.2f", rate)
        return s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) + "x"
    }

    // MARK: Activation

    func select(_ index: Int?) {
        guard let index, index != current, episodes.indices.contains(index) else { return }
        current = index
        paused = false
        activate(index)
    }

    func activate(_ i: Int) {
        guard i == current, episodes.indices.contains(i), observer != nil else { return }
        save(force: true)
        let token = UUID()
        activation = token
        readyIndex = nil
        itemObservation = nil
        player.pause()
        time = 0; loadedUntil = 0
        duration = Double(episodes[i].duration)
        for k in tasks.keys where k != i && k != i + 1 {
            tasks.removeValue(forKey: k)?.cancel()
        }
        for (k, tok) in prefetchTokens where k != i {
            // Only the playing episode pre-buffers; others drop their proxy route + cache.
            LocalHLSProxy.shared.release(tok); prefetchTokens[k] = nil; prepared[k] = nil
        }
        prebuffer = nil
        for k in prepared.keys where abs(k - i) > 1 {
            prepared[k] = nil
            streams[k] = nil
            chosen[k] = nil
        }
        errors[i] = nil
        verifyTargets[i] = nil
        Task { [self] in
            guard activation == token else { return }
            do {
                let src = try await prepare(i)
                guard activation == token else { return }
                guard let item = Self.makeItem(src) else { throw URLError(.badURL) }
                item.nowPlayingInfo = [MPMediaItemPropertyTitle: detail?.title ?? series.title,
                                       MPMediaItemPropertyAlbumTitle: series.source.isLongVideo ? series.source.label : "第\(episodes[i].ep)集"]
                player.replaceCurrentItem(with: item)
                thumbnails.attach(item.asset)
                tech = nil; videoSize = .zero; audioOptions = []; subtitleOptions = []
                itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        #if DEBUG
                        if item.status == .readyToPlay { NSLog("%@", "[STV] item readyToPlay") }
                        #endif
                        guard let self, self.activation == token, item.status == .failed else { return }
                        #if DEBUG
                        let ns = item.error as NSError?
                        let under = (ns?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-"
                        NSLog("%@", "[STV] item failed \(ns?.domain ?? "-") \(ns?.code ?? 0) under=\(under) url=\((item.asset as? AVURLAsset)?.url.absoluteString.prefix(80) ?? "-") log=\(item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])")
                        #endif
                        self.readyIndex = nil
                        if Self.canBypassProxy(src, stream: self.chosen[i]), !self.bypassProxy.contains(i) {
                            // Proxy path failed (probe/CDN/token): retry once with AVFoundation talking to the CDN.
                            #if DEBUG
                            NSLog("%@", "[STV] proxy fallback → direct CDN")
                            #endif
                            self.bypassProxy.insert(i)
                            if let tok = self.prefetchTokens.removeValue(forKey: i) { LocalHLSProxy.shared.release(tok) }
                            self.prepared[i] = nil
                            self.chosen[i] = nil
                            self.activate(i)
                            return
                        }
                        self.prepared[i] = nil
                        self.chosen[i] = nil
                        self.errors[i] = Self.failureText(item.error)
                    }
                }
                if let p = LibraryStore.shared.progress(for: series), p.episodeIndex == i, p.seconds > 3,
                   p.duration <= 0 || p.seconds < p.duration - 5 {
                    await player.seek(to: CMTime(seconds: p.seconds, preferredTimescale: 600))
                }
                guard activation == token, item.status != .failed else { return }
                #if DEBUG
                NSLog("%@", "[STV] item prepared src=\(String(describing: src).prefix(120))")
                #endif
                observeEnd(item, index: i)
                readyIndex = i
                if !paused, !interrupted { play() }
                if episodes.indices.contains(i + 1) {
                    Task { [weak self] in
                        guard let self, self.activation == token else { return }
                        _ = try? await self.prepare(i + 1)
                    }
                }
                if series.source == .hongguo {
                    // Warm play URLs for the next few episodes (180 s cache) so swipes resolve instantly.
                    let next = episodes.indices.filter { $0 > i && $0 <= i + 3 }.map { episodes[$0].vid }
                    Task { await HongguoClient.shared.prefetch(vids: next) }
                }
                _ = await nowPlaying?.becomeActiveIfPossible()
            } catch {
                guard activation == token else { return }
                errors[i] = error.localizedDescription
                verifyTargets[i] = error.verifyTarget
            }
        }
    }

    private func observeEnd(_ item: AVPlayerItem, index: Int) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current == index, self.player.currentItem === item else { return }
                if index + 1 < self.episodes.count, self.autoNext { self.select(index + 1) }
                else { self.setPaused(true) }
            }
        }
    }

    private func prepare(_ i: Int) async throws -> Source {
        if let source = prepared[i] {
            if case .file(let url) = source, !FileManager.default.fileExists(atPath: url.path) {
                prepared[i] = nil
            } else { return source }
        }
        if let t = tasks[i] { return try await t.value }
        let ep = episodes[i]
        let series = self.series
        let want = chosen[i]
        let preferredId = SitePrefs.preferredStream[series.id]
        let bypass = bypassProxy.contains(i)
        let task = Task<Source, Error> { [weak self] in
            var stream = want
            if stream == nil {
                let r = try await Catalog.resolve(series, ep)
                if let e = r.err, r.streams.isEmpty { throw ProviderError.upstream(e) }
                guard let best = r.streams.first(where: { $0.id == preferredId }) ?? r.streams.first else { throw ProviderError.upstream("没有可用的视频流") }
                try Task.checkCancellation()
                self?.streams[i] = r.streams
                self?.chosen[i] = best
                stream = best
            }
            guard let s = stream else { throw ProviderError.upstream("没有可用的视频流") }
            switch s.kind {
            case .mp4Cenc:
                return .file(try await EpisodePlaybackLoader.playableFile(vid: ep.vid, stream: s))
            case .mp4Clear where s.url.hasPrefix("tdfile://"):
                // TDLib video: plain progressive file from the loopback proxy, downloaded window by window.
                guard let ref = TDFileRef(s.url) else { throw ProviderError.invalid(s.url) }
                let source = try await TDLibService.shared.streamSource()
                guard let src = await self?.tdStream(ref, source: source, budget: BufferSettings.budget(for: series.source), index: i) else {
                    throw ProviderError.upstream("本地播放代理启动失败")
                }
                return src
            case .mp4Clear where s.url.hasPrefix("file://"):
                // Downloaded (offline) Telegram video.
                guard let u = URL(string: s.url) else { throw ProviderError.upstream("文件地址无效") }
                return .file(u)
            case .mp4Clear where bypass:
                guard let u = URL(string: s.url) else { throw ProviderError.invalid(s.url) }
                return .remote(u, s.headers)
            case .mp4Clear, .hls, .hlsAES:
                let budget = bypass ? 0 : BufferSettings.budget(for: series.source)
                if budget > 0, let proxied = await self?.prebuffered(s, budget: budget, index: i) { return proxied }
                return .stream(HLSPlayback(headers: s.headers, keyHex: s.key), s.url)
            }
        }
        tasks[i] = task
        defer { if tasks[i] == task { tasks[i] = nil } }
        let src = try await task.value
        guard tasks[i] == task, !task.isCancelled else { throw CancellationError() }
        prepared[i] = src
        return src
    }

    /// Long-video sources go through the loopback proxy so segments / MP4 ranges come from the byte
    /// pre-buffer. AES-128 streams with an out-of-band key keep the resource-loader path.
    private func prebuffered(_ s: HGStream, budget: Int, index i: Int) -> Source? {
        if let tok = LocalHLSProxy.token(of: s.url) {           // SupJav: already proxied
            LocalHLSProxy.shared.enablePrefetch(tok, budget: budget)
            prefetchTokens[i] = tok
            return nil
        }
        let proxied: String?
        switch s.kind {
        case .hls: proxied = LocalHLSProxy.shared.playlistURL(s.url, headers: s.headers, strip: false, budget: budget)
        case .hlsAES where s.key.isEmpty: proxied = LocalHLSProxy.shared.playlistURL(s.url, headers: s.headers, strip: false, budget: budget)
        case .mp4Clear: proxied = LocalHLSProxy.shared.mp4URL(s.url, headers: s.headers, budget: budget)
        default: proxied = nil
        }
        guard let proxied, let u = URL(string: proxied), let tok = LocalHLSProxy.token(of: proxied) else { return nil }
        prefetchTokens[i] = tok
        return .direct(u)
    }

    private func tdStream(_ ref: TDFileRef, source: TDFileStreamSource, budget: Int, index i: Int) -> Source? {
        guard let proxied = LocalHLSProxy.shared.tdURL(ref, budget: budget, source: source),
              let u = URL(string: proxied), let tok = LocalHLSProxy.token(of: proxied) else { return nil }
        prefetchTokens[i] = tok
        return .direct(u)
    }

    func choose(_ s: HGStream, for i: Int) {
        guard chosen[i] != s else { return }
        if let tok = prefetchTokens.removeValue(forKey: i) { LocalHLSProxy.shared.release(tok) }
        tasks.removeValue(forKey: i)?.cancel()
        chosen[i] = s; prepared[i] = nil
        if current == i { activate(i) }
    }

    // MARK: Controls

    func togglePause() {
        setPaused(!paused)
    }

    private func setPaused(_ value: Bool) {
        paused = value
        if value {
            player.pause()
            save(force: true)
        } else if !interrupted, readyIndex != nil {
            if duration > 0, player.currentTime().seconds >= duration - 0.15 { seek(fraction: 0) }
            play()
        }
    }

    private func play() {
        activateAudioSession()
        player.defaultRate = Float(playbackRate)
        player.play()
    }

    /// ±10 s buttons / double tap.
    func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(duration - 0.5, player.currentTime().seconds + seconds))
        seek(fraction: t / duration)
    }

    private func refreshMediaOptions(_ item: AVPlayerItem) async {
        if let g = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
            audioOptions = g.options; audioSelected = item.currentMediaSelection.selectedMediaOption(in: g)
        }
        if let g = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            subtitleOptions = g.options; subtitleSelected = item.currentMediaSelection.selectedMediaOption(in: g)
        }
    }

    /// nil option = subtitles off.
    func selectMedia(_ option: AVMediaSelectionOption?, audible: Bool) {
        guard let item = player.currentItem else { return }
        Task {
            guard let g = try? await item.asset.loadMediaSelectionGroup(for: audible ? .audible : .legible) else { return }
            item.select(option, in: g)
            if audible { audioSelected = option } else { subtitleSelected = option }
        }
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updatePrefetch(at: duration * fraction, force: true)
    }

    /// Follow the playhead (seek restarts prefetch from the new position) and refresh the HUD figure.
    private func updatePrefetch(at t: Double, force: Bool = false) {
        guard let i = readyIndex, let tok = prefetchTokens[i] else { return }
        guard force || Date().timeIntervalSince(lastPrefetchPoll) > 1 else { return }
        lastPrefetchPoll = Date()
        if let td = LocalHLSProxy.shared.tdSession(tok) {
            // TDLib stream: seek moves the download window; the buffer layer = bytes TDLib has from here on.
            let d = duration, frac = d > 0 ? t / d : 0
            Task { [weak self] in
                if force { await td.seek(fraction: frac) }
                guard let b = await td.buffered(from: frac), d > 0 else { return }
                await MainActor.run {
                    guard let self, self.readyIndex == i, self.prefetchTokens[i] == tok else { return }
                    self.prebuffer = (b.bytes, min(d, b.until * d), false)
                }
            }
            return
        }
        // MP4 units are chunk indices; map playback time to a chunk by fraction of the duration.
        let pos: Double
        if chosen[i]?.kind == .mp4Clear, duration > 0, let st = LocalHLSProxy.shared.status(tok), st.total >= 0 {
            pos = (t / duration) * Double(LocalHLSProxy.shared.mp4Chunks(tok))
        } else { pos = t }
        LocalHLSProxy.shared.setPosition(tok, pos)
        if let st = LocalHLSProxy.shared.status(tok) {
            let until = chosen[i]?.kind == .mp4Clear
                ? min(duration, st.until / Double(max(1, LocalHLSProxy.shared.mp4Chunks(tok))) * duration) : st.until
            prebuffer = (st.bytes, until, st.lowStorage)
        }
    }

    private func tick(_ t: Double) {
        guard readyIndex != nil, t.isFinite else { return }
        time = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if let s = player.currentItem?.presentationSize, s.width > 0, s != videoSize { videoSize = s }
        if Date().timeIntervalSince(lastTech) > 2, let item = player.currentItem, let i = readyIndex {
            lastTech = Date()
            let stream = chosen[i]
            Task { [weak self] in
                let t = await PlayerTech.read(item, stream: stream)
                guard let self, self.player.currentItem === item else { return }
                if t != self.tech { self.tech = t }
                await self.refreshMediaOptions(item)
            }
        }
        if let ranges = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue) {
            let r = ranges.first { $0.start.seconds <= t + 1 && ($0.start + $0.duration).seconds >= t } ?? ranges.first
            loadedUntil = r.map { ($0.start + $0.duration).seconds } ?? 0
        }
        updatePrefetch(at: t)
        save(force: false)
    }

    private func save(force: Bool) {
        guard let i = readyIndex, episodes.indices.contains(i) else { return }
        guard force || Date().timeIntervalSince(lastSave) > 4 else { return }
        let seconds = force ? player.currentTime().seconds : time
        guard seconds.isFinite, seconds > 0 else { return }
        lastSave = Date()
        // Deep links / season switches may carry a bare series; fill title & cover from the loaded detail.
        var rec = series
        if let d = detail {
            if rec.title.isEmpty { rec.title = d.title }
            if rec.cover.isEmpty { rec.cover = d.cover }
            if rec.episodeCount == 0 { rec.episodeCount = max(d.totalEps, d.episodes.count) }
        }
        LibraryStore.shared.record(rec, index: i, ep: episodes[i].ep, seconds: seconds, duration: duration)
    }
}
