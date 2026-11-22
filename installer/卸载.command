#!/bin/bash
clear
echo "=============================="
echo "  Claude 账号切换器 - 卸载"
echo "=============================="
echo ""
# 系统级组件:一次系统授权弹窗(账号密码填在弹窗里,不需要在终端输入密码)
ADMIN_CMDS="launchctl bootout system/local.claude-bodyguard 2>/dev/null; launchctl bootout system/local.tz-watchdog 2>/dev/null; launchctl bootout system/local.claude-update 2>/dev/null; rm -f /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist /Library/LaunchDaemons/local.claude-update.plist; rm -rf '/Library/Application Support/claude-switcher'"
echo "接下来会弹出系统授权窗口,请输入管理员账号和密码（用于移除守护进程与系统级文件）"
if /usr/bin/osascript - "$ADMIN_CMDS" <<'UNINSTALL_ADMIN_APPLESCRIPT'
on run argv
    do shell script ("/bin/bash -c " & quoted form of (item 1 of argv)) with administrator privileges
end run
UNINSTALL_ADMIN_APPLESCRIPT
then
    echo "✓ 系统级组件已移除"
else
    echo "✗ 管理员授权被取消,系统级组件未移除；如需彻底清理请重新运行本脚本"
    read -n 1 -s -r -p "按任意键退出..."
    exit 1
fi
launchctl bootout "gui/$(id -u)/local.claude-update" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.claude-update.plist"
sudo rm -rf "/Applications/Claude切换器.app"
# 兼容旧版桌面安装路径。
rm -rf "$HOME/Desktop/Claude切换器.app"
rm -f "$HOME/.local/bin/claude-switch.sh" "$HOME/.local/bin/claude-bodyguard.sh" "$HOME/.local/bin/tz-watchdog.sh" "$HOME/.local/bin/local.claude-bodyguard.plist" "$HOME/.local/bin/local.tz-watchdog.plist" "$HOME/.local/bin/local.claude-update.plist" "$HOME/.local/bin/claude-switch.sh.bak" "$HOME/.local/bin/claude-bodyguard.sh.bak" "$HOME/.local/bin/tz-watchdog.sh.bak"
echo ""
echo "✅ 已卸载。"
echo "注意: 账号存档保留在 ~/.claude-switcher/(含你的登录态),要删干净可手动: rm -rf ~/.claude-switcher"
echo "置顶规则提示: 如曾在 Clash 系客户端配置过置顶规则,可手动清空 全局扩展配置(Merge.yaml / Script.js);其他客户端的规则请自行检查。"
echo ""
read -n 1 -s -r -p "按任意键关闭窗口..."
