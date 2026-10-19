#!/usr/bin/env python3
"""Install a new local copy. Refuse to overwrite an existing app or different extension."""
from pathlib import Path
import os
import shutil
import subprocess
import uuid

root = Path(__file__).resolve().parent
source = root / "build.noindex/智能体工作灯.app"
destination = Path("/Applications/智能体工作灯.app")
extension_source = root / "Resources/agent-lantern.ts"
extension = Path.home() / ".pi/agent/extensions/agent-lantern.ts"
if destination.exists():
    raise SystemExit("应用已存在，已保留。更新前请退出旧版并单独备份或移走该应用。")
if extension.exists() and extension.read_bytes() != extension_source.read_bytes():
    raise SystemExit("检测到不同的同名 Pi 扩展，已保留；请先核对该扩展。")
if not source.exists():
    subprocess.run(["python3", str(root / "build.py")], check=True)
temporary = destination.with_name(".AgentLantern-install-" + str(uuid.uuid4()) + ".app")
try:
    shutil.copytree(source, temporary, symlinks=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(temporary)], check=True)
    extension.parent.mkdir(parents=True, exist_ok=True)
    if not extension.exists(): shutil.copy2(extension_source, extension)
    temporary.rename(destination)
finally:
    if temporary.exists(): shutil.rmtree(temporary)
subprocess.run(["/usr/bin/open", str(destination)], check=True)
print("已安装并启动：" + str(destination))
print("Pi 新会话会自动接入；现有终端会话可 /reload。")
hermes_home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes").expanduser()
hermes_plugin = hermes_home / "plugins/agent-lantern-metrics"
plugin_source = root / "Resources/hermes-metrics"
if hermes_home.is_dir() and not hermes_plugin.exists():
    shutil.copytree(plugin_source, hermes_plugin, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    command = shutil.which("hermes")
    if command:
        result = subprocess.run([command, "plugins", "enable", "agent-lantern-metrics"], check=False)
        if result.returncode == 0: print("Hermes TPS 插件已启用；下次启动 Hermes 后生效。")
    else:
        print("Hermes 插件已复制；运行 hermes plugins enable agent-lantern-metrics 启用。")
