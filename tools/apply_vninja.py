#!/usr/bin/env python3
"""把 v-ninja 客户端适配重新施加到 ClaudeSwitcher 上游代码上。

用法:
    python3 tools/apply_vninja.py            # 施加改动（已应用的会自动跳过）
    python3 tools/apply_vninja.py --check    # 只检查，不写文件
    python3 tools/apply_vninja.py --dry-run  # 显示将要做什么
    python3 tools/apply_vninja.py --revert   # 从 .vninja.bak 还原

退出码: 0 = 全部成功（含跳过），1 = 有失败项需要人工处理。
失败时会打印具体条目、文件、锚点和原因，便于定位上游结构变化。
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

SHELL_FILES = [
    "core/claude-switch.sh",
    "installer/安装.command",
    "installer/卸载.command",
    "daemons/claude-bodyguard.sh",
]


def load_rules(root):
    path = os.path.join(root, "tools", "vninja-patch.json")
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    rules = data.get("rules") or []
    if not rules:
        sys.exit("FAIL: 规则文件为空: " + path)
    return rules


def classify(text, rule, reverse=False):
    """判断规则状态：返回 apply / skip / fail。

    规则分两类：
      append  —— 新串包含旧串（典型是"在原文后追加一行"），旧串不会消失，
                 只能看新串是否就位；
      replace —— 新旧互不包含，必须旧串完全消失且新串就位才算已应用，
                 否则部分回退会被误判成已完成。
    """
    old, new, expected = rule["old"], rule["new"], int(rule.get("count", 1))
    old_count, new_count = text.count(old), text.count(new)
    append_kind = old in new

    if append_kind:
        if new_count >= expected:
            return "skip", ""
        if old_count == expected:
            return "apply", ""
        if old_count == 0:
            return "fail", "找不到锚点（上游这段可能已重写）"
        return "fail", "锚点出现 %d 次，预期 %d 次（上游结构可能已变）" % (old_count, expected)

    if old_count == expected:
        return "apply", ""
    if old_count == 0 and new_count >= expected:
        return "skip", ""
    if old_count == 0:
        return "fail", "找不到锚点（上游这段可能已重写）"
    return "fail", "部分匹配：旧串仍有 %d 处（预期 %d 处），可能上游已改动" % (old_count, expected)


def describe(rule, reverse):
    return rule["note"] or rule["id"]


def main():
    parser = argparse.ArgumentParser(description="重新施加 v-ninja 客户端适配")
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        help="仓库根目录（默认取脚本所在仓库）")
    parser.add_argument("--check", action="store_true", help="只检查，不写文件")
    parser.add_argument("--dry-run", action="store_true", help="显示改动但不落盘")
    parser.add_argument("--revert", action="store_true", help="从 .vninja.bak 还原")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    rules = load_rules(root)

    print("仓库: %s" % root)
    print("规则: %d 条%s" % (len(rules), "（反向还原）" if args.revert else ""))
    print("-" * 68)

    if args.revert:
        return do_revert(root)

    by_file = {}
    for rule in rules:
        by_file.setdefault(rule["file"], []).append(rule)

    stats = {"apply": 0, "skip": 0, "fail": 0}
    failures = []

    for path in sorted(by_file):
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            for rule in by_file[path]:
                stats["fail"] += 1
                failures.append((rule["id"], path, rule.get("note", ""), "文件不存在"))
                print("[FAIL] %-5s %-28s %s：文件不存在" % (rule["id"], path, rule.get("note", "")))
            continue
        with open(full, encoding="utf-8") as handle:
            text = original = handle.read()

        for rule in by_file[path]:
            status, reason = classify(text, rule)
            if status == "apply":
                text = text.replace(rule["old"], rule["new"])
                stats["apply"] += 1
                mark = "[ OK ]" if not (args.check or args.dry_run) else "[TODO]"
                print("%s %-5s %-28s %s" % (mark, rule["id"], path, describe(rule, False)))
            elif status == "skip":
                stats["skip"] += 1
                print("[SKIP] %-5s %-28s %s（已应用）" % (rule["id"], path, describe(rule, False)))
            else:
                stats["fail"] += 1
                failures.append((rule["id"], path, rule.get("note", ""), reason))
                print("[FAIL] %-5s %-28s %s：%s" % (rule["id"], path, describe(rule, False), reason))

        if text != original and not (args.check or args.dry_run):
            backup = full + ".vninja.bak"
            if not os.path.exists(backup):
                shutil.copy2(full, backup)
            with open(full, "w", encoding="utf-8") as handle:
                handle.write(text)

    print("-" * 68)
    if args.check or args.dry_run:
        print("待应用 %d · 已应用 %d · 失败 %d" % (stats["apply"], stats["skip"], stats["fail"]))
    else:
        print("成功 %d · 跳过 %d · 失败 %d" % (stats["apply"], stats["skip"], stats["fail"]))

    if failures:
        print("\n需要人工处理：")
        for rid, path, note, reason in failures:
            print("  - [%s] %s %s：%s" % (rid, path, note, reason))
        print("\n提示: 打开 docs/新增代理客户端适配规范.md 第 7 节，按条目编号对照改。")
        return 1

    if args.check:
        if stats["apply"]:
            print("\n还有 %d 条改动未应用，去掉 --check 直接运行即可施加。" % stats["apply"])
            return 1
        print("\n全部改动均已就位。")
        return 0

    if args.dry_run:
        print("\n[dry-run] 未写入任何文件。")
        return 0

    print("\n语法检查：")
    ok = True
    for rel in SHELL_FILES:
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            continue
        # 从 stdin 做语法检查:不依赖路径格式(Windows/WSL/Git Bash 都能用),
        # 也不受工作区 CRLF 影响(脚本在 macOS 上运行时本来就是 LF)。
        with open(full, encoding="utf-8") as handle:
            source = handle.read()
        proc = subprocess.run(["bash", "-n", "-s"], input=source.encode("utf-8"),
                              capture_output=True)
        err = (proc.stderr or b"").decode("utf-8", "replace").strip()
        if proc.returncode == 0:
            print("  ✓ %s" % rel)
        else:
            ok = False
            print("  ✗ %s\n    %s" % (rel, err))
    if not ok:
        print("\nFAIL: 语法检查未通过，可用 --revert 还原。")
        return 1
    print("\n下一步：重跑安装器或按 docs 第 3 节做端到端验证。")
    return 0


def do_revert(root):
    files = sorted({rule["file"] for rule in load_rules(root)})
    restored = []
    for rel in files:
        full = os.path.join(root, rel)
        backup = full + ".vninja.bak"
        if os.path.exists(backup):
            shutil.copy2(backup, full)
            print("[REST] %s" % rel)
            restored.append(rel)
    print("-" * 68)
    if not restored:
        print("没有找到 .vninja.bak，未做过改动或已还原过。")
        return 0
    print("已还原 %d 个文件（每个文件只还原一次）" % len(restored))
    print("如需再次施加改动，重新运行本脚本即可。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
