import SwiftUI

struct MessageFlowView: View {
    var task: AgentTask
    var palette: Palette
    var animationsEnabled: Bool
    var windClock: WindClock
    var demo = false
    var detailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var created = Date()
    @State private var mechanismMotion = MechanismMotion()

    private var observation: MessageFlow {
        if let flow = task.flow { return flow }
        if let speed = task.speed, speed.status == "recent", let at = speed.measuredAt {
            return MessageFlow(phase: "response", at: at, detail: "响应结束统计；不代表当前模型正在生成")
        }
        return MessageFlow(phase: "unknown", at: 0, detail: "当前数据仅能确认任务运行，未确认模型收发阶段")
    }

    private var canAnimate: Bool { animationsEnabled && !reduceMotion && visible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !canAnimate)) { _ in
            let now = Date().timeIntervalSince1970
            let phase = displayPhase(now: now)
            let pulse = activePulse(now: now, phase: phase)
            let moving = canAnimate && (phase.moving || pulse != nil)
            let sideMoving = canAnimate && phase.allowsMechanismMotion
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    Text(detailed ? "工作闭环示意" : task.agent).font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    Text(phase.title).font(.system(size: 12))
                        .foregroundStyle(phase == .waiting ? palette.warning : palette.text(0.55))
                        .frame(maxWidth: .infinity)
                    Text(detailed ? "模型内部示意" : "大模型").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                }.foregroundStyle(palette.text(0.85)).lineLimit(1).minimumScaleFactor(0.9)
                    .shadow(color: palette.background, radius: 3)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving && !sideMoving)) { frame in
                    let wall = moving ? frame.date.timeIntervalSince1970 : now
                    let elapsed = moving ? frame.date.timeIntervalSince(created) : 0.9
                    let transfer = activePulse(now: wall, phase: phase)
                    let scene = MechanismScene(palette: palette, phase: phase, detailed: detailed,
                                       elapsed: max(0, elapsed), eventAge: eventAge(now: wall, phase: phase),
                                       moving: moving, transfer: transfer,
                                       transferAge: transfer.map { moving ? max(0, wall - $0.began) : $0.duration * 0.57 },
                                       sideElapsed: mechanismMotion.time(at: windClock.motion.mechanismTime))
                    ZStack {
                        Canvas { context, size in scene.draw(context, size: size) }
                        GeometryReader { geometry in
                            WindGustButton(clock: windClock, side: min(96, geometry.size.width / 3 - 1))
                                .position(x: geometry.size.width / 2, y: 56)
                        }
                        // Traffic stays above the window's background rotor and
                        // never intercepts the center's breeze interaction.
                        Canvas { context, size in scene.draw(context, size: size, layer: .transfers) }
                            .allowsHitTesting(false)
                    }
                }
                .onAppear { mechanismMotion.configure(source: windClock.motion.mechanismTime, enabled: sideMoving) }
                .onChange(of: sideMoving) { _, enabled in
                    mechanismMotion.configure(source: windClock.motion.mechanismTime, enabled: enabled)
                }
                .onDisappear { mechanismMotion.configure(source: windClock.motion.mechanismTime, enabled: false) }
                .frame(height: detailed ? 144 : 112)
                Text(pulse?.title ?? mechanismLabel(phase))
                    .font(.system(size: 12)).foregroundStyle(pulse?.kind == "response" ? palette.accent : palette.text(0.65))
                    .shadow(color: palette.background, radius: 3)
                    .frame(height: 18).lineLimit(1).minimumScaleFactor(0.9)
                Text("两侧为原理示意 · 非模型内部遥测")
                    .font(.system(size: 12)).foregroundStyle(palette.text(0.60))
                    .shadow(color: palette.background, radius: 3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if !detailed {
                    HStack(spacing: 4) {
                        Circle().fill(palette.accent.opacity(0.6)).frame(width: 3, height: 3)
                        Text(demo ? "演示 · 非真实请求" : sourceLabel)
                            .font(.system(size: 12)).foregroundStyle(palette.text(0.55))
                        Spacer(minLength: 4)
                        Text(task.label).font(.system(size: 12)).foregroundStyle(palette.text(0.55))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .help((demo ? "预览示例；" : observation.detail + "；") +
                  "两侧均为原理示意；待命呼吸和浮动不表示模型正在计算。节点、层数、生成符号和光点不代表内部遥测、token 数或 TPS")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(task.agent)，\(phase.title)，\(demo ? "演示" : sourceLabel)，模型内部为原理示意")
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func displayPhase(now: Double) -> FlowPhase {
        if task.state == "ended" { return .ended }
        guard demo, task.state != "waiting" else { return observation.display(at: now, waiting: task.state == "waiting") }
        if let flow = task.flow { return flow.display(at: flow.at, waiting: false) }
        let offset = ["Codex": 0.0, "Pi": 4.0, "Hermes": 8.0, "DeepSeek": 12.0][task.agent] ?? 0.0
        return [.sending, .awaiting, .receiving, .tools][Int((now + offset).truncatingRemainder(dividingBy: 16)) / 4]
    }

    private func mechanismLabel(_ phase: FlowPhase) -> String {
        switch phase {
        case .sending: return "上下文归拢 · 请求已观察"
        case .awaiting: return "模型原理示意 · 等待新响应"
        case .receiving: return "响应整理 · 生成符号示意"
        case .tools: return "工具调度示意 · 模型待命"
        case .response: return "已观察响应 · 模型待命"
        case .recorded: return "待命微动 · 响应已记录"
        case .processing: return "待命微动 · 等待后续事件"
        case .unknown: return "待命微动 · 收发阶段未确认"
        case .waiting: return "等待确认 · 两侧工作动效暂停"
        case .ended: return "本次运行已结束 · 微风相伴"
        }
    }

    private func eventAge(now: Double, phase: FlowPhase) -> Double {
        guard canAnimate else { return phase == .sending ? FlowPhase.sendingDuration * 0.57 : 1.7 }
        if demo {
            let age = max(0, now - (task.flow?.at ?? created.timeIntervalSince1970))
            return phase == .sending ? age.truncatingRemainder(dividingBy: FlowPhase.sendingDuration) : age
        }
        return max(0, now - observation.at)
    }

    private func activePulse(now: Double, phase: FlowPhase) -> TransferPulse? {
        guard phase != .waiting else { return nil }
        return observation.playback?.first { $0.active(at: now) }
    }

    private var sourceLabel: String {
        if task.agent == "Hermes", task.speed?.status == "recent" { return "响应统计" }
        if task.flow != nil { return task.agent == "Pi" ? "扩展事件" : "日志事件" }
        return task.speed?.status == "recent" ? "响应统计" : "任务状态"
    }
}

struct MessageFlowCarousel: View {
    var tasks: [AgentTask]
    var palette: Palette
    var animationsEnabled: Bool
    var windClock: WindClock
    var demo: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchor = Date()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !animationsEnabled || reduceMotion)) { timeline in
            if !tasks.isEmpty {
                let index = Int(max(0, timeline.date.timeIntervalSince(anchor)) / 6) % tasks.count
                let now = Date().timeIntervalSince1970
                let active = tasks.filter { $0.state != "waiting" && $0.flow?.playback?.contains(where: { $0.active(at: now) }) == true }
                let selected = active.contains(where: { $0.id == tasks[index].id }) ? tasks[index] : (active.first ?? tasks[index])
                MessageFlowView(task: selected, palette: palette, animationsEnabled: animationsEnabled, windClock: windClock, demo: demo)
                    .id(selected.id)
            }
        }
    }
}
