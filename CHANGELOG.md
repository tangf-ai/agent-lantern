# 更新记录

## 0.5.0 · 2026-10-19

- 新增 DeepSeek Harness 本机任务检测，显示为 `DeepSeek`；按持有会话的进程和任务生命周期判断忙碌。
- 支持普通 JSONL、Zstandard 压缩会话、已落盘的审批等待状态及正常完成提示；不把空闲窗口、进程退出或重启前的残留任务当作当前运行。
- 新增每任务 TPS 显示：Pi 的流式实际计数或最近响应均速，及 Hermes 本地观察插件的响应均速。没有可靠计数或计时则明确显示暂无数据。
- 包含自 v0.2.0 以来的工作核心动画、动态信号条、完成扩散效果及动画开关。
- 兼容不同区域设置的 Pi 进程启动日期格式，并将 MIT 许可证包含在应用包中。
- DeepSeek Harness 压缩日志需要 `zstd`；Codex 和 DeepSeek Harness 的 TPS 暂显示 `—`。
- 仅支持 Apple Silicon、macOS 14+，需要可用的 `/usr/bin/python3`；应用为 ad-hoc 签名，未进行 Apple 公证。
