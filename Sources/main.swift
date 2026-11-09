import AppKit
import SwiftUI
import Combine

struct AgentTask: Codable, Identifiable, Equatable {
    var id: String
    var agent: String
    var label: String
    var state: String
    var started: Double
    var pid: Int?
    var evidence: String
    var speed: TaskSpeed? = nil
    var flow: MessageFlow? = nil
}
struct TaskSpeed: Codable, Equatable {
    var status: String
    var detail: String
    var value: Double? = nil
    var measuredAt: Double? = nil
    var outputTokens: Int? = nil
    var durationMs: Double? = nil
}
struct Adapter: Codable, Identifiable, Equatable {
    var agent: String
    var status: String
    var detail: String
    var id: String { agent }
}
struct Snapshot: Codable {
    var schema: Int
    var updated: Double
    var tasks: [AgentTask]
    var adapters: [Adapter]
    var completions: [TaskCompletion]?
}

enum ThemeChoice: String, CaseIterable {
    case system, dark, light, paper
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色 · 夜航"
        case .light: return "浅色 · 晨光"
        case .paper: return "暖纸 · 午后"
        }
    }
}
struct Palette: Equatable {
    var background: Color
    var ink: Color
    var accent: Color
    var warning: Color
    var border: Color
    var isDark = false
    func text(_ opacity: Double) -> Color { ink.opacity(isDark ? opacity : max(0.64, opacity)) }
    static let dark = Palette(background: Color(red: 0.075, green: 0.095, blue: 0.09), ink: .white,
        accent: Color(red: 0.63, green: 0.90, blue: 0.75), warning: Color(red: 1, green: 0.78, blue: 0.45), border: .white.opacity(0.12), isDark: true)
    static let light = Palette(background: Color(red: 0.96, green: 0.985, blue: 0.975),
        ink: Color(red: 0.10, green: 0.18, blue: 0.15), accent: Color(red: 0.13, green: 0.46, blue: 0.32),
        warning: Color(red: 0.63, green: 0.35, blue: 0.08), border: .black.opacity(0.10))
    static let paper = Palette(background: Color(red: 1, green: 0.965, blue: 0.90),
        ink: Color(red: 0.27, green: 0.20, blue: 0.14), accent: Color(red: 0.49, green: 0.35, blue: 0.16),
        warning: Color(red: 0.71, green: 0.30, blue: 0.11), border: Color.brown.opacity(0.18))
}
let supportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AgentLantern", isDirectory: true)

final class Model: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var adapters: [Adapter] = []
    @Published var expanded = false
    @Published var quote = "你负责灵感，它们负责加班。"
    @Published var finished = false
    @Published var demo = false
    @Published var paused = false
    @Published var monitorHealthy = false
    @Published var theme = ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "dark") ?? .dark
    @Published var systemDark = false
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    @Published var fireworksEnabled = UserDefaults.standard.object(forKey: "fireworksEnabled") as? Bool ?? true
    @Published var animationsEnabled = UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true
    @Published var meteorEnabled = UserDefaults.standard.object(forKey: "meteorEnabled") as? Bool ?? true
    @Published var meteorStrength = min(0.6, max(0.15, UserDefaults.standard.object(forKey: "meteorStrength") as? Double ?? 0.25))
    @Published var auroraEnabled = UserDefaults.standard.object(forKey: "auroraEnabled") as? Bool ?? true
    @Published var auroraStrength = min(0.7, max(0.15, UserDefaults.standard.object(forKey: "auroraStrength") as? Double ?? 0.18))
    @Published var auroraLandscape = UserDefaults.standard.object(forKey: "auroraLandscape") as? Bool ?? true
    @Published var adaptiveAnimations = UserDefaults.standard.object(forKey: "adaptiveAnimations") as? Bool ?? true
    @Published private(set) var recentAnimationActivities = 0
    @Published var sessionActive = true
    @Published var detailPresented = false
    @Published var driftPresented = false
    @Published var showIdle = UserDefaults.standard.bool(forKey: "showIdle")
    @Published var quoteInterval = UserDefaults.standard.double(forKey: "quoteInterval") == 0
        ? 20.0 : UserDefaults.standard.double(forKey: "quoteInterval")
    var onChange: (() -> Void)?
    var onCompletions: (([TaskCompletion]) -> Void)?
    var onCompletionDecisions: (([CompletionDecision]) -> Void)?
    var collector: Process?
    var pipe: Pipe?
    var quoteTimer: Timer?
    var healthTimer: Timer?
    var hideWork: DispatchWorkItem?
    var buffer = Data()
    var lastUpdate = Date.distantPast
    var lastSnapshot: Snapshot?
    var phrases: [String] = []
    var restartWork: DispatchWorkItem?
    var shuttingDown = false
    var manualVisible = false
    var lastQuote = ""
    var completionGate = CompletionGate()
    var transferGate = TransferPlaybackGate()
    var animationActivity = AnimationActivityWindow()
    var lastFlowTask: AgentTask?
    let completionSound = NSSound(named: "Glass")
    let preview: Bool

    init(preview: Bool) {
        self.preview = preview
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let quotesURL = supportURL.appendingPathComponent("quotes.json")
        if !FileManager.default.fileExists(atPath: quotesURL.path),
           let resource = Bundle.main.url(forResource: "quotes", withExtension: "json") {
            try? FileManager.default.copyItem(at: resource, to: quotesURL)
        }
        loadQuotes()
        rotateQuote()
        startQuoteTimer()
        if preview {
            toggleDemo()
        } else {
            startCollector()
            healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastUpdate) > 15 {
                    self.monitorHealthy = false
                    self.tasks = []
                    self.finished = false
                    self.onChange?()
                }
            }
        }
    }

    var running: Int { tasks.filter { $0.state == "running" }.count }
    var animationTempo: AnimationTempo {
        adaptiveAnimations ? .resolve(running: running, recentActivities: recentAnimationActivities) : .calm
    }
    var visualTasks: [AgentTask] {
        if !tasks.isEmpty { return tasks }
        guard finished, var last = lastFlowTask else { return [] }
        last.state = "ended"
        last.speed = nil
        last.flow = nil
        return [last]
    }
    var waiting: Int { tasks.filter { $0.state == "waiting" }.count }
    var degraded: Bool { !monitorHealthy || adapters.contains { $0.status == "degraded" } }
    var effectiveDark: Bool { theme == .dark || (theme == .system && systemDark) }
    var palette: Palette { effectiveDark ? .dark : (theme == .paper ? .paper : .light) }
    var color: Color { waiting > 0 || degraded ? palette.warning : palette.accent }
    var activityPhase: ActivityPhase {
        if !monitorHealthy && !demo { return .connecting }
        if running > 0 { return .working }
        if waiting > 0 { return .waiting }
        if finished { return .completed }
        return degraded ? .connecting : .idle
    }
    var activityColor: Color { activityPhase == .waiting || activityPhase == .connecting ? palette.warning : palette.accent }
    var animateWork: Bool { animationsEnabled && shouldShow && sessionActive && detailPresented }
    var animateDrift: Bool { animationsEnabled && shouldShow && sessionActive && driftPresented }
    var title: String {
        if paused { return "已暂停显示" }
        if !monitorHealthy && !demo { return "正在连接任务状态" }
        if running > 0 { return "\(running) 个任务进行中" }
        if waiting > 0 { return "\(waiting) 个任务等你确认" }
        if finished { return "任务已结束" }
        if degraded { return "部分状态未确认" }
        return "此刻，暂时没有任务"
    }
    var subtitle: String {
        if demo { return "预览模式 · 示例任务" }
        let names = ["Codex", "Pi", "Hermes", "DeepSeek"].compactMap { name -> String? in
            let count = tasks.filter { $0.agent == name }.count
            return count > 0 ? "\(name) ×\(count)" : nil
        }
        if !names.isEmpty { return names.joined(separator: "  ·  ") }
        return finished ? "可以去看看它们的成果了" : "小灯在这里，等下一份灵感"
    }
    var shouldShow: Bool {
        !paused && (manualVisible || demo || showIdle || !tasks.isEmpty || finished || degraded)
    }

    func loadQuotes() {
        if let data = try? Data(contentsOf: supportURL.appendingPathComponent("quotes.json")),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            phrases = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 50 }
        }
        if phrases.isEmpty { phrases = ["你负责灵感，它们负责加班。", "事情正在向前，你可以伸个懒腰。"] }
    }
    func rotateQuote() {
        guard shouldShow || preview else { return }
        loadQuotes()
        let choices = phrases.filter { $0 != lastQuote }
        let next = choices.randomElement() ?? phrases[0]
        lastQuote = next
        withAnimation(.easeInOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.45)) {
            quote = next
        }
    }
    func startQuoteTimer() {
        quoteTimer?.invalidate()
        UserDefaults.standard.set(quoteInterval, forKey: "quoteInterval")
        quoteTimer = Timer.scheduledTimer(withTimeInterval: quoteInterval, repeats: true) { [weak self] _ in
            self?.rotateQuote()
        }
    }

    func startCollector() {
        guard !shuttingDown, let script = Bundle.main.url(forResource: "collector", withExtension: "py") else { return }
        let p = Process()
        completionGate = CompletionGate()
        transferGate = TransferPlaybackGate()
        animationActivity = AnimationActivityWindow()
        recentAnimationActivities = 0
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", script.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        collector = p
        pipe = out
        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown else { return }
                self.monitorHealthy = false
                self.tasks = []
                self.finished = false
                self.onChange?()
                let work = DispatchWorkItem { [weak self] in self?.startCollector() }
                self.restartWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
        do { try p.run() }
        catch { monitorHealthy = false; onChange?() }
    }
    func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let snap = try? JSONDecoder().decode(Snapshot.self, from: line), snap.schema == 1 {
                // A degraded adapter can still report a verified completion from another healthy task.
                let observedAgents = Set(snap.adapters.filter { ["ready", "degraded"].contains($0.status) }.map { $0.agent })
                let completed = (snap.completions ?? []).filter { observedAgents.contains($0.agent) }
                let fresh = completionGate.consumeFresh(completed, at: snap.updated, enabled: !demo)
                if !fresh.isEmpty && soundEnabled {
                    playCompletionSound()
                }
                lastSnapshot = snap
                lastUpdate = Date()
                if !demo { apply(snap) }
                if !completionGate.decisions.isEmpty { onCompletionDecisions?(completionGate.decisions) }
                if !fresh.isEmpty { onCompletions?(fresh) }
            }
        }
        if buffer.count > 2_000_000 { buffer.removeAll() }
    }
    func apply(_ snapshot: Snapshot) {
        let hadTasks = !tasks.isEmpty
        if let last = tasks.first { lastFlowTask = last }
        monitorHealthy = true
        var incoming = snapshot.tasks
        for index in incoming.indices where incoming[index].flow == nil {
            if let speed = incoming[index].speed, speed.status == "recent", let at = speed.measuredAt {
                incoming[index].flow = MessageFlow(phase: "response", at: at, detail: speed.detail,
                    transfers: [FlowTransfer(id: "response:\(at)", kind: "response", at: at)])
            }
        }
        let playback = transferGate.consume(incoming.map {
            TransferBatch(task: $0.id, started: $0.started, events: $0.flow?.transfers ?? [])
        }, at: snapshot.updated)
        for index in incoming.indices {
            let id = incoming[index].id
            incoming[index].flow?.playback = playback[id]
        }
        let activityNow = Date().timeIntervalSince1970
        if snapshot.updated.isFinite && abs(activityNow - snapshot.updated) <= 15 {
            let observed = Set(incoming.flatMap { task in
                // Count validated observation metadata, not the deliberately
                // throttled playback queue, so real bursts are not collapsed.
                (task.flow?.transfers ?? []).filter { $0.isRecent(started: task.started, now: snapshot.updated) }.map {
                    AnimationActivity(task: task.id, event: $0.id)
                }
            })
            let count = animationActivity.update(running: Set(incoming.filter { $0.state == "running" }.map { $0.id }),
                                                 observed: observed, at: activityNow)
            if recentAnimationActivities != count { recentAnimationActivities = count }
        } else {
            animationActivity = AnimationActivityWindow()
            recentAnimationActivities = 0
        }
        tasks = incoming
        adapters = snapshot.adapters
        if !tasks.isEmpty {
            lastFlowTask = tasks.first
            hideWork?.cancel()
            finished = false
            manualVisible = false
        } else if hadTasks && !degraded {
            finished = true
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.finished = false
                self?.expanded = false
                self?.onChange?()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
        onChange?()
    }
    func toggleDemo() {
        hideWork?.cancel()
        finished = false
        animationActivity = AnimationActivityWindow()
        recentAnimationActivities = 0
        demo.toggle()
        if demo {
            monitorHealthy = true
            let now = Date().timeIntervalSince1970
            tasks = [AgentTask(id: "demo:1", agent: "Codex", label: "整理项目里的新想法", state: "running", started: now - 83, evidence: "示例"),
                     AgentTask(id: "demo:2", agent: "Pi", label: "把灵感变成作品", state: "running", started: now - 36, evidence: "示例"),
                     AgentTask(id: "demo:3", agent: "Hermes", label: "等待你的一个决定", state: "waiting", started: now - 112, evidence: "示例")]
            tasks.append(AgentTask(id: "demo:4", agent: "DeepSeek", label: "Harness · 正在实现新想法", state: "running", started: now - 52, evidence: "示例"))
            tasks[0].speed = TaskSpeed(status: "unavailable", detail: "示例：当前 Codex 本地记录缺少完整请求计时，显示不可用")
            tasks[1].speed = TaskSpeed(status: "live", detail: "示例：流式增量 token 计数得到的实时速度", value: 42.8, measuredAt: now)
            tasks[2].speed = TaskSpeed(status: "recent", detail: "示例：最近一次响应均速，包含首 token 等待，不包含工具执行", value: 28.6, measuredAt: now)
            tasks[3].speed = TaskSpeed(status: "unavailable", detail: "示例：DeepSeek Harness 已接入任务运行检测")
            tasks.sort { $0.agent < $1.agent }
            adapters = ["Codex", "Pi", "Hermes", "DeepSeek"].map { Adapter(agent: $0, status: "ready", detail: "预览示例") }
            quote = "你负责灵感，它们负责加班。"
        } else {
            tasks = []
            if let snap = lastSnapshot { apply(snap) }
            else { monitorHealthy = false }
        }
        onChange?()
    }
    @discardableResult func playCompletionSound(force: Bool = false) -> Bool {
        guard force || (soundEnabled && !demo), let sound = completionSound else { return false }
        if sound.isPlaying { sound.stop() }
        sound.volume = 0.45
        return sound.play()
    }
    func stop() {
        shuttingDown = true
        quoteTimer?.invalidate()
        healthTimer?.invalidate()
        hideWork?.cancel()
        restartWork?.cancel()
        pipe?.fileHandleForReading.readabilityHandler = nil
        collector?.terminationHandler = nil
        if collector?.isRunning == true { collector?.terminate() }
    }
}

struct LanternView: View {
    static let compactWidth: CGFloat = 278
    static let detailWidth: CGFloat = 334
    @ObservedObject var model: Model
    var openMenu: () -> Void
    var returnToDrift: (() -> Void)? = nil
    var palette: Palette { model.palette }
    // Only decorative canvas children observe frames; the panel stays event-driven.
    @State private var windClock = WindClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WorkingLight(color: model.activityColor, warning: palette.warning, phase: model.activityPhase,
                             hasWaiting: model.waiting > 0, animationsEnabled: model.animateWork)
                    .scaleEffect(0.83).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("小灯").font(.system(size: 12, weight: .semibold)).tracking(1.5)
                            .foregroundStyle(palette.text(0.44))
                        if model.demo { Text("预览").font(.system(size: 11)).foregroundStyle(palette.warning) }
                    }
                    HStack(spacing: 7) {
                        Text(model.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text(0.94))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        if model.activityPhase == .working {
                            WorkingSignal(color: palette.accent, animationsEnabled: model.animateWork)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: openMenu) {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.text(0.55)).frame(width: 26, height: 26)
                }.buttonStyle(.plain).help("小灯设置")
            }
            .padding(.top, 12).padding(.horizontal, 12)

            Button {
                model.expanded.toggle()
                model.onChange?()
            } label: {
                HStack(spacing: 5) {
                    Text(model.subtitle).lineLimit(1)
                    Spacer(minLength: 0)
                    if model.waiting > 0 && model.running > 0 {
                        Text("\(model.waiting) 个待确认").foregroundStyle(palette.warning)
                    }
                    Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 12)).foregroundStyle(palette.text(0.60))
                .contentShape(Rectangle()).padding(.vertical, 8)
            }.buttonStyle(.plain).padding(.horizontal, 16)
                .accessibilityLabel(model.expanded ? "收起任务详情" : "展开任务详情")

            if !model.visualTasks.isEmpty && !model.expanded {
                MessageFlowCarousel(tasks: model.visualTasks, palette: palette, animationsEnabled: model.animateWork, windClock: windClock, demo: model.demo)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1).padding(.horizontal, 16)

            HStack(alignment: .center, spacing: 8) {
                Text("“").font(.system(size: 25, weight: .light, design: .serif)).foregroundStyle(palette.accent.opacity(0.5))
                Text(model.quote).id(model.quote)
                    .font(.system(size: 13, weight: .regular)).foregroundStyle(palette.text(0.85))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                Spacer(minLength: 0)
            }.frame(height: 48).padding(.horizontal, 16)

            if let returnToDrift {
                Button(action: returnToDrift) {
                    Label("收起，继续漂浮", systemImage: "wind")
                        .font(.system(size: 12)).foregroundStyle(palette.text(0.65))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.plain).padding(.horizontal, 16)
            }

            if model.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if model.visualTasks.isEmpty {
                                Text("新任务开始时，小灯会自动亮起。")
                                    .font(.system(size: 13)).foregroundStyle(palette.text(0.6))
                            }
                            ForEach(model.visualTasks) { task in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top, spacing: 9) {
                                        Circle().fill(task.state == "waiting" ? palette.warning : palette.accent)
                                            .frame(width: 5, height: 5).padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(task.agent).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text(0.85))
                                                Spacer()
                                                Text(task.state == "ended" ? "已结束" : task.state == "waiting" ? "等你确认" : "进行中")
                                                    .font(.system(size: 12)).foregroundStyle(task.state == "waiting" ? palette.warning : palette.accent)
                                                if task.started > 0 && task.state != "ended" {
                                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                                        Text(elapsed(context.date.timeIntervalSince1970 - task.started))
                                                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.text(0.55))
                                                    }
                                                }
                                            }
                                            HStack(spacing: 8) {
                                                Text(task.label).font(.system(size: 13)).foregroundStyle(palette.text(0.60))
                                                    .lineLimit(1).truncationMode(.middle)
                                                Spacer(minLength: 0)
                                                SpeedBadge(speed: task.speed, palette: palette, demo: model.demo)
                                                    .layoutPriority(1)
                                            }
                                        }
                                    }.help(task.evidence)
                                    MessageFlowView(task: task, palette: palette, animationsEnabled: model.animateWork,
                                                    windClock: windClock, demo: model.demo, detailed: true)
                                }
                            }
                        }.padding(.vertical, 15)
                    }.frame(height: min(CGFloat(max(model.visualTasks.count, 1)) * 285 + 30, 350))
                    Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.adapters) { adapter in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(adapter.status == "ready" ? palette.accent.opacity(0.7) : palette.warning.opacity(0.8))
                                    .frame(width: 4, height: 4).padding(.top, 4)
                                Text(adapter.agent).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 62, alignment: .leading)
                                Text(adapter.detail).font(.system(size: 12)).foregroundStyle(palette.text(0.60))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.foregroundStyle(palette.text(0.6))
                        }
                    }.padding(.vertical, 13)
                }.padding(.horizontal, 21)
            }
        }
        .padding(.bottom, 5)
        .frame(width: model.expanded ? Self.detailWidth : Self.compactWidth)
        .background {
            ZStack {
                palette.background
                if model.auroraEnabled {
                    AuroraBackgroundView(clock: windClock, palette: palette,
                                         strength: model.auroraStrength, landscape: model.auroraLandscape)
                }
                WindBackdropView(clock: windClock, palette: palette)
                if model.meteorEnabled {
                    MeteorBackgroundView(clock: windClock, palette: palette,
                                         moving: model.animateWork && !reduceMotion,
                                         strength: model.meteorStrength)
                }
                // Restore a quiet surface beneath the header and quote while
                // keeping the large rotor clear in the middle of the window.
                LinearGradient(stops: [
                    .init(color: palette.background, location: 0),
                    .init(color: palette.background.opacity(0), location: 0.28),
                    .init(color: palette.background.opacity(0), location: 0.68),
                    .init(color: palette.background.opacity(0.72), location: 0.82),
                    .init(color: palette.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            }.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(palette.border, lineWidth: 0.7))
        .environment(\.colorScheme, model.effectiveDark ? .dark : .light)
        .onAppear { configureWind() }
        .onChange(of: model.animateWork) { _, _ in configureWind() }
        .onChange(of: model.activityPhase) { _, _ in configureWind() }
        .onChange(of: model.visualTasks.count) { _, _ in configureWind() }
        .onChange(of: model.meteorEnabled) { _, _ in configureWind() }
        .onChange(of: model.auroraEnabled) { _, _ in configureWind() }
        .onChange(of: model.animationTempo) { _, _ in configureWind() }
        .onChange(of: reduceMotion) { _, _ in configureWind() }
        .onDisappear { windClock.configure(enabled: false, phase: model.activityPhase) }
    }
    private func configureWind() {
        windClock.configure(enabled: model.animateWork && !reduceMotion,
                            phase: model.activityPhase, tempo: model.animationTempo)
    }
    func elapsed(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(value % 60)s" }
        return "\(value / 3600)h \((value % 3600) / 60)m"
    }
}

struct SpeedBadge: View {
    var speed: TaskSpeed?
    var palette: Palette
    var demo: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.timeIntervalSince1970
            let fresh = demo || (speed?.measuredAt.map { now - $0 <= (speed?.status == "live" ? 4 : 300) } ?? true)
            let valid = fresh && (speed?.value.map { $0.isFinite && $0 > 0 } ?? false)
            Text(label(valid: valid))
                .font(.system(size: 12, weight: valid ? .medium : .regular)).monospacedDigit()
                .foregroundStyle(valid && speed?.status == "live" ? palette.accent : palette.text(valid ? 0.65 : 0.45))
                .lineLimit(1)
                .help(speed?.detail ?? "尚未接入此任务的 TPS 数据，不将整个任务耗时作为生成耗时")
        }
    }
    func label(valid: Bool) -> String {
        if valid, let speed, let value = speed.value, ["live", "recent"].contains(speed.status) {
            return String(format: "%.1f TPS · %@", value, speed.status == "live" ? "实时" : "均速")
        }
        switch speed?.status {
        case "sampling", "live", "recent": return "TPS 采样中"
        case "tools": return "TPS — · 工具中"
        case "reload": return "TPS 待接入"
        default: return "TPS —"
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: screen)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var hosting: NSHostingView<LanternView>!
    var model: Model!
    var item: NSStatusItem!
    var menu: NSMenu!
    var changingFrame = false
    var workspaceObservers: [NSObjectProtocol] = []
    var frameTimer: Timer?
    var driftPanel: FloatingPanel!
    var driftHosting: NSHostingView<DriftLightView>!
    var completionPanel: FloatingPanel!
    var celebrationPanel: FloatingPanel!
    let celebrationDisplay = CelebrationDisplay()
    var celebrationTimer: Timer?
    var celebrationScreenID: CGDirectDisplayID?
    var completionDiagnostics: [[String: Any]] = []
    var driftMotion: DriftMotion?
    var driftScreenID: CGDirectDisplayID?
    var driftTimer: Timer?
    var environmentTimer: Timer?
    var driftEnabled = true
    var driftArea: DriftArea = .edges
    var detailOpen = false
    var fullScreenSuppressed = false
    var explicitFullScreenDetails = false
    var menuTracking = false
    var previousFinished = false
    var completionDeadline: Double = 0
    var userSessionActive = true
    var displayAwake = true
    var screenLocked = false
    let args = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One GUI instance; opening again brings the existing app's panel back.
        if !args.contains("--preview"), NSRunningApplication.runningApplications(withBundleIdentifier: "local.agentlantern.desktop")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        model = Model(preview: args.contains("--preview"))
        driftEnabled = model.preview ? args.contains("--preview-drift") :
            (UserDefaults.standard.object(forKey: "driftEnabled") as? Bool ?? true)
        if model.preview {
            if let index = args.firstIndex(of: "--preview-drift-area"), args.indices.contains(index + 1),
               let area = DriftArea(rawValue: args[index + 1]) { driftArea = area }
        } else {
            driftArea = UserDefaults.standard.string(forKey: "driftArea").flatMap(DriftArea.init(rawValue:)) ?? .edges
        }
        systemAppearanceChanged()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // Command-line theme overrides are only for artifact rendering; they do not change saved preferences.
        if let index = args.firstIndex(of: "--theme"), args.indices.contains(index + 1),
           let theme = ThemeChoice(rawValue: args[index + 1]) { model.theme = theme }
        if model.preview && args.contains("--preview-no-meteors") { model.meteorEnabled = false }
        if model.preview && args.contains("--preview-no-aurora") { model.auroraEnabled = false }
        if model.preview && args.contains("--preview-no-landscape") { model.auroraLandscape = false }
        if model.preview && args.contains("--preview-fixed-tempo") { model.adaptiveAnimations = false }
        if model.preview, let index = args.firstIndex(of: "--preview-state"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "waiting": model.tasks = model.tasks.map { var task = $0; task.state = "waiting"; return task }
            case "idle": model.tasks = []
            case "completed": model.lastFlowTask = model.tasks.first; model.tasks = []; model.finished = true
            default: break
            }
        }
        if model.preview, let index = args.firstIndex(of: "--preview-flow"), args.indices.contains(index + 1),
           ["request", "awaiting", "receiving", "response", "tools", "processing", "unknown"].contains(args[index + 1]) {
            model.tasks = model.tasks.map { task in
                var value = task
                value.flow = MessageFlow(phase: args[index + 1], at: Date().timeIntervalSince1970, detail: "演示动画")
                return value
            }
        }
        if model.preview && args.contains("--preview-transfers") {
            let now = Date().timeIntervalSince1970
            model.tasks = model.tasks.map { task in
                var value = task
                value.flow = MessageFlow(phase: "tools", at: now, detail: "近期事件演示", playback: [
                    TransferPulse(id: "demo-response", kind: "response", began: now),
                    TransferPulse(id: "demo-context", kind: "context", began: now + 2.5)
                ])
                return value
            }
        }
        if model.preview && args.contains("--preview-single") { model.tasks = Array(model.tasks.prefix(1)) }
        if model.preview, let index = args.firstIndex(of: "--preview-task-count"), args.indices.contains(index + 1),
           let count = Int(args[index + 1]), (1...12).contains(count), let first = model.tasks.first {
            model.tasks = (0..<count).map { index in
                var task = first; task.id = "tempo-demo-\(index)"; return task
            }
        }
        if args.contains("--no-animation") { model.animationsEnabled = false }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.sessionDidResignActiveNotification { self.userSessionActive = false }
                else { self.displayAwake = false }
                self.updateSessionVisibility()
            })
        }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.explicitFullScreenDetails = false
                self?.updateEnvironment()
            })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateEnvironment()
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.sessionDidBecomeActiveNotification { self.userSessionActive = true }
                else { self.displayAwake = true }
                self.updateSessionVisibility()
            })
        }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: LanternView.compactWidth, height: 138),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "小灯 · 智能体工作灯"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        hosting = NSHostingView(rootView: makeDetailView())
        panel.contentView = hosting
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = UserDefaults.standard.object(forKey: "panelX") as? Double ?? screen.maxX - LanternView.compactWidth - 26
        let y = UserDefaults.standard.object(forKey: "panelTop") as? Double ?? screen.maxY - 65
        let savedFrame = NSRect(x: x, y: y - 138, width: LanternView.compactWidth, height: 138)
        panel.setFrame(visiblePanelFrame(savedFrame), display: false)
        setupDriftPanel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "智能体工作灯")
        item.button?.target = self
        item.button?.action = #selector(statusClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.onChange = { [weak self] in self?.refresh() }
        model.onCompletions = { [weak self] events in self?.showCelebration(events: events) }
        model.onCompletionDecisions = { [weak self] decisions in
            for decision in decisions { self?.recordCompletionDiagnostic("event", fields: ["agent": decision.agent, "age": decision.age, "decision": decision.reason]) }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(diagnoseRunning),
            name: NSNotification.Name("local.agentlantern.diagnose"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(previewRunningFireworks(_:)),
            name: NSNotification.Name("local.agentlantern.preview-fireworks"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(movePanelToPrimaryScreen),
            name: NSNotification.Name("local.agentlantern.move-primary"), object: nil)
        model.manualVisible = true
        refresh()
        environmentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateEnvironment()
        }
        updateEnvironment()
        if model.preview && args.contains("--preview-fireworks") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.previewFireworks() }
        }
        if model.preview, let index = args.firstIndex(of: "--verify-fireworks"), args.indices.contains(index + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.verifyFireworks(path: self?.args[index + 1] ?? "")
                NSApp.terminate(nil)
            }
        }
        if !model.preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.detailOpen else { return }
                self.model.manualVisible = false
                self.refresh()
            }
        }
        if model.preview && args.contains("--expanded") { detailOpen = true; model.expanded = true; refresh() }
        if model.preview && args.contains("--preview-details") { showPanel() }
        if model.preview, let index = args.firstIndex(of: "--verify-drift"), args.indices.contains(index + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.verifyDrift(path: self?.args[index + 1] ?? "")
                NSApp.terminate(nil)
            }
        }
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveSnapshot(path: self?.args[index + 1] ?? "")
                NSApp.terminate(nil)
            }
        }
        if let index = args.firstIndex(of: "--record-frames"), args.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var frame = 0
            let requestedFrames = args.firstIndex(of: "--frame-count").flatMap { index in
                args.indices.contains(index + 1) ? Int(args[index + 1]) : nil
            } ?? 36
            let frameCount = min(240, max(12, requestedFrames))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
                    self?.saveSnapshot(path: directory.appendingPathComponent(String(format: "frame-%03d.png", frame)).path)
                    frame += 1
                    if frame >= frameCount { timer.invalidate(); NSApp.terminate(nil) }
                }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateEnvironment()
    }
    private func makeDetailView() -> LanternView {
        LanternView(model: model, openMenu: { [weak self] in self?.showMenu() },
                    returnToDrift: driftEnabled ? { [weak self] in self?.resumeDrift() } : nil)
    }
    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func updateSessionVisibility() {
        model.sessionActive = userSessionActive && displayAwake && !screenLocked
        updateEnvironment()
    }
    @objc private func screenDidLock() {
        screenLocked = true
        updateSessionVisibility()
    }
    @objc private func screenDidUnlock() {
        screenLocked = false
        updateSessionVisibility()
    }
    private var currentDriftScreen: NSScreen? {
        NSScreen.screens.first(where: { screenID($0) == driftScreenID }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func setupDriftPanel() {
        driftPanel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        driftPanel.title = "小灯 · 桌面游光"
        driftPanel.backgroundColor = .clear
        driftPanel.isOpaque = false
        driftPanel.hasShadow = false
        driftPanel.level = .floating
        driftPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        driftPanel.ignoresMouseEvents = true
        driftPanel.isMovable = false
        driftPanel.hidesOnDeactivate = false
        driftPanel.isReleasedWhenClosed = false
        driftHosting = NSHostingView(rootView: DriftLightView(model: model))
        driftPanel.contentView = driftHosting
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(panel.frame.origin) }) ?? NSScreen.main {
            driftScreenID = screenID(screen)
            driftMotion = DriftMotion(screen: screen.visibleFrame, area: driftArea)
        }
        completionPanel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        completionPanel.backgroundColor = .clear
        completionPanel.isOpaque = false
        completionPanel.hasShadow = false
        completionPanel.level = .floating
        completionPanel.collectionBehavior = driftPanel.collectionBehavior
        completionPanel.ignoresMouseEvents = true
        completionPanel.isReleasedWhenClosed = false
        completionPanel.contentView = NSHostingView(rootView: DriftCompletionView(model: model))
        celebrationPanel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        celebrationPanel.title = "小灯 · 烟花谢幕"
        celebrationPanel.backgroundColor = .clear
        celebrationPanel.isOpaque = false
        celebrationPanel.hasShadow = false
        celebrationPanel.level = .floating
        celebrationPanel.collectionBehavior = driftPanel.collectionBehavior
        celebrationPanel.ignoresMouseEvents = true
        celebrationPanel.isMovable = false
        celebrationPanel.hidesOnDeactivate = false
        celebrationPanel.isReleasedWhenClosed = false
        celebrationPanel.contentView = NSHostingView(rootView: CelebrationView(display: celebrationDisplay))
    }
    private func showCelebration(events: [TaskCompletion], demo: Bool = false, allEnded: Bool? = nil) {
        if let reason = celebrationSuppression {
            recordCompletionDiagnostic("suppressed", fields: ["reason": reason, "count": events.count]); return
        }
        guard model.fireworksEnabled, !model.paused, model.sessionActive, !fullScreenSuppressed,
              let screen = model.driftPresented ? currentDriftScreen :
                NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }) ?? NSScreen.main,
              !events.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let ended = allEnded ?? (model.tasks.isEmpty && !model.degraded)
        let remaining = demo ? (ended ? 0 : 2) : model.tasks.count
        let waiting = demo ? 0 : model.waiting
        if var show = celebrationDisplay.show, show.demo == demo, show.isActive(at: now) {
            show.merge(events: events, remaining: remaining, waiting: waiting, allEnded: ended, at: now)
            celebrationDisplay.show = show
        } else {
            celebrationDisplay.renderProbe.reset()
            celebrationDisplay.show = CompletionCelebration(events: events, remaining: remaining, waiting: waiting,
                                                            allEnded: ended, at: now, demo: demo)
            celebrationScreenID = screenID(screen)
            let source = model.driftPresented ? CGPoint(x: driftPanel.frame.midX, y: driftPanel.frame.midY) :
                CGPoint(x: panel.frame.minX + 42, y: panel.frame.maxY - 48)
            celebrationDisplay.source = CompletionCelebration.source(lightCenter: source, screen: screen.visibleFrame)
        }
        driftMotion?.pause()
        if celebrationTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateCelebration() }
            RunLoop.main.add(timer, forMode: .common)
            celebrationTimer = timer
        }
        updateCelebration()
        updateCompletionBubble()
        recordCompletionDiagnostic("playback", fields: ["demo": demo, "count": events.count,
            "bursts": celebrationDisplay.show?.bursts.count ?? 0, "screen": NSStringFromRect(screen.visibleFrame),
            "source": NSStringFromPoint(celebrationDisplay.source)])
    }
    private var celebrationSuppression: String? {
        if !model.fireworksEnabled { return "fireworks-disabled" }
        if model.paused { return "display-paused" }
        if !model.sessionActive { return "session-inactive" }
        if fullScreenSuppressed { return "fullscreen" }
        return nil
    }
    private func recordCompletionDiagnostic(_ stage: String, fields: [String: Any] = [:]) {
        var entry = fields
        entry["stage"] = stage; entry["at"] = Date().timeIntervalSince1970
        completionDiagnostics.append(entry)
        completionDiagnostics = Array(completionDiagnostics.suffix(40))
        writeCompletionDiagnostics()
    }
    @objc private func diagnoseRunning() { writeCompletionDiagnostics() }
    @objc private func previewRunningFireworks(_ notification: Notification) {
        let event = TaskCompletion(id: UUID().uuidString, agent: "Codex", label: "烟花效果预览", at: Date().timeIntervalSince1970)
        showCelebration(events: [event], demo: true, allEnded: notification.userInfo?["single"] as? Bool != true)
    }
    private func writeCompletionDiagnostics() {
        guard !model.preview else { return }
        let snapshot: [String: Any] = ["updated": Date().timeIntervalSince1970,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "fireworksEnabled": model.fireworksEnabled, "animationsEnabled": model.animationsEnabled,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "sessionActive": model.sessionActive, "paused": model.paused, "demo": model.demo,
            "monitorHealthy": model.monitorHealthy, "fullscreen": fullScreenSuppressed,
            "tasks": model.tasks.count, "driftFrame": NSStringFromRect(driftPanel.frame),
            "playbackVisible": celebrationPanel.isVisible, "render": celebrationDisplay.renderProbe.snapshot,
            "records": completionDiagnostics]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        let file = supportURL.appendingPathComponent("completion-diagnostics.json")
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func stopCelebration() {
        celebrationTimer?.invalidate(); celebrationTimer = nil
        celebrationDisplay.show = nil
        celebrationDisplay.previewAge = nil
        celebrationPanel?.orderOut(nil)
        driftMotion?.pause()
        recordCompletionDiagnostic("stopped")
    }
    private func updateCelebration() {
        guard let show = celebrationDisplay.show else { return }
        guard model.fireworksEnabled, !model.paused, model.sessionActive, !fullScreenSuppressed,
              show.demo || (model.monitorHealthy && !model.demo),
              show.isActive(at: ProcessInfo.processInfo.systemUptime),
              let screen = NSScreen.screens.first(where: { screenID($0) == celebrationScreenID }) else {
            stopCelebration(); return
        }
        if !show.demo {
            var updated = show
            updated.updateRemaining(model.tasks.count, waiting: model.waiting, allEnded: model.tasks.isEmpty && !model.degraded)
            if updated != show { celebrationDisplay.show = updated }
        }
        let moving = model.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if celebrationDisplay.moving != moving { celebrationDisplay.moving = moving }
        if celebrationDisplay.palette != model.palette { celebrationDisplay.palette = model.palette }
        celebrationPanel.setFrame(screen.visibleFrame, display: true)
        if !celebrationPanel.isVisible { celebrationPanel.orderFrontRegardless() }
    }
    private func updateEnvironment() {
        guard driftPanel != nil else { return }
        if let screen = currentDriftScreen {
            driftScreenID = screenID(screen)
            driftMotion?.setScreen(screen.visibleFrame)
        }
        // Only public window bounds and the frontmost PID are needed; no titles or screen images.
        fullScreenSuppressed = !model.preview && frontmostIsFullScreen()
        refresh()
    }
    private func frontmostIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds) else { return false }
            let cocoa = CGRect(x: quartz.minX, y: primaryTop - quartz.maxY, width: quartz.width, height: quartz.height)
            return NSScreen.screens.contains { DriftScreenPolicy.isFullScreen(window: cocoa, screen: $0.frame) }
        }
    }
    private func updateDriftTimer(visible: Bool) {
        guard visible else {
            driftTimer?.invalidate(); driftTimer = nil
            driftMotion?.pause()
            return
        }
        let enabled = model.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let interval = enabled ? 1.0 / 30 : 0.2
        if let driftTimer, abs(driftTimer.timeInterval - interval) < 0.001 { return }
        driftTimer?.invalidate()
        driftMotion?.pause()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tickDrift() }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }
    private func tickDrift() {
        guard model.driftPresented, !menuTracking, model.sessionActive, !fullScreenSuppressed,
              celebrationDisplay.show == nil else {
            driftMotion?.pause()
            return
        }
        let enabled = model.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mouse = NSEvent.mouseLocation
        driftMotion?.advance(at: ProcessInfo.processInfo.systemUptime, mouse: mouse,
                             working: model.running > 0, enabled: enabled)
        if let motion = driftMotion {
            driftPanel.setFrameOrigin(motion.frame.origin)
            let near = hypot(mouse.x - motion.center.x, mouse.y - motion.center.y) < 90
            let alpha: CGFloat = near ? 0.22 : 0.88
            if driftPanel.alphaValue != alpha { driftPanel.alphaValue = alpha }
        }
        updateCompletionBubble()
    }
    private func updateCompletionBubble() {
        guard completionPanel != nil else { return }
        guard celebrationDisplay.show == nil, model.driftPresented, model.finished, ProcessInfo.processInfo.systemUptime < completionDeadline,
              let screen = currentDriftScreen else { completionPanel.orderOut(nil); return }
        let light = driftPanel.frame
        let y = light.maxY + 42 < screen.visibleFrame.maxY ? light.maxY + 6 : light.minY - 40
        let bubble = CGRect(x: light.midX - 87, y: y, width: 174, height: 34)
        completionPanel.setFrame(WindowPlacement.visibleFrame(bubble, screens: [screen.visibleFrame], fallbackIndex: 0), display: true)
        completionPanel.orderFrontRegardless()
    }
    private func visiblePanelFrame(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        let fallback = NSScreen.main.flatMap { screens.firstIndex(of: $0) } ?? 0
        return WindowPlacement.visibleFrame(frame, screens: screens.map(\.visibleFrame), fallbackIndex: fallback)
    }
    func refresh() {
        guard panel != nil else { return }
        if !model.shouldShow { detailOpen = false }
        let allowed = model.shouldShow && model.sessionActive
        let detailVisible = allowed && (!fullScreenSuppressed || explicitFullScreenDetails) && (!driftEnabled || detailOpen)
        let driftVisible = allowed && !fullScreenSuppressed && driftEnabled && !detailOpen
        if model.detailPresented != detailVisible { model.detailPresented = detailVisible }
        if model.driftPresented != driftVisible { model.driftPresented = driftVisible }
        if model.finished && !previousFinished { completionDeadline = ProcessInfo.processInfo.systemUptime + 3.5 }
        previousFinished = model.finished
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        let current = panel.frame
        let width = model.expanded ? LanternView.detailWidth : LanternView.compactWidth
        let proposed = NSRect(x: current.minX, y: current.maxY - height, width: width, height: height)
        let rect = visiblePanelFrame(proposed)
        changingFrame = true
        panel.setFrame(rect, display: true, animate: false)
        changingFrame = false
        if detailVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        if driftVisible {
            if let frame = driftMotion?.frame { driftPanel.setFrame(frame, display: true) }
            driftPanel.orderFrontRegardless()
        } else { driftPanel?.orderOut(nil) }
        updateDriftTimer(visible: driftVisible)
        updateCompletionBubble()
        updateCelebration()
        let count = model.tasks.count
        item.button?.title = model.demo ? " 示例" : (count > 0 ? " \(count)" : "")
        item.button?.toolTip = "小灯 · " + model.title + "\n点击查看详情，右键打开设置"
    }
    func windowDidMove(_ notification: Notification) {
        guard !changingFrame else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: "panelX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "panelTop")
    }
    func rebuildMenu() {
        menu = NSMenu()
        add("小灯 · 智能体工作灯", nil).isEnabled = false
        add(model.demo ? "预览模式（示例任务）" : model.title, nil).isEnabled = false
        menu.addItem(.separator())
        add("查看任务详情", #selector(showPanel))
        if driftEnabled { add("收起详情，继续漂浮", #selector(resumeDrift)) }
        add("桌面漂浮", #selector(toggleDrift)).state = driftEnabled ? .on : .off
        let areaParent = add("漂浮范围", nil)
        let areas = NSMenu()
        for (index, area) in DriftArea.allCases.enumerated() {
            let entry = NSMenuItem(title: area.title, action: #selector(changeDriftArea(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = driftArea == area ? .on : .off
            areas.addItem(entry)
        }
        areaParent.submenu = areas
        add("移回主屏幕", #selector(movePanelToPrimaryScreen))
        add("空闲时也显示", #selector(toggleIdle)).state = model.showIdle ? .on : .off
        add(model.paused ? "恢复显示" : "暂停显示", #selector(togglePaused))
        add(model.demo ? "退出预览" : "预览浮窗（示例）", #selector(togglePreview))
        menu.addItem(.separator())
        let themeParent = add("主题", nil)
        let themes = NSMenu()
        for (index, theme) in ThemeChoice.allCases.enumerated() {
            let entry = NSMenuItem(title: theme.title, action: #selector(changeTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = model.theme == theme ? .on : .off
            themes.addItem(entry)
        }
        themeParent.submenu = themes
        add("工作动画", #selector(toggleAnimations)).state = model.animationsEnabled ? .on : .off
        add("随忙碌程度加速", #selector(toggleAdaptiveAnimations)).state = model.adaptiveAnimations ? .on : .off
        add("当前节奏：\(model.animationTempo.title)", nil).isEnabled = false
        add("流星背景", #selector(toggleMeteors)).state = model.meteorEnabled ? .on : .off
        let meteorParent = add("流星亮度", nil)
        let meteorMenu = NSMenu()
        for percent in [15, 25, 40, 60] {
            let entry = NSMenuItem(title: "\(percent)%", action: #selector(changeMeteorStrength(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = percent
            entry.state = abs(model.meteorStrength - Double(percent) / 100) < 0.001 ? .on : .off
            meteorMenu.addItem(entry)
        }
        meteorParent.submenu = meteorMenu
        add("极光帷幕", #selector(toggleAurora)).state = model.auroraEnabled ? .on : .off
        let auroraParent = add("极光强度", nil)
        let auroraMenu = NSMenu()
        for percent in [15, 18, 30, 45, 70] {
            let entry = NSMenuItem(title: "\(percent)%", action: #selector(changeAuroraStrength(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = percent
            entry.state = abs(model.auroraStrength - Double(percent) / 100) < 0.001 ? .on : .off
            auroraMenu.addItem(entry)
        }
        auroraParent.submenu = auroraMenu
        add("远处山脊", #selector(toggleAuroraLandscape)).state = model.auroraLandscape ? .on : .off
        add("任务结束提示音", #selector(toggleSound)).state = model.soundEnabled ? .on : .off
        add("试听提示音", #selector(testSound))
        add("任务结束烟花", #selector(toggleFireworks)).state = model.fireworksEnabled ? .on : .off
        add("预览结束烟花", #selector(previewFireworks))
        menu.addItem(.separator())
        let parent = add("文案轮播间隔", nil)
        let submenu = NSMenu()
        for seconds in [15, 20, 30, 60] {
            let entry = NSMenuItem(title: "\(seconds) 秒", action: #selector(changeInterval(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = seconds
            entry.state = Int(model.quoteInterval) == seconds ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        add("编辑轮播文案…", #selector(editQuotes))
        add("使用说明…", #selector(openHelp))
        menu.addItem(.separator())
        add("退出小灯", #selector(quit), key: "q")
    }
    @discardableResult func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(inPanel: false) }
        else if driftEnabled && detailOpen { resumeDrift() }
        else { showPanel() }
    }
    func showMenu(inPanel: Bool = true) {
        menuTracking = true
        driftMotion?.pause()
        defer { menuTracking = false; driftMotion?.pause() }
        rebuildMenu()
        if inPanel {
            menu.popUp(positioning: nil, at: NSPoint(x: hosting.bounds.maxX - 28, y: hosting.bounds.maxY - 52), in: hosting)
        } else if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
        }
    }
    @objc func showPanel() {
        if !model.preview { fullScreenSuppressed = frontmostIsFullScreen() }
        explicitFullScreenDetails = fullScreenSuppressed
        if driftEnabled && !detailOpen, let frame = driftMotion?.frame {
            changingFrame = true
            let width = model.expanded ? LanternView.detailWidth : LanternView.compactWidth
            panel.setFrameOrigin(NSPoint(x: frame.maxX - width, y: frame.maxY - panel.frame.height))
            changingFrame = false
        }
        detailOpen = true
        model.manualVisible = true
        model.paused = false
        refresh()
    }
    @objc func resumeDrift() {
        detailOpen = false
        explicitFullScreenDetails = false
        // A manual detail inspection must not keep an idle light permanently visible.
        model.manualVisible = false
        driftMotion?.pause()
        refresh()
    }
    @objc func toggleDrift() {
        driftEnabled.toggle()
        if !model.preview { UserDefaults.standard.set(driftEnabled, forKey: "driftEnabled") }
        detailOpen = !driftEnabled
        hosting.rootView = makeDetailView()
        driftMotion?.pause()
        refresh()
    }
    @objc func changeDriftArea(_ entry: NSMenuItem) {
        guard DriftArea.allCases.indices.contains(entry.tag) else { return }
        driftArea = DriftArea.allCases[entry.tag]
        if !model.preview { UserDefaults.standard.set(driftArea.rawValue, forKey: "driftArea") }
        if let screen = currentDriftScreen {
            driftMotion?.setArea(driftArea, screen: screen.visibleFrame)
        }
        refresh()
    }
    @objc func movePanelToPrimaryScreen() {
        guard panel != nil, let screen = NSScreen.screens.first?.visibleFrame else { return }
        model.manualVisible = true
        model.paused = false
        if let screen = NSScreen.screens.first {
            driftScreenID = screenID(screen)
            driftMotion?.setScreen(screen.visibleFrame)
            driftMotion?.park(near: CGPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.maxY))
        }
        let frame = NSRect(x: screen.maxX - panel.frame.width - 20, y: screen.maxY - panel.frame.height - 20,
                           width: panel.frame.width, height: panel.frame.height)
        changingFrame = true
        panel.setFrame(visiblePanelFrame(frame), display: true)
        changingFrame = false
        UserDefaults.standard.set(panel.frame.minX, forKey: "panelX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "panelTop")
        refresh()
    }
    @objc func toggleIdle() {
        model.showIdle.toggle()
        model.manualVisible = false
        UserDefaults.standard.set(model.showIdle, forKey: "showIdle")
        refresh()
    }
    @objc func togglePaused() { model.paused.toggle(); refresh() }
    @objc func togglePreview() { model.toggleDemo() }
    @objc func changeTheme(_ entry: NSMenuItem) {
        guard ThemeChoice.allCases.indices.contains(entry.tag) else { return }
        model.theme = ThemeChoice.allCases[entry.tag]
        UserDefaults.standard.set(model.theme.rawValue, forKey: "theme")
        refresh()
    }
    @objc func toggleSound() {
        model.soundEnabled.toggle()
        UserDefaults.standard.set(model.soundEnabled, forKey: "soundEnabled")
    }
    @objc func toggleAnimations() {
        model.animationsEnabled.toggle()
        UserDefaults.standard.set(model.animationsEnabled, forKey: "animationsEnabled")
    }
    @objc func toggleMeteors() {
        model.meteorEnabled.toggle()
        UserDefaults.standard.set(model.meteorEnabled, forKey: "meteorEnabled")
    }
    @objc func toggleAdaptiveAnimations() {
        model.adaptiveAnimations.toggle()
        UserDefaults.standard.set(model.adaptiveAnimations, forKey: "adaptiveAnimations")
    }
    @objc func changeMeteorStrength(_ entry: NSMenuItem) {
        guard [15, 25, 40, 60].contains(entry.tag) else { return }
        model.meteorStrength = Double(entry.tag) / 100
        UserDefaults.standard.set(model.meteorStrength, forKey: "meteorStrength")
    }
    @objc func toggleAurora() {
        model.auroraEnabled.toggle()
        UserDefaults.standard.set(model.auroraEnabled, forKey: "auroraEnabled")
    }
    @objc func changeAuroraStrength(_ entry: NSMenuItem) {
        guard [15, 18, 30, 45, 70].contains(entry.tag) else { return }
        model.auroraStrength = Double(entry.tag) / 100
        UserDefaults.standard.set(model.auroraStrength, forKey: "auroraStrength")
    }
    @objc func toggleAuroraLandscape() {
        model.auroraLandscape.toggle()
        UserDefaults.standard.set(model.auroraLandscape, forKey: "auroraLandscape")
    }
    @objc func testSound() { model.playCompletionSound(force: true) }
    @objc func toggleFireworks() {
        model.fireworksEnabled.toggle()
        if !model.preview { UserDefaults.standard.set(model.fireworksEnabled, forKey: "fireworksEnabled") }
        updateCelebration()
    }
    @objc func previewFireworks() {
        let event = TaskCompletion(id: UUID().uuidString, agent: "Codex", label: "烟花效果预览", at: Date().timeIntervalSince1970)
        showCelebration(events: [event], demo: true, allEnded: !args.contains("--preview-fireworks-single"))
    }
    @objc func systemAppearanceChanged() {
        model?.systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if panel != nil { refresh() }
    }
    @objc func changeInterval(_ entry: NSMenuItem) { model.quoteInterval = Double(entry.tag); model.startQuoteTimer(); refresh() }
    @objc func editQuotes() { NSWorkspace.shared.open(supportURL.appendingPathComponent("quotes.json")) }
    @objc func openHelp() {
        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    private func verifyFireworks(path: String) {
        guard model.preview else { return }
        var checks: [String: Bool] = [:]
        var liveRender: [String: Any] = [:]
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.demo = false
        model.soundEnabled = false
        model.fireworksEnabled = true
        model.completionGate = CompletionGate()
        let tasks = Array(model.tasks.prefix(2))
        let base = Date().timeIntervalSince1970
        let history = TaskCompletion(id: "history", agent: "Codex", label: "历史任务", at: base - 1)
        let first = TaskCompletion(id: "first", agent: "Codex", label: "示例任务一", at: base + 1)
        let last = TaskCompletion(id: "last", agent: "Pi", label: "示例任务二", at: base + 7)
        func receive(_ events: [TaskCompletion], at time: Double, remaining: [AgentTask], codexStatus: String = "ready") {
            let snapshot = Snapshot(schema: 1, updated: time, tasks: remaining,
                adapters: [Adapter(agent: "Codex", status: codexStatus, detail: "验收示例"),
                           Adapter(agent: "Pi", status: "ready", detail: "验收示例")], completions: events)
            if var data = try? JSONEncoder().encode(snapshot) { data.append(10); model.receive(data) }
        }
        receive([history], at: base, remaining: tasks)
        checks["startup_history_silent"] = celebrationDisplay.show == nil
        receive([history], at: base + 2, remaining: tasks)
        receive([history, first], at: base + 4, remaining: Array(tasks.suffix(1)), codexStatus: "degraded")
        checks["individual_completion_with_sound_muted"] = celebrationDisplay.show?.bursts.count == 2 && celebrationPanel.isVisible
        checks["delayed_completion_not_lost"] = celebrationDisplay.show?.completedCount == 1
        checks["other_uncertain_task_does_not_block_verified_completion"] = model.degraded && celebrationPanel.isVisible
        checks["remaining_tasks_are_real"] = celebrationDisplay.show?.remaining == 1 && !model.tasks.isEmpty
        if model.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No snapshots, pinned ages or state writes: only the live timeline can advance the renderer.
            RunLoop.main.run(until: Date().addingTimeInterval(1.8))
            let render = celebrationDisplay.renderProbe.snapshot
            liveRender = render
            checks["live_canvas_advances"] = (render["frames"] as? Int ?? 0) >= 12 && (render["lastAge"] as? Double ?? 0) > 1
            checks["live_canvas_draws_particles"] = (render["particleFrames"] as? Int ?? 0) >= 6
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            let lateRender = celebrationDisplay.renderProbe.snapshot
            liveRender["extendedTail"] = lateRender
            checks["extended_single_still_draws_embers"] = celebrationPanel.isVisible &&
                (lateRender["lastAge"] as? Double ?? 0) > 4.5 && (lateRender["lastParticles"] as? Int ?? 0) > 0
        }
        let began = celebrationDisplay.show?.began
        receive([history, first], at: base + 6, remaining: Array(tasks.suffix(1)))
        checks["duplicate_does_not_restart"] = celebrationDisplay.show?.completedCount == 1 && celebrationDisplay.show?.began == began
        receive([first, last], at: base + 8, remaining: [])
        checks["last_completion_upgrades_in_place"] = celebrationDisplay.show?.bursts.count == 6 &&
            celebrationDisplay.show?.allEnded == true && celebrationDisplay.show?.began == began
        checks["single_completion_surface"] = !completionPanel.isVisible
        checks["click_through"] = celebrationPanel.ignoresMouseEvents
        checks["cannot_take_focus"] = !celebrationPanel.canBecomeKey && !celebrationPanel.canBecomeMain
        checks["transparent_overlay"] = !celebrationPanel.isOpaque && celebrationPanel.backgroundColor == .clear
        checks["confined_to_one_visible_screen"] = NSScreen.screens.contains { $0.visibleFrame == celebrationPanel.frame }
        celebrationDisplay.show = CompletionCelebration(events: [last], remaining: 0, waiting: 0, allEnded: true,
                                                        at: ProcessInfo.processInfo.systemUptime, demo: true)
        celebrationDisplay.previewAge = 1.95
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let view = celebrationPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: folder.appendingPathComponent("fireworks.png")) }
        }
        celebrationDisplay.previewAge = nil
        model.animationsEnabled = false; updateCelebration()
        checks["animations_off_is_static_toast"] = celebrationPanel.isVisible && !celebrationDisplay.moving
        model.animationsEnabled = true; updateCelebration()
        checks["system_reduce_motion_respected"] = celebrationDisplay.moving == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.paused = true; refresh()
        checks["pause_cancels_and_stops_timer"] = !celebrationPanel.isVisible && celebrationTimer == nil
        model.paused = false; refresh()
        checks["resume_does_not_replay"] = celebrationDisplay.show == nil
        showCelebration(events: [last])
        model.monitorHealthy = false; refresh()
        checks["collector_disconnect_cancels"] = celebrationDisplay.show == nil && celebrationTimer == nil
        model.monitorHealthy = true; refresh()
        showCelebration(events: [last], demo: true, allEnded: true)
        screenDidLock()
        checks["lock_cancels"] = !celebrationPanel.isVisible && celebrationTimer == nil
        screenDidUnlock()
        showCelebration(events: [last], demo: true, allEnded: true)
        fullScreenSuppressed = true; refresh()
        checks["fullscreen_cancels"] = !celebrationPanel.isVisible && celebrationTimer == nil
        fullScreenSuppressed = false; refresh()
        showCelebration(events: [last], demo: true, allEnded: true)
        model.fireworksEnabled = false; updateCelebration()
        checks["disabled_cancels"] = !celebrationPanel.isVisible && celebrationTimer == nil
        showCelebration(events: [last], demo: true, allEnded: true)
        checks["disabled_cannot_start"] = celebrationDisplay.show == nil
        model.fireworksEnabled = true
        celebrationDisplay.show = CompletionCelebration(events: [last], remaining: 0, waiting: 0, allEnded: true,
                                                        at: ProcessInfo.processInfo.systemUptime - 10)
        updateCelebration()
        checks["expiry_clears_show_and_timer"] = celebrationDisplay.show == nil && celebrationTimer == nil
        // A disconnected collector must seed completion history without any new celebration.
        receive([TaskCompletion(id: "reconnect", agent: "Codex", label: "重连历史", at: base + 29)], at: base + 30, remaining: [])
        checks["reconnect_history_silent"] = celebrationDisplay.show == nil
        checks["foreground_unchanged"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "liveRender": liveRender]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    private func verifyDrift(path: String) {
        // Native presentation checks run only with isolated, explicitly labeled demo tasks.
        guard model.preview else { return }
        var checks: [String: Bool] = [:]
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        checks["requested_drift_area"] = driftMotion?.route.area == driftArea
        if driftArea == .top, let motion = driftMotion {
            checks["top_route_position"] = motion.center.y == motion.route.bounds.maxY
        }
        checks["drift_size_52"] = driftPanel.frame.size == CGSize(width: 52, height: 52)
        checks["click_through"] = driftPanel.ignoresMouseEvents && completionPanel.ignoresMouseEvents
        checks["cannot_take_focus"] = !driftPanel.canBecomeKey && !panel.canBecomeKey
        checks["single_visible_surface"] = driftPanel.isVisible && !panel.isVisible
        if model.running > 0 && model.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            checks["native_timer_moves_light"] = (driftMotion?.distance ?? 0) > 1
        }
        saveSnapshot(path: folder.appendingPathComponent("drift.png").path)
        showPanel()
        checks["details_stop_drift"] = panel.isVisible && !driftPanel.isVisible && driftTimer == nil
        checks["details_accept_clicks"] = !panel.ignoresMouseEvents
        checks["compact_detail_width"] = panel.frame.width == LanternView.compactWidth
        saveSnapshot(path: folder.appendingPathComponent("details.png").path)
        model.expanded = true; refresh()
        checks["expanded_detail_width"] = panel.frame.width == LanternView.detailWidth
        saveSnapshot(path: folder.appendingPathComponent("expanded.png").path)
        resumeDrift()
        checks["resume_drift"] = driftPanel.isVisible && !panel.isVisible && driftTimer != nil
        model.sessionActive = false; refresh()
        checks["session_pause_hides_and_stops"] = !driftPanel.isVisible && !panel.isVisible && driftTimer == nil
        model.sessionActive = true; refresh()
        checks["session_resume"] = driftPanel.isVisible && driftTimer != nil
        screenDidLock()
        checks["lock_hides_and_stops"] = !driftPanel.isVisible && driftTimer == nil
        displayAwake = true; updateSessionVisibility()
        checks["wake_does_not_override_lock"] = !driftPanel.isVisible && !model.sessionActive
        screenDidUnlock()
        checks["unlock_resumes"] = driftPanel.isVisible && driftTimer != nil
        displayAwake = false; updateSessionVisibility(); screenDidUnlock()
        checks["unlock_does_not_override_sleep"] = !driftPanel.isVisible && !model.sessionActive
        displayAwake = true; updateSessionVisibility()
        fullScreenSuppressed = true; refresh()
        checks["full_screen_hides_and_stops"] = !driftPanel.isVisible && !panel.isVisible && driftTimer == nil
        showPanel()
        checks["full_screen_explicit_details_available"] = panel.isVisible && !driftPanel.isVisible
        resumeDrift()
        checks["full_screen_return_hides_ambient"] = !driftPanel.isVisible && !panel.isVisible
        fullScreenSuppressed = false; refresh()
        model.paused = true; refresh()
        checks["pause_hides"] = !driftPanel.isVisible && driftTimer == nil
        model.paused = false; refresh()
        toggleDrift()
        checks["fixed_mode_available"] = panel.isVisible && !driftPanel.isVisible && driftTimer == nil
        toggleDrift()
        checks["drift_mode_restored"] = driftPanel.isVisible && !panel.isVisible
        let originalArea = driftArea
        for (index, area) in DriftArea.allCases.enumerated() {
            let entry = NSMenuItem()
            entry.tag = index
            changeDriftArea(entry)
            rebuildMenu()
            let areaMenu = menu.items.first(where: { $0.title == "漂浮范围" })?.submenu
            checks["area_menu_\(area.rawValue)"] = areaMenu?.items[index].state == .on &&
                areaMenu?.items.filter({ $0.state == .on }).count == 1
            checks["area_switch_\(area.rawValue)"] = driftMotion?.route.area == area &&
                currentDriftScreen?.visibleFrame.contains(driftPanel.frame) == true
        }
        let restoreArea = NSMenuItem()
        restoreArea.tag = DriftArea.allCases.firstIndex(of: originalArea) ?? 0
        changeDriftArea(restoreArea)
        checks["foreground_unchanged"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
        model.tasks = []; model.finished = true; refresh()
        checks["completion_bubble"] = completionPanel.isVisible && completionPanel.ignoresMouseEvents
        if let bubbleView = completionPanel.contentView,
           let image = bubbleView.bitmapImageRepForCachingDisplay(in: bubbleView.bounds) {
            bubbleView.cacheDisplay(in: bubbleView.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: folder.appendingPathComponent("completion.png"))
            }
        }
        completionDeadline = 0; updateCompletionBubble()
        checks["completion_bubble_expires"] = !completionPanel.isVisible
        model.finished = false; model.demo = false; model.manualVisible = false
        model.showIdle = false; model.monitorHealthy = true; model.adapters = []; refresh()
        checks["idle_hides"] = !driftPanel.isVisible && !panel.isVisible && driftTimer == nil
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    func saveSnapshot(path: String) {
        let target: NSView = (model.preview && args.contains("--preview-fireworks") ? celebrationPanel.contentView : nil) ??
            (model.driftPresented ? driftHosting : hosting)
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        frameTimer?.invalidate()
        driftTimer?.invalidate()
        environmentTimer?.invalidate()
        celebrationTimer?.invalidate()
        model?.stop()
    }
}

// Command clients must not register a GUI instance: that can race the resident's single-instance guard.
let commandArgs = CommandLine.arguments
if commandArgs.contains("--diagnose-running") || commandArgs.contains("--preview-running-fireworks") || commandArgs.contains("--move-running-to-primary") {
    let diagnose = commandArgs.contains("--diagnose-running")
    let name = diagnose ? "local.agentlantern.diagnose" :
        commandArgs.contains("--move-running-to-primary") ? "local.agentlantern.move-primary" : "local.agentlantern.preview-fireworks"
    let began = Date()
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(name), object: nil,
        userInfo: ["single": commandArgs.contains("--single")], deliverImmediately: true)
    if diagnose {
        let file = supportURL.appendingPathComponent("completion-diagnostics.json")
        let deadline = began.addingTimeInterval(3)
        var received = false
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date >= began, let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                print(text); received = true; break
            }
        }
        if !received { fputs("Resident lantern did not respond\n", stderr); exit(1) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
