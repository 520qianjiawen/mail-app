# Mail Lite 0.4.38「Aurora」— 原生实现说明

Swift + SwiftUI + AppKit + 系统 WebKit；macOS 14+、Apple Silicon；不含 Electron/Node/Chromium。

## 0.4.38 发件通道

主发送链路改为 IPA 对照的 `MailSendAPI`：先获取账号上传域名，普通附件与正文图片分别上传，发送 multipart 参数并核对完整邮件 ID 回执。实现与证据、测试边界见 [本版复核记录](../analysis/official-send-adapter-20261026/README.md)。

缺少 RFC Message-ID 的旧邮件/旧任务保留完整的公开 REST 回复通道；选择发生在上传前，发送失败不会自动换通道或重发。未猜测私有 `dmailid/mymid` 或已有附件实体。真实 Zoho 上传和投递尚未验收，不能视为完整 IPA 功能等价。

界面是新的三栏结构：侧栏（智能邮箱 / 账号 / 文件夹 / 标签）、会话列表、阅读器。旧的 AppKit 单栏界面完整保留在 `Legacy/` 作为对照，不参与编译。功能矩阵与验证边界见 [analysis/native-0.4.0/README.md](../analysis/native-0.4.0/README.md)。

## 结构

| 文件 | 职责 |
|---|---|
| `main.swift` | NSApplication、菜单与快捷键、夹具/截图模式 |
| `AppState.swift` | 单一状态源：范围、分页、筛选、搜索、动作、发件箱、账号、标签、角标 |
| `AccountSession.swift` | 每账号独立 `WKWebsiteDataStore`；登录窗（工具栏/诊断/弹窗/JS 对话框）、就绪检测、会话清理 |
| `MailAPI.swift` / `MailboxAPI.swift` | 受信 origin、CSRF、列表/正文/附件/发送/上传/搜索/会话/动作 |
| `MailOfficialProtocol.swift` / `MailOfficialAPI.swift` | 官方私有发送/上传格式、账号上传域名、multipart、回执与安全诊断 |
| `ZohoAPI.swift` | 标签、文件夹 CRUD、清空、阻止、假期回复、联系人（未实测接口集中隔离） |
| `MailCache.swift` | SQLite：列表、正文（最近 200 封及固定的离线正文）、账号目录 |
| `MailDetail.swift` | HTML 白名单 + CSP；暗色下按亮度重映射邮件自带颜色（保留图片） |
| `Outbox.swift` | 持久发件箱：定时、失败、不确定状态 |
| `Notifier.swift` | 系统通知与 Dock 角标 |
| `Design.swift` | Aurora 设计令牌与通用视图 |
| `RootView.swift` / `SidebarView.swift` / `MessageListView.swift` / `ReaderView.swift` | 三栏界面 |
| `ComposeWindow.swift` | 撰写窗、富文本编辑器、地址 chip、定时发送 |
| `SettingsView.swift` | 设置与本机草稿窗 |
| `SelfTests.swift` | 203 项模型/缓存/信任/HTML/队列检查 |

## 数据流

1. 启动：读取偏好与 SQLite → 先显示缓存列表 → 逐账号 `ready()` 后 `discover()` 拉取文件夹。
2. 列表：按当前范围逐账号取 Inbox/文件夹/标签/搜索页，写入 `messageStore` 与缓存，再本地合并会话、置顶优先、时间倒序。
3. 阅读：先读正文缓存；未命中时经账号会话取 `details`/`content`/`attachmentinfo`，写入缓存；正文在独立禁脚本视图渲染。
4. 操作：`MailAction` → 按账号分组 → `updatemessage`；成功后更新本地状态，失败只提示，不伪造。
5. 发送：`OutboxItem` 先落盘并冻结来源与 RFC 引用，再获取上传配置、上传、提交；取得有效邮件 ID 后才清理队列内容，失败/不确定保留待人工处理。

## 存储与安全

- `~/Library/Application Support/Mail Lite/Native/`：`preferences.json`、`mail-cache.sqlite`、`drafts/<uuid>/`、`outbox/<id>/`；目录 0700、文件 0600。
- 账号 Cookie 由 WebKit 数据存储管理；CSRF 只从会话读取，不持久化到偏好。
- 邮件正文：非持久、禁脚本、无 preload；`default-src 'none'`，图片仅 `data:`/`mail-inline:`（外部图片需显式开启）。
- 附件保存：系统保存面板；写入 `com.apple.quarantine`；单附件 25 MB 上限。
- 退出：保存草稿、取消刷新、关闭登录窗；发送/同步进行中阻止退出。

## 构建与验收

```sh
bash native/build.sh
bash native/package-dmg.sh
```

`build.sh` 会运行 `--self-test`（203 项）。安装并验证对应 DMG 后，另运行 `native/cleanup.py` 清理旧版本；不要在安装前清理。历史夹具截图命令：

```sh
"dist/0.4.5/Mail Lite.app/Contents/MacOS/Mail Lite" --fixture --light --open-first --snapshot test-results/0.4.0/reader.png
```

## 0.4.0 历史未完成清单

撤回、投递状态、SecurePass、S/MIME/PGP、分类标签、翻译、附件浏览器、正文内嵌图片、整文件夹已读、委派邮箱等条目属于历史 0.4.0 复核，不作为后续版本的当前功能矩阵。0.4.38 发件通道与真实投递验证边界以本版记录为准。
# 发布后清理

安装最新版本并生成对应 DMG 后，运行 `python3 native/cleanup.py`。脚本从项目版本读取当前版本，验证已安装应用及安装包后，仅保留 `/Applications/Mail Lite.app` 和对应 DMG，将重复构建、旧包和应用备份移到废纸篓，并注销旧应用搜索登记。清理前可使用 `--dry-run`；不要在安装前运行。打包临时副本会在退出打包脚本时注销。
