import Foundation

/// Observation metadata only. No message text, model secrets or fabricated packet counts.
struct MessageFlow: Codable, Equatable {
    var phase: String
    var at: Double
    var detail: String
    var transfers: [FlowTransfer]? = nil
    var playback: [TransferPulse]? = nil

    func display(at now: Double, waiting: Bool) -> FlowPhase {
        if waiting { return .waiting }
        guard at.isFinite, at <= now + 1 else { return .unknown }
        switch phase {
        case "request": return now < at + FlowPhase.sendingDuration ? .sending : .awaiting
        case "awaiting": return .awaiting
        case "receiving": return now - at <= 3 ? .receiving : .awaiting
        case "response": return now - at <= 2.5 ? .response : .recorded
        case "tools": return .tools
        case "processing": return .processing
        default: return .unknown
        }
    }
}

enum FlowPhase {
    case sending, awaiting, receiving, response, recorded, tools, processing, waiting, unknown, ended
    static let sendingDuration = 2.8
    var title: String {
        switch self {
        case .sending: return "请求已发起"
        case .awaiting: return "等待新响应"
        case .receiving: return "正在接收内容"
        case .response: return "观察到响应"
        case .recorded: return "响应已记录"
        case .tools: return "执行本地工具"
        case .processing: return "等待后续事件"
        case .waiting: return "等待你的确认"
        case .unknown: return "收发阶段未确认"
        case .ended: return "本次运行已结束"
        }
    }
    var moving: Bool { [.sending, .awaiting, .receiving, .response, .tools].contains(self) }
    var showsModelPrinciple: Bool { self == .awaiting || self == .receiving }
    var showsAgentCycle: Bool { self == .tools }
    var showsInboundFlow: Bool { self == .receiving || self == .response }
    var allowsMechanismMotion: Bool { self != .waiting && self != .ended }
    var showsAgentPrinciple: Bool { [.sending, .receiving, .response, .tools].contains(self) }
}
