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
struct Palette {
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
    @Published var animationsEnabled = UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true
    @Published var sessionActive = true
    @Published var showIdle = UserDefaults.standard.bool(forKey: "showIdle")
    @Published var quoteInterval = UserDefaults.standard.double(forKey: "quoteInterval") == 0
        ? 20.0 : UserDefaults.standard.double(forKey: "quoteInterval")
    var onChange: (() -> Void)?
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
    var animateWork: Bool { animationsEnabled && shouldShow && sessionActive }
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
        let names = ["Codex", "Pi", "Hermes"].compactMap { name -> String? in
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
                let healthyAgents = Set(snap.adapters.filter { $0.status == "ready" }.map { $0.agent })
                let completed = (snap.completions ?? []).filter { healthyAgents.contains($0.agent) }
                if completionGate.consume(completed, at: snap.updated, allowSound: !demo && soundEnabled) {
                    playCompletionSound()
                }
                lastSnapshot = snap
                lastUpdate = Date()
                if !demo { apply(snap) }
            }
        }
        if buffer.count > 2_000_000 { buffer.removeAll() }
    }
    func apply(_ snapshot: Snapshot) {
        let hadTasks = !tasks.isEmpty
        monitorHealthy = true
        tasks = snapshot.tasks
        adapters = snapshot.adapters
        if !tasks.isEmpty {
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
        demo.toggle()
        if demo {
            monitorHealthy = true
            let now = Date().timeIntervalSince1970
            tasks = [AgentTask(id: "demo:1", agent: "Codex", label: "整理项目里的新想法", state: "running", started: now - 83, evidence: "示例"),
                     AgentTask(id: "demo:2", agent: "Pi", label: "把灵感变成作品", state: "running", started: now - 36, evidence: "示例"),
                     AgentTask(id: "demo:3", agent: "Hermes", label: "等待你的一个决定", state: "waiting", started: now - 112, evidence: "示例")]
            adapters = ["Codex", "Pi", "Hermes"].map { Adapter(agent: $0, status: "ready", detail: "预览示例") }
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
    @ObservedObject var model: Model
    var openMenu: () -> Void
    var palette: Palette { model.palette }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WorkingLight(color: model.activityColor, warning: palette.warning, phase: model.activityPhase,
                             hasWaiting: model.waiting > 0, animationsEnabled: model.animateWork)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("小灯").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                            .foregroundStyle(palette.text(0.44))
                        if model.demo { Text("预览").font(.system(size: 9)).foregroundStyle(palette.warning) }
                    }
                    HStack(spacing: 7) {
                        Text(model.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.text(0.94))
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
            .padding(.top, 18).padding(.horizontal, 18)

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
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 10.5)).foregroundStyle(palette.text(0.48))
                .contentShape(Rectangle()).padding(.vertical, 10)
            }.buttonStyle(.plain).padding(.horizontal, 21)
                .accessibilityLabel(model.expanded ? "收起任务详情" : "展开任务详情")

            Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1).padding(.horizontal, 20)

            HStack(alignment: .center, spacing: 8) {
                Text("“").font(.system(size: 25, weight: .light, design: .serif)).foregroundStyle(palette.accent.opacity(0.5))
                Text(model.quote).id(model.quote)
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(palette.text(0.77))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                Spacer(minLength: 0)
            }.frame(height: 46).padding(.horizontal, 21)

            if model.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 13) {
                            if model.tasks.isEmpty {
                                Text("新任务开始时，小灯会自动亮起。")
                                    .font(.system(size: 11)).foregroundStyle(palette.text(0.5))
                            }
                            ForEach(model.tasks) { task in
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(task.state == "waiting" ? palette.warning : palette.accent)
                                        .frame(width: 5, height: 5).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(task.agent).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.text(0.85))
                                            Spacer()
                                            Text(task.state == "waiting" ? "等你确认" : "进行中")
                                                .font(.system(size: 10)).foregroundStyle(task.state == "waiting" ? palette.warning : palette.accent)
                                            if task.started > 0 {
                                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                                    Text(elapsed(context.date.timeIntervalSince1970 - task.started))
                                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.text(0.35))
                                                }
                                            }
                                        }
                                        Text(task.label).font(.system(size: 11)).foregroundStyle(palette.text(0.48)).lineLimit(1)
                                    }
                                }.help(task.evidence)
                            }
                        }.padding(.vertical, 15)
                    }.frame(height: min(CGFloat(max(model.tasks.count, 1)) * 45 + 26, 170))
                    Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.adapters) { adapter in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(adapter.status == "ready" ? palette.accent.opacity(0.7) : palette.warning.opacity(0.8))
                                    .frame(width: 4, height: 4).padding(.top, 4)
                                Text(adapter.agent).font(.system(size: 10, weight: .medium)).frame(width: 44, alignment: .leading)
                                Text(adapter.detail).font(.system(size: 10)).foregroundStyle(palette.text(0.42))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.foregroundStyle(palette.text(0.6))
                        }
                    }.padding(.vertical, 13)
                }.padding(.horizontal, 21)
            }
        }
        .padding(.bottom, 5)
        .frame(width: 334)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(palette.background.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(palette.border, lineWidth: 0.7))
        .environment(\.colorScheme, model.effectiveDark ? .dark : .light)
    }
    func elapsed(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(value % 60)s" }
        return "\(value / 3600)h \((value % 3600) / 60)m"
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
        systemAppearanceChanged()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        // Command-line theme overrides are only for artifact rendering; they do not change saved preferences.
        if let index = args.firstIndex(of: "--theme"), args.indices.contains(index + 1),
           let theme = ThemeChoice(rawValue: args[index + 1]) { model.theme = theme }
        if model.preview, let index = args.firstIndex(of: "--preview-state"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "waiting": model.tasks = model.tasks.map { var task = $0; task.state = "waiting"; return task }
            case "idle": model.tasks = []
            case "completed": model.tasks = []; model.finished = true
            default: break
            }
        }
        if args.contains("--no-animation") { model.animationsEnabled = false }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.model.sessionActive = false
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.model.sessionActive = true
            })
        }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 334, height: 149),
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
        hosting = NSHostingView(rootView: LanternView(model: model, openMenu: { [weak self] in self?.showMenu() }))
        panel.contentView = hosting
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = UserDefaults.standard.object(forKey: "panelX") as? Double ?? screen.maxX - 360
        let y = UserDefaults.standard.object(forKey: "panelTop") as? Double ?? screen.maxY - 65
        panel.setFrameTopLeftPoint(NSPoint(x: min(max(x, screen.minX + 10), screen.maxX - 344),
                                           y: min(max(y, screen.minY + 160), screen.maxY - 10)))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "智能体工作灯")
        item.button?.target = self
        item.button?.action = #selector(statusClick)
        model.onChange = { [weak self] in self?.refresh() }
        model.manualVisible = true
        refresh()
        if !model.preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.model.manualVisible = false
                self?.refresh()
            }
        }
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            if args.contains("--expanded") { model.expanded = true; refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveSnapshot(path: self?.args[index + 1] ?? "")
                NSApp.terminate(nil)
            }
        }
        if let index = args.firstIndex(of: "--record-frames"), args.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var frame = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
                    self?.saveSnapshot(path: directory.appendingPathComponent(String(format: "frame-%03d.png", frame)).path)
                    frame += 1
                    if frame >= 36 { timer.invalidate(); NSApp.terminate(nil) }
                }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.manualVisible = true
        model?.paused = false
        refresh()
        return true
    }
    func refresh() {
        guard panel != nil else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        let current = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var rect = NSRect(x: current.minX, y: current.maxY - height, width: 334, height: height)
        rect.origin.x = min(max(rect.origin.x, screen.minX + 8), screen.maxX - rect.width - 8)
        rect.origin.y = max(rect.origin.y, screen.minY + 8)
        changingFrame = true
        panel.setFrame(rect, display: true, animate: false)
        changingFrame = false
        if model.shouldShow { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        let count = model.tasks.count
        item.button?.title = model.demo ? " 示例" : (count > 0 ? " \(count)" : "")
        item.button?.toolTip = "小灯 · " + model.title
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
        add("显示浮窗", #selector(showPanel))
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
        add("任务结束提示音", #selector(toggleSound)).state = model.soundEnabled ? .on : .off
        add("试听提示音", #selector(testSound))
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
    @objc func statusClick() { showMenu(inPanel: false) }
    func showMenu(inPanel: Bool = true) {
        rebuildMenu()
        if inPanel {
            menu.popUp(positioning: nil, at: NSPoint(x: hosting.bounds.maxX - 28, y: hosting.bounds.maxY - 52), in: hosting)
        } else if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
        }
    }
    @objc func showPanel() { model.manualVisible = true; model.paused = false; refresh() }
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
    @objc func testSound() { model.playCompletionSound(force: true) }
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
    func saveSnapshot(path: String) {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        frameTimer?.invalidate()
        model?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
