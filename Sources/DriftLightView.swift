import SwiftUI

struct DriftLightView: View {
    @ObservedObject var model: Model

    private var badge: String {
        if model.demo { return "示" }
        if model.finished && model.tasks.isEmpty { return "✓" }
        if model.degraded { return "!" }
        return model.tasks.count > 99 ? "99+" : String(model.tasks.count)
    }

    var body: some View {
        WorkingLight(color: model.activityColor, warning: model.palette.warning, phase: model.activityPhase,
                     hasWaiting: model.waiting > 0, animationsEnabled: model.animateDrift)
            .background(Circle().fill(model.palette.background.opacity(0.7)).padding(5))
            .frame(width: DriftRoute.lightSize, height: DriftRoute.lightSize)
            .overlay(alignment: .bottomTrailing) {
                Text(badge).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.color)
                    .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
                    .background(model.palette.background, in: Capsule())
                    .overlay(Capsule().stroke(model.palette.border, lineWidth: 0.6))
            }
            .environment(\.colorScheme, model.effectiveDark ? .dark : .light)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("小灯，\(model.demo ? "示例，" : "")\(model.title)，通过菜单栏查看详情")
    }
}

struct DriftCompletionView: View {
    @ObservedObject var model: Model

    var body: some View {
        Label(model.demo ? "示例任务已结束" : "本轮任务已结束", systemImage: "checkmark.circle")
            .font(.system(size: 12)).foregroundStyle(model.palette.text(0.9))
            .frame(width: 172, height: 32)
            .background(model.palette.background, in: Capsule())
            .overlay(Capsule().stroke(model.palette.border, lineWidth: 0.6))
            .frame(width: 174, height: 34)
    }
}
