import SwiftUI

struct MessageFlowView: View {
    var task: AgentTask
    var palette: Palette
    var animationsEnabled: Bool
    var demo = false
    var detailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var created = Date()

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
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text(detailed ? "工作闭环示意" : task.agent).font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(phase.title).font(.system(size: 9))
                        .foregroundStyle(phase == .waiting ? palette.warning : palette.text(0.55))
                    Spacer(minLength: 2)
                    Text(detailed ? "模型内部示意" : "大模型").font(.system(size: 10, weight: .medium))
                }.foregroundStyle(palette.text(0.75))
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { frame in
                    Canvas { context, size in
                        let wall = moving ? frame.date.timeIntervalSince1970 : now
                        let elapsed = moving ? frame.date.timeIntervalSince(created) : 0.9
                        let transfer = activePulse(now: wall, phase: phase)
                        MechanismScene(palette: palette, phase: phase, detailed: detailed,
                                       elapsed: max(0, elapsed), eventAge: eventAge(now: wall, phase: phase),
                                       moving: moving, transfer: transfer,
                                       transferAge: transfer.map { moving ? max(0, wall - $0.began) : $0.duration * 0.57 })
                            .draw(context, size: size)
                    }
                }.frame(height: detailed ? 150 : 74)
                Text(pulse?.title ?? (phase == .waiting ? "等待确认 · 通信暂停" : "收发由事件驱动"))
                    .font(.system(size: 9)).foregroundStyle(pulse?.kind == "response" ? palette.accent : palette.text(0.5))
                    .frame(height: 11).lineLimit(1)
                Text(detailed ? "模型内部为原理示意 · 非实时内部遥测" : "模型内部示意")
                    .font(.system(size: 9)).foregroundStyle(palette.text(0.43))
                if !detailed {
                    HStack(spacing: 4) {
                        Circle().fill(palette.accent.opacity(0.6)).frame(width: 3, height: 3)
                        Text(demo ? "演示 · 非真实请求" : sourceLabel)
                            .font(.system(size: 9)).foregroundStyle(palette.text(0.4))
                        Spacer(minLength: 4)
                        Text(task.label).font(.system(size: 9)).foregroundStyle(palette.text(0.4))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .help((demo ? "预览示例；" : observation.detail + "；") +
                  "模型内部的注意力与分层计算、智能体的闭环图均为原理示意；节点、层数、token 方块与光点不代表内部遥测或 TPS")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(task.agent)，\(phase.title)，\(demo ? "演示" : sourceLabel)，模型内部为原理示意")
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func displayPhase(now: Double) -> FlowPhase {
        guard demo, task.state != "waiting" else { return observation.display(at: now, waiting: task.state == "waiting") }
        if let flow = task.flow { return flow.display(at: flow.at, waiting: false) }
        let offset = ["Codex": 0.0, "Pi": 4.0, "Hermes": 8.0, "DeepSeek": 12.0][task.agent] ?? 0.0
        return [.sending, .awaiting, .receiving, .tools][Int((now + offset).truncatingRemainder(dividingBy: 16)) / 4]
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
                MessageFlowView(task: selected, palette: palette, animationsEnabled: animationsEnabled, demo: demo)
                    .id(selected.id)
            }
        }
    }
}
