# cc-sessions

macOS 菜单栏小工具：管理本机 Claude Code 会话——查看开着的会话与状态、检索历史会话、改名、一键跳转或恢复到 iTerm。

## 功能
- 菜单栏图标，橙色数字 = 等你处理的会话数；点图标或按 `⌥⌘K` 打开面板
- 开着的会话按「等你处理 / 运行中 / 空闲」分组，显示目录、git 分支、在等什么
- 历史会话全文检索（会话名 + 聊天内容），按 ↑↓ 选择、回车跳转
- 点击跳转：开着的会话切到对应 iTerm 标签页；后台会话 `claude attach`；没开着的新开标签页在原目录 `claude --resume`
- 悬停一行可改名、在 Finder 打开、复制恢复命令

## 构建
需要 macOS 14+ 和 Command Line Tools（自带 swiftc），不需要 Xcode。

```bash
./build.sh            # 生成 build/CCSessions.app
./build.sh install    # 安装到 /Applications 并启动
build/CCSessions.app/Contents/MacOS/cc-sessions --dump   # 不开界面，打印读到的会话，排查用
```

首次跳转时 macOS 会询问是否允许控制 iTerm，点「好」。

## 数据来源（只读，改名除外）
| 数据 | 来源 |
|---|---|
| 开着的会话与状态 | `~/.claude/sessions/<pid>.json`（Claude Code 的会话登记表） |
| 后台会话 | `claude agents --json`（低频调用） |
| 历史会话 | `~/.claude/projects/*/*.jsonl`，增量解析，索引缓存在 `~/Library/Caches/cc-sessions/` |
| 分支 | 直接读目录的 `.git/HEAD` |

改名：历史会话在记录末尾追加一条 `custom-title`；开着且空闲的会话向其 iTerm 标签页发送 `/rename`（开着的会话每轮会把内存里的名字写回记录，只改文件会被覆盖）。
