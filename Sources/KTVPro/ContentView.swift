import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

private let accent = StudioTheme.accent

struct ContentView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropping = false
    @State private var seeking = false
    @State private var seekPosition = 0.0
    @State private var lyricSearch: LyricSearchContext?
    @State private var takeReview: TakeReviewRequest?
    @State private var lyricNavigator = false
    @State private var musicDLSearch = false
    @State private var requestedPunch: (Take, PracticeRange)?
    @State private var focusStage = false
    @AppStorage("autoFocusStageOnRecord") private var autoFocusStageOnRecord = false
    @AppStorage("stageVisualMode") private var visualModeRaw = StageVisualMode.flowerMascot.rawValue
    @State private var autoFocusedDuringTake = false
    @State private var editingPhotoMouth = false
    @State private var photoEditorStartInCrop = false
    @StateObject private var photoMouth = PhotoMouthStore()
    @StateObject private var fiveSing = FiveSingBrowser()

    private var visualMode: StageVisualMode {
        StageVisualMode(rawValue: visualModeRaw) ?? .flowerMascot
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioTheme.separator.frame(height: 1)
            HStack(spacing: 0) {
                if !focusStage {
                    LibrarySidebar(model: model, accent: accent, reviewTake: { takeReview = model.beginTakeReview($0) }, openFiveSing: {
                        fiveSing.onAdded = { [weak model] song in model?.downloadedSongAdded(song) }
                        fiveSing.show()
                    }, openMusicDL: {
                        if model.isPlaying { model.togglePlayback() }
                        model.stopTakePlayback()
                        musicDLSearch = true
                    })
                    .frame(width: 288)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    StudioTheme.separator.frame(width: 1)
                }
                VStack(spacing: 0) {
                    if !focusStage {
                        mediaSources
                            .transition(.opacity)
                    }
                    videoWorkspace
                    transport
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if !focusStage {
                    StudioTheme.separator.frame(width: 1)
                    inspector
                        .frame(width: 294)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : StudioTheme.stageSpring, value: focusStage)
            StudioTheme.separator.frame(height: 1)
            footer
        }
        .background(StudioTheme.chrome)
        .preferredColorScheme(.dark)
        .tint(accent)
        .frame(minWidth: 1060, minHeight: 740)
        .onKeyPress(.escape) {
            guard focusStage else { return .ignored }
            toggleFocusStage(false)
            return .handled
        }
        .onChange(of: model.isRecording) { _, recording in
            if recording {
                if autoFocusStageOnRecord && !focusStage {
                    autoFocusedDuringTake = true
                    toggleFocusStage(true)
                }
            } else if autoFocusedDuringTake {
                autoFocusedDuringTake = false
                toggleFocusStage(false)
            }
        }
        .sheet(item: $lyricSearch) { context in
            LyricSearchSheet(context: context) { record in
                try model.importSearchedLyrics(record, for: context)
            }
        }
        .sheet(item: $takeReview, onDismiss: {
            model.endTakeReview()
            if let (take, range) = requestedPunch {
                requestedPunch = nil
                model.stagePunch(take, range: range)
            }
        }) { request in
            TakeReviewSheet(request: request, cuePunch: { requestedPunch = (request.take, $0) },
                            adopt: { try model.adoptPunch(parentID: request.id, versionID: $0) })
        }
        .sheet(isPresented: $lyricNavigator) {
            lyricNavigationSheet
        }
        .sheet(isPresented: $musicDLSearch) {
            if let importer = model.musicDLImporter {
                MusicDLSearchSheet(importer: importer) { [weak model] song in model?.musicDLSongAdded(song) }
                    .id(model.musicDLDownloadDirectory)
            }
        }
        .sheet(isPresented: $editingPhotoMouth) {
            PhotoMouthEditorSheet(model: model, store: photoMouth, startInCrop: photoEditorStartInCrop)
        }
        .alert("需要处理", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.permissionDenied {
                Button("打开麦克风设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("下载伴奏分离模型", isPresented: Binding(get: { model.modelDownloadRequest != nil },
                                                   set: { if !$0 { model.modelDownloadRequest = nil } }),
               presenting: model.modelDownloadRequest) { request in
            Button("下载并提取") {
                Task { @MainActor in
                    model.extractAccompaniment(for: request.song, version: request.version,
                                               approvedModelDirectory: request.directory)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text("模型目录中没有完整的「\(request.model.rawValue)」。联网下载\(request.model.downloadSize)后，即可提取伴奏。\n\n存放位置\n\(request.directory.path)")
        }
    }

    private func openLyricSearch() { lyricSearch = model.lyricSearchContext() }

    private func toggleFocusStage(_ enabled: Bool) {
        if !enabled { autoFocusedDuringTake = false }
        if reduceMotion { focusStage = enabled }
        else { withAnimation(StudioTheme.stageSpring) { focusStage = enabled } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = StudioTheme.appIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 39, height: 39).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("KTake").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("录唱工作台").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRecording {
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill").font(.system(size: 8))
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                    Text("录制中  \(timeLabel(model.recordingSeconds))").monospacedDigit()
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(StudioTheme.live)
                    .transition(.opacity)
            } else {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Button { model.importLyrics() } label: { Label("歌词", systemImage: "text.alignleft").padding(.vertical, 4) }
                .disabled(model.busy || model.loadingMedia).keyboardShortcut("l", modifiers: .command)
                .help("导入本地 LRC 歌词")
            Button(action: openLyricSearch) {
                Label("搜歌词", systemImage: "magnifyingglass").padding(.vertical, 4)
            }.disabled(!model.canSearchLyrics).help("从 LRCLIB 搜索歌词")
            Button { model.importVideo() } label: {
                Label("MV", systemImage: "film").padding(.vertical, 4)
            }.disabled(model.busy || model.loadingMedia).keyboardShortcut("o", modifiers: [.command, .shift])
            Button { model.importAccompaniment() } label: {
                Label("导入伴奏", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 31)
            }.buttonStyle(StudioActionStyle())
                .disabled(model.busy || model.loadingMedia).keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .animation(reduceMotion ? nil : StudioTheme.quick, value: model.isRecording)
    }

    private var mediaSources: some View {
        HStack(spacing: 18) {
            sourceLabel("伴奏", url: model.accompanimentURL, empty: "未导入", clear: model.clearAccompaniment)
            sourceLabel("MV", url: model.mediaURL, empty: "可选", clear: model.clearVideo)
            sourceLabel("歌词", url: model.lyricsURL, empty: "LRC · 可选", clear: model.clearLyrics)
        }.padding(.horizontal, 22).padding(.vertical, 12).background(StudioTheme.library)
    }

    private func sourceLabel(_ title: String, url: URL?, empty: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(.tertiary)
            Text(url?.lastPathComponent ?? empty).foregroundStyle(url == nil ? .tertiary : .secondary)
                .lineLimit(1).truncationMode(.middle).help(url?.path ?? empty)
            Spacer(minLength: 0)
            if url != nil {
                Button(action: clear) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).disabled(model.busy || model.loadingMedia).help("移除\(title)")
            }
        }.font(.system(size: 10)).frame(maxWidth: .infinity)
    }

    private func pickStagePhoto() {
        if photoMouth.choosePhoto() {
            visualModeRaw = StageVisualMode.photoMouth.rawValue
            photoEditorStartInCrop = true
            editingPhotoMouth = true
        }
    }

    private func handleDroppedFile(_ url: URL) {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .image) == true {
            if photoMouth.importPhoto(from: url) {
                visualModeRaw = StageVisualMode.photoMouth.rawValue
                photoEditorStartInCrop = true
                editingPhotoMouth = true
            }
            return
        }
        model.loadDroppedFile(url)
    }

    private var videoWorkspace: some View {
        ZStack {
            StageAmbientBackdrop(model: model, showsVideo: model.showsVideo, focusStage: focusStage)
            if model.showsVideo || (!model.loadingMedia && (model.mediaReady || !model.lyrics.lines.isEmpty)) {
                GeometryReader { stage in
                    VStack(spacing: 0) {
                        if model.showsVideo {
                            MovieSurface(player: model.player)
                                .frame(maxHeight: .infinity)
                        } else if visualMode == .flowerMascot {
                            let hasLyrics = !model.lyrics.lines.isEmpty
                            FlowerSingerView(model: model, mini: false, focusStage: focusStage)
                                .frame(height: hasLyrics
                                       ? min(focusStage ? 290 : 228, max(164, stage.size.height * (focusStage ? 0.42 : 0.41)))
                                       : min(focusStage ? 340 : 270, max(190, stage.size.height * 0.54)))
                                .frame(maxWidth: .infinity)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else if visualMode == .photoMouth {
                            let hasLyrics = !model.lyrics.lines.isEmpty
                            PhotoMouthSingerView(model: model, store: photoMouth, mini: false, focusStage: focusStage,
                                                 openEditor: { photoEditorStartInCrop = false; editingPhotoMouth = true },
                                                 pickPhoto: pickStagePhoto)
                                .frame(height: hasLyrics
                                       ? min(focusStage ? 300 : 236, max(168, stage.size.height * (focusStage ? 0.43 : 0.42)))
                                       : min(focusStage ? 360 : 280, max(196, stage.size.height * 0.56)))
                                .frame(maxWidth: .infinity)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        if !model.lyrics.lines.isEmpty || !model.showsVideo {
                            let compactLyrics = model.showsVideo || visualMode.hasCharacter
                            let upperFocusLyrics = !model.showsVideo && visualMode.hasCharacter
                            StageLyricDisplay(model: model, compact: compactLyrics, focusStage: focusStage,
                                              upperFocus: upperFocusLyrics, searchLyrics: openLyricSearch)
                                .frame(height: model.showsVideo ? min(focusStage ? 310 : 276, max(180, stage.size.height * (focusStage ? 0.42 : 0.44))) : nil)
                                .background {
                                    if model.showsVideo {
                                        LinearGradient(
                                            stops: [
                                                .init(color: StudioTheme.canvas.opacity(0.15), location: 0),
                                                .init(color: StudioTheme.canvas.opacity(0.76), location: 0.22),
                                                .init(color: StudioTheme.canvas.opacity(0.92), location: 1)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    }
                                }
                        }
                        if model.microphoneEnabled || model.isTestingMic {
                            VocalEnergyRibbon(model: model, compact: model.showsVideo, focusStage: focusStage)
                                .padding(.bottom, 6)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, model.showsVideo ? 0 : 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    if model.loadingMedia {
                        if model.preparingPitch {
                            ProgressView(value: model.pitchProgress).frame(width: 180)
                            Text("正在准备升降调… \(Int(model.pitchProgress * 100))% ").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.large)
                            Text("正在准备歌曲…").foregroundStyle(.secondary)
                        }
                    } else {
                        if visualMode == .flowerMascot {
                            FlowerSingerView(model: model, mini: false, focusStage: focusStage)
                                .frame(width: focusStage ? 320 : 250, height: focusStage ? 280 : 220)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else if visualMode == .photoMouth {
                            PhotoMouthSingerView(model: model, store: photoMouth, mini: false, focusStage: focusStage,
                                                 openEditor: { photoEditorStartInCrop = false; editingPhotoMouth = true },
                                                 pickPhoto: pickStagePhoto)
                                .frame(maxWidth: focusStage ? 460 : 380)
                                .frame(height: focusStage ? 290 : 230)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else {
                            ZStack {
                                Circle()
                                    .fill(StudioTheme.accent.opacity(0.08))
                                    .frame(width: 96, height: 96)
                                Image(systemName: "music.note")
                                    .font(.system(size: 46, weight: .ultraLight))
                                    .foregroundStyle(StudioTheme.action)
                            }
                        }
                        VStack(spacing: 8) {
                            Text("导入伴奏，开始录唱").font(.system(size: 24, weight: .medium, design: .rounded))
                            Text("搭配 MV 画面，或使用 LRC 同步歌词").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Text("拖入音频、MV、LRC 或照片文件").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.microphoneEnabled || model.isTestingMic {
                        VocalEnergyRibbon(model: model, compact: false, focusStage: focusStage)
                            .padding(.bottom, 10)
                    }
                }
            }
            if model.showsVideo && visualMode.hasCharacter {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if visualMode == .flowerMascot {
                            FlowerSingerView(model: model, mini: true, focusStage: focusStage)
                                .frame(width: 118, height: 118)
                                .background(.ultraThinMaterial.opacity(0.32), in: Circle())
                                .overlay { Circle().strokeBorder(StudioTheme.separator) }
                                .padding(.trailing, 18)
                                .padding(.bottom, (model.microphoneEnabled || model.isTestingMic) ? 34 : 14)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        } else if visualMode == .photoMouth, photoMouth.image != nil {
                            PhotoMouthSingerView(model: model, store: photoMouth, mini: true, focusStage: focusStage,
                                                 openEditor: { editingPhotoMouth = true }, pickPhoto: pickStagePhoto)
                                .frame(width: 124, height: 124)
                                .padding(.trailing, 18)
                                .padding(.bottom, (model.microphoneEnabled || model.isTestingMic) ? 34 : 14)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            VStack {
                HStack(spacing: 10) {
                    Label(model.showsVideo ? "MV" : visualMode == .flowerMascot ? "花小梨舞台" : visualMode == .photoMouth ? "照片舞台" : "歌词",
                          systemImage: model.showsVideo ? "film" : visualMode.hasCharacter ? visualMode.icon : "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.showsVideo ? .white : accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(model.showsVideo ? .black.opacity(0.6) : accent.opacity(0.11), in: Capsule())
                    if model.microphoneEnabled {
                        VocalZoneBadge(meter: model.meter, isRecording: model.isRecording)
                            .transition(.opacity)
                    }
                    Spacer()
                    if !model.lyrics.lines.isEmpty {
                        Text(String(format: "歌词延后 %+.2f s", model.lyricDelay))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Stepper("歌词时间调整", value: $model.lyricDelay, in: -10...10, step: 0.25)
                            .labelsHidden().controlSize(.mini).fixedSize()
                            .disabled(model.busy)
                            .help("正值让歌词晚出现，负值让歌词早出现")
                    }
                    stageModeControls
                }
                Spacer()
            }.padding(20)
            if isDropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(StudioTheme.action, lineWidth: 2).padding(8)
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : StudioTheme.quick, value: isDropping)
        .animation(reduceMotion ? nil : StudioTheme.quick, value: model.microphoneEnabled)
        .animation(reduceMotion ? nil : StudioTheme.stageSpring, value: visualModeRaw)
        .overlay { countdownOverlay }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropping) { providers in
            guard !model.busy, !model.loadingMedia, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in handleDroppedFile(url) }
            }
            return true
        }
    }

    private var stageModeControls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(StageVisualMode.allCases) { mode in
                    let selected = visualMode == mode
                    Button {
                        visualModeRaw = mode.rawValue
                    } label: {
                        Label(mode.shortLabel, systemImage: mode.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selected ? StudioTheme.lyricGlow : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(selected ? accent.opacity(0.22) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("切换到「\(mode.label)」")
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay { Capsule().strokeBorder(StudioTheme.separator) }

            Button {
                toggleFocusStage(!focusStage)
            } label: {
                Label(focusStage ? "退出舞台" : "舞台模式",
                      systemImage: focusStage ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(focusStage ? StudioTheme.lyricGlow : .secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(focusStage ? accent.opacity(0.20) : Color.white.opacity(0.07), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(focusStage ? accent.opacity(0.45) : StudioTheme.separator)
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("\\", modifiers: .command)
            .help(focusStage ? "退出专注舞台模式（⌘\\ 或 Esc）" : "收起侧栏进入专注舞台模式（⌘\\）")

            Menu {
                Toggle("开始录音时自动进入舞台模式", isOn: $autoFocusStageOnRecord)
                Divider()
                Button("上传舞台照片…", systemImage: "photo.badge.plus", action: pickStagePhoto)
                if photoMouth.image != nil {
                    Button("裁剪照片与调整嘴型…", systemImage: "crop") {
                        visualModeRaw = StageVisualMode.photoMouth.rawValue
                        editingPhotoMouth = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(autoFocusStageOnRecord ? accent : .secondary)
                    .frame(width: 24, height: 22)
                    .background(autoFocusStageOnRecord ? accent.opacity(0.14) : Color.white.opacity(0.06), in: Circle())
                    .overlay { Circle().strokeBorder(StudioTheme.separator) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("舞台视觉选项")
        }
    }

    private var countdownOverlay: some View {
        ZStack {
            if let count = model.recordCountdown, count > 0 {
                VStack(spacing: 4) {
                    Text("\(count)")
                        .font(.system(size: 62, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StudioTheme.action)
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    Text("准备开录").font(.callout.weight(.medium))
                }
                .frame(width: 142, height: 126)
                .background(StudioTheme.chrome.opacity(0.96), in: RoundedRectangle(cornerRadius: 19))
                .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(StudioTheme.separator) }
                .accessibilityLabel("\(count) 秒后开始录音")
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.21), value: model.recordCountdown)
    }

    private var transport: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.songTitle)
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(model.audioSourceLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill").frame(width: 25, height: 30) }
                    .buttonStyle(.plain).disabled(!model.mediaReady || model.busy).help("回到开头")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                        .frame(width: 43, height: 43)
                }.buttonStyle(StudioActionStyle(cornerRadius: 22))
                    .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    .disabled(!model.mediaReady || model.busy).help("播放 / 暂停歌曲")
                Button {
                    if model.isTestingMic { model.stopMicTest() } else { model.startMicTest() }
                } label: {
                    Label(model.isTestingMic ? "结束试音" : "试音", systemImage: "mic.badge.plus")
                }
                .fixedSize()
                .disabled(!model.isTestingMic && (!model.microphoneEnabled || model.busy || model.loadingMedia))
                .help(model.microphoneEnabled ? "录制最多 5 秒，检查输入电平" : "启用麦克风后可以试音")
                Button {
                    if model.isRecording { model.stopRecording() }
                    else if model.isRecordArmed { model.cancelRecordPreparation() }
                    else { model.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                        Text(model.isFinalizing ? "保存中…" : model.isRecording ? "结束录音" :
                             model.isRecordArmed ? "取消准备" : model.punchRange != nil ? "开始补录" : "开始录音")
                    }.font(.system(size: 13, weight: .semibold)).frame(width: 118, height: 43)
                }.buttonStyle(StudioActionStyle(emphasis: model.isRecording ? .recording :
                                                        model.isRecordArmed ? .quiet : .primary))
                    .disabled(!model.canPressRecord)
                    .keyboardShortcut("r", modifiers: .command)
            }
            HStack(spacing: 12) {
                Text(timeLabel(seeking ? seekPosition : model.position)).monospacedDigit()
                Slider(value: Binding(get: { seeking ? seekPosition : model.position }, set: {
                    if seeking { seekPosition = $0 } else { model.seek(to: $0) }
                }),
                       in: 0...max(model.duration, 1), onEditingChanged: { editing in
                    if editing { seekPosition = model.position; seeking = true }
                    else { model.seek(to: seekPosition); seeking = false }
                }).controlSize(.mini).disabled(!model.mediaReady || model.busy)
                Text(timeLabel(model.duration.rounded())).monospacedDigit().foregroundStyle(.tertiary)
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            practiceControls
        }.padding(22)
            .overlay(alignment: .top) { StudioTheme.separator.frame(height: 1).allowsHitTesting(false) }
    }

    private var practiceControls: some View {
        HStack(spacing: 8) {
            if let punch = model.punchRange {
                Label("补录 \(punch.label)", systemImage: "mic").foregroundStyle(accent).lineLimit(1)
                Button("取消补录") { model.cancelPunch() }.disabled(model.isRecording || model.isFinalizing)
            } else if model.hasSong {
                Button(model.loopA.map { "A \(preciseTimeLabel($0))" } ?? "设 A") { model.setLoopA() }
                    .disabled(model.busy || !model.mediaReady).help("把当前进度设为循环起点")
                Button(model.loopB.map { "B \(preciseTimeLabel($0))" } ?? "设 B") { model.setLoopB() }
                    .disabled(model.busy || !model.mediaReady || model.loopA == nil).help("把当前进度设为循环终点并启用循环")
                Button { model.togglePracticeLoop() } label: { Image(systemName: "repeat") }
                    .foregroundStyle(model.loopEnabled ? accent : .secondary)
                    .accessibilityLabel(model.loopEnabled ? "关闭 A/B 循环" : "开启 A/B 循环")
                    .disabled(model.busy || model.practiceRange == nil)
                if model.loopA != nil {
                    Button { model.clearPracticeLoop() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("清除循环点").disabled(model.busy)
                }
                if !model.lyrics.lines.isEmpty {
                    Button("歌词定位") { lyricNavigator = true }.disabled(model.busy || !model.mediaReady)
                }
            }
            Spacer(minLength: 4)
            if let song = model.librarySong {
                let versions = model.availableAudioVersions(for: song.id)
                if versions.count > 1 { audioVersionMenu(song, versions: versions) }
            }
            Menu {
                Picker("录前准备", selection: $model.recordLeadIn) {
                    ForEach(RecordLeadIn.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Label(model.recordLeadIn.rawValue, systemImage: "timer") }
                .disabled(model.isRecordArmed || model.isRecording || model.isFinalizing)
                .fixedSize().help("选择直接录制、倒数或提前听伴奏")
        }.font(.system(size: 11)).controlSize(.small)
    }

    private func audioVersionMenu(_ song: LibrarySong, versions: [LibraryAudioVersion]) -> some View {
        let current = model.libraryAudioVersion(for: song.id)
        let pending = model.pendingAudioVersion
        return Menu {
            ForEach(versions, id: \.self) { version in
                Button(version.label, systemImage: version == current ? "checkmark" : version == pending ? "clock" : "waveform") {
                    model.setLibraryAudioVersion(for: song, version: version)
                }
            }
        } label: {
            Label(pending == nil ? "切换音轨" : "准备音轨…", systemImage: "waveform")
        }
        .fixedSize()
        .disabled(model.busy || model.loadingMedia)
        .help(model.busy ? "录音及补录期间使用已选音轨" : "当前：\(current.label) · 可在播放中切换")
    }

    private var lyricNavigationSheet: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("歌词定位").font(.title2.bold())
            ScrollViewReader { proxy in
                List(model.lyrics.lines.filter { !$0.text.isEmpty }) { line in
                    Button {
                        model.seekToLyric(line)
                        lyricNavigator = false
                    } label: {
                        HStack(spacing: 15) {
                            Text(preciseTimeLabel(max(0, line.time + model.lyricDelay)))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(line.text)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).id(line.id)
                }
                .scrollContentBackground(.hidden)
                .background(StudioTheme.library, in: RoundedRectangle(cornerRadius: 8))
                .onAppear {
                    if let index = model.currentLyricIndex, model.lyrics.lines.indices.contains(index) {
                        proxy.scrollTo(model.lyrics.lines[index].id, anchor: .center)
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { lyricNavigator = false }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 550, height: 450).studioSheet()
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        sectionLabel("音频设备")
                        Spacer()
                        Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(model.busy).help("刷新设备")
                    }
                    devicePicker(title: "输入", selection: $model.inputID, devices: model.inputs)
                        .onChange(of: model.inputID) { _, _ in model.deviceSelectionChanged(input: true) }
                    if let input = model.inputDevice, input.inputChannels > 1 {
                        Picker("通道", selection: $model.inputChannel) {
                            ForEach(0..<input.inputChannels, id: \.self) { Text("Input \($0 + 1)").tag($0) }
                        }.font(.system(size: 11)).disabled(model.busy || model.microphoneEnabled)
                    }
                    devicePicker(title: "输出", selection: $model.outputID, devices: model.outputs)
                        .onChange(of: model.outputID) { _, _ in model.deviceSelectionChanged(input: false) }
                    Button {
                        if model.microphoneEnabled { model.disableMicrophone() } else { model.enableMicrophone() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.enablingMicrophone { ProgressView().controlSize(.mini) }
                            else { Image(systemName: model.microphoneEnabled ? "mic.fill" : "mic") }
                            Text(model.enablingMicrophone ? "正在准备…" : model.microphoneEnabled ? "关闭麦克风" : "启用麦克风")
                        }.font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34)
                    }.buttonStyle(StudioActionStyle())
                        .disabled(model.busy || model.inputs.isEmpty || model.outputs.isEmpty)
                }
                Divider()
                pitchControls
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionLabel("麦克风电平")
                        Spacer()
                        Text(model.microphoneEnabled ? String(format: "%.0f dBFS", model.meter.peakDB) : "— dBFS")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    LevelMeter(db: model.microphoneEnabled ? model.meter.peakDB : -60,
                               clipping: model.meter.clipUntil > ProcessInfo.processInfo.systemUptime)
                    HStack {
                        Text("−60")
                        Spacer()
                        Text("−18")
                        Spacer()
                        Text("0")
                    }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    if model.meter.clipUntil > ProcessInfo.processInfo.systemUptime {
                        Text("输入过载，请调低声卡增益").font(.system(size: 10)).foregroundStyle(StudioTheme.live)
                    }
                    if model.isTestingMic || model.isFinishingMicTest {
                        Label(model.isTestingMic ? "试音中 · 还剩 \(model.micTestRemaining) 秒" : "正在准备试音回放…",
                              systemImage: "waveform")
                            .font(.caption).foregroundStyle(accent)
                    } else if let result = model.micTestResult {
                        Text(result.summary).font(.caption)
                            .foregroundStyle(result.level.nearClipping || result.frames == 0 ? StudioTheme.amber : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(model.playingMicTest ? "停止试音回听" : "回听试音", systemImage: model.playingMicTest ? "stop.fill" : "play.fill") {
                            model.toggleMicTestPlayback()
                        }.disabled(model.busy || result.frames == 0)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $model.monitoring) {
                        Text("实时效果监听").font(.system(size: 13, weight: .medium))
                    }.toggleStyle(.switch).controlSize(.mini)
                        .disabled(!model.microphoneEnabled || model.playingTakeID != nil || model.playingMicTest)
                    Text("请使用有线耳机，并关闭声卡的直通监听。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("音色", selection: Binding(get: { model.preset }, set: { model.selectPreset($0) })) {
                        ForEach(SessionModel.vocalPresets, id: \.self) { Text($0) }
                    }.font(.system(size: 11))
                    effectSlider("人声音量", value: $model.monitorGain, range: 0...1.5, label: "\(Int(model.monitorGain * 100))%")
                    effectSlider("明亮度", value: $model.brightness, range: -4...6, label: String(format: "%+.0f dB", model.brightness))
                    effectSlider("压缩", value: $model.compression, range: 0...1, label: "\(Int(model.compression * 100))%")
                    effectSlider("混响", value: $model.reverb, range: 0...45, label: "\(Int(model.reverb))%")
                    VocalTuningControls(tuning: $model.vocalTuning)
                    Text("效果只用于监听，录音保存原始人声。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Divider()
                effectSlider(model.accompanimentURL != nil ? "伴奏音量" : "MV 音量", value: $model.videoVolume, range: 0...1, label: "\(Int(model.videoVolume * 100))%")
            }.padding(22)
        }.background(StudioTheme.inspector)
    }

    private var pitchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("伴奏升降调")
                Spacer()
                Text("速度不变").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button { model.setPitch(model.semitones - 1) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                    .disabled(model.semitones <= PitchRenderer.range.lowerBound).help("降低一个半音")
                Text(model.pitchLabel).font(.system(size: 15, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity).foregroundStyle(accent)
                Button { model.setPitch(model.semitones + 1) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .disabled(model.semitones >= PitchRenderer.range.upperBound).help("升高一个半音")
                Button("原调") { model.setPitch(0) }.disabled(model.semitones == 0)
            }.disabled(model.busy || model.loadingMedia || !model.mediaReady || model.accompanimentURL == nil)
            Text(model.preparingPitch ? "正在准备伴奏，完成后恢复原播放位置。" : "每格一个半音，范围 ±6；首次切换需稍候。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.isRecording ? StudioTheme.live : model.microphoneEnabled ? accent : Color.gray)
                .frame(width: 5, height: 5)
            if let progress = model.accompanimentProgress, let name = model.separatingModel?.rawValue {
                extractionStatus(progress, name: name)
            } else {
                Text(model.status).lineLimit(1)
            }
            Spacer()
            if model.microphoneEnabled {
                Text(model.audio.deviceDescription + "  ·  " + model.audio.bufferDescription)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 34)
    }

    private func extractionStatus(_ progress: AccompanimentExtractor.Progress, name: String) -> some View {
        let message = switch progress.phase {
        case .downloadingModel: "\(name) · 正在下载模型…"
        case .preparingModel: "\(name) · 正在准备模型…"
        case .loadingModel: "\(name) · 正在加载模型…"
        case .separating: "\(name) · 正在分离人声"
        case .saving: "正在合成并保存伴奏…"
        }
        return HStack(spacing: 8) {
            Text(message).lineLimit(1)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .controlSize(.small).frame(width: 100)
                    .accessibilityLabel("伴奏提取进度")
                Text("\(Int(fraction * 100))%").monospacedDigit()
                if progress.phase == .separating {
                    if let seconds = progress.remainingSeconds, seconds.isFinite, seconds > 0 {
                        Text("预计剩余 \(timeLabel(ceil(seconds)))").monospacedDigit()
                    } else {
                        Text("正在估算剩余时间…")
                    }
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }

    private func devicePicker(title: String, selection: Binding<UInt32>, devices: [AudioDevice]) -> some View {
        Picker(title, selection: selection) {
            if devices.isEmpty { Text("没有可用设备").tag(UInt32(0)) }
            ForEach(devices) { device in Text(device.name).tag(device.id) }
        }.font(.system(size: 11)).disabled(model.busy)
    }

    private func effectSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, label: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
}

private struct MovieSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct LevelMeter: View {
    let db: Float
    let clipping: Bool
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(0..<28) { index in
                    let threshold = -60 + Float(index) / 27 * 60
                    RoundedRectangle(cornerRadius: 1)
                        .fill(db > threshold ? (index > 25 ? StudioTheme.live : index > 21 ? StudioTheme.amber : accent) : StudioTheme.inset)
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.frame(height: 14).accessibilityLabel("输入电平 \(Int(db)) dBFS\(clipping ? "，过载" : "")")
    }
}
