# Zoho Mail IPA：所有收件箱专项分析

> 后续核查修正：请同时阅读 `Zoho-Mail-iOS-3.10.1-REA深度逆向核查.md`。本报告中的 UnifiedMail 名称片段尚不能视为有效导出或已恢复函数；后续 REA 元数据读取未恢复可靠业务调用链。本文的桌面实现建议是工程方案，不是已确认的 iOS 原版内部实现。

分析日期：2026-10-19。问题：能否把多个账号的收件箱合并显示，避免反复切换？

## 结论

可以为自己的 Mail Lite 实现这一功能。所给 IPA 内包含明确的“所有收件箱 / 统一收件箱”产品资源，多账号汇总邮件的名称线索也与此吻合。当前 Mail Lite 0.1.3 尚无汇总邮件的数据层，需要新增合并列表及每个账号的邮件读取授权，不能直接复用 IPA 二进制功能。

本次完成静态专项分析和公开接口核对，没有修改桌面客户端或操作用户邮件。

## 样本身份和覆盖

| 项目 | 观察值 |
| --- | --- |
| 输入 | `/Users/cavon/Downloads/ZohoMail.ipa` |
| IPA SHA-256 | `3d526423855d48f9ce2177a99443764c92b1acc3428f30320caae76c0ee2e5cb` |
| App | `Payload/Zoho Mail.app` |
| Bundle ID | `com.zoho.zmail` |
| 版本 / 构建 | `3.10.1 / 478` |
| 平台 | iOS，arm64，最低 iOS 16.0 |
| 主程序 SHA-256 | `f00473aaac88fe8ccda0238df5afad202424e9497861e6da9e8c059216d0e817` |
| REA 包清单 | 6,830 个 occurrence；未报告完整性矛盾 |
| 主程序限制 | `LC_ENCRYPTION_INFO_64.cryptid = 1`；加密区间偏移 16,384，长度 38,535,168 |

REA 实际调用：`open_binary` → `inspect_artifact(summary)` → `extract_artifact` → `inspect_plist` → 主程序 `open_binary` → `inspect_macho(summary)` → 保留结果的 load_commands 视图。未执行 IPA，未反编译加密代码，未抓取登录流量。

## 直接证据：界面资源

以下来自主 App 的资源包，不依赖 Watch 副本：

| 资源路径 | 键 | 值 |
| --- | --- | --- |
| `ZMLoginStrings.bundle/zh-Hans.lproj/Localizable.strings` | `onBoardingUnifiedInbox_label` | 一个收件箱统一管理所有Zoho邮箱 |
| `ZMLoginStrings.bundle/en.lproj/Localizable.strings` | 同上 | Multiple Zoho Mail accounts in a unified inbox |
| `ZMMailStrings.bundle/zh-Hans.lproj/Localizable.strings` | `title_allInboxes` | 所有收件箱 |
| 同上 | `title_unifiedInbox` | 统一收件箱 |
| `ZMSettingsStrings.bundle/zh-Hans.lproj/Localizable.strings` | `all_inboxes_title` | 所有收件箱 |

这些直接证明样本随包携带了统一收件箱的入口文案和多账号产品说明；不等同于本机运行验证了该入口。

## 辅助证据：未加密区域内的名称片段

主程序内可见以下 ASCII 片段，原始偏移及完整片段保存在 `zoho-ios-3.10.1/unified-symbols.txt` 和 `focused-static-evidence.json`：

- `0x295c4a7`：`AllInboxesMailListNavigatable`
- `0x2a3c1ed`：包含 `UnifiedMails`，以及 `users / filter / startTime / from / isConvSupported / limit / requestType / callback` 参数名称。
- `0x2a63120`：包含 `getUnified...Lists`，以及 `zuids / accIds / folder... / flagType / startTime / limit` 名称。
- `0x2a655d9`：包含 `UnifiedUnreadLists` 及账号、文件夹、分页相关参数名称。
- `0x2ab6903`：包含 `UnifiedMailListRequest` 名称片段。
- `0x2abc393`：包含 `UnifiedMailListResponse` 名称片段。
- `0x2ae9355`：包含 `ZGetUnifiedMailsFolderInfo` 名称片段。

解释：这些名称支持“账号 / 文件夹标识参与统一邮件列表读取，并存在筛选和分页”的推断。它们是原始字符串片段，不是完整恢复的 Swift 符号、反编译结果或调用链。`dyld_info -exports` 只列出了主头符号，因此没有将上述片段冒充已恢复的导出函数。

未知：iOS 内部具体请求地址、授权结构、是否逐账号并发读取或由服务器一次汇总、跨数据中心行为、实时更新策略。受加密和无运行观测限制，不能从这些名称证明其内部算法。

## 对当前 Mail Lite 的含义

当前源码 `src/main.cjs:169` 的 `loadAccount` 会释放现有页面，再为所选账号的独立 partition 创建一个 `WebContentsView`。它一次显示一个 Zoho 网页，没有合并各账号邮件摘要的实现。保留独立登录状态解决了账号隔离，并不自动产生统一收件箱。

实现建议（工程方案，不声称是原版内部实现）：

1. 增加默认的“所有收件箱”，同时保留单账号入口。
2. 分别读取已授权账号的 Inbox，统一按时间倒序显示；每封信带来源邮箱和未读状态。
3. 用“本地账号标识 + 远端 accountId + messageId”定位邮件，避免不同账号的消息混淆。
4. 第一版可保留网页阅读、回复和写信：点击汇总列表中的邮件后自动进入所属账号及目标邮件，用户不必先手动切换。具体深链接仍需验证。
5. 每个账号单独维护分页及失败状态；一个账号失效时提示该账号，不遮蔽其他账号的邮件。

官方公开接口已核对：[List Emails](https://www.zoho.com/mail/help/api/get-emails-list.html)，按 `accountId` 和 `folderId` 读取列表，使用 OAuth 消息读取权限，支持分页、未读筛选及按日期排序。由客户端分别读取后合并具备公开接口基础。该文档不证明 iOS 使用同一个接口，也不意味着现有网页 Cookie 已拥有 OAuth 权限；正式实现前仍需接入授权并验证账号可访问性。

## 证据索引

- 包清单母证据：`ev_a2c9b4e91e26761dab6e55653be82915b2b6e46cc9f469c8e23603069d4d469a`
- 包清单 summary：`ev_2b65d5e1dbb2509e193059206f68946009b437567b6b943a0fc3c91caff9fa16`
- 提取：`ev_9ec831a467e059add17e07b6c45c7f9b20b5bac9ff6b43a12a332ba650f5dc9a`
- Info.plist：`ev_f57a6fce133bbaa5ab1d7807ea4c66b985e1d4fa307cc279cee5cf2f7a89bbe2`
- 引导文案：`ev_f4d624b660a34d6bd6930fb21e57ee22b9aaad971849109bdafedaaec11172be`
- 邮件文案：`ev_c7acc30cd058b598b1cba675f2b1cfdae7122baf25360279218487f53d22eafd`
- Mach-O 母证据：`ev_621dbe9dadaac3591334fb63ab36bdac5b851c727eaf7f74ce990aa4d693b366`
- 加密标记 load_commands 视图：`ev_23969c1d9dde3abf559a65f1e7d1b1716ca8f7cc7e26ed6e6a9db4c214c2d21f`
- REA 结果与选定命令记录：`zoho-ios-3.10.1/rea-evidence.json`
- 补充资源解析、哈希与字节偏移：`zoho-ios-3.10.1/focused-static-evidence.json`

问题完成度：包内功能证据已找到；当前桌面版缺口已确认；公开实现路径已核对；iOS 内部网络实现和桌面新功能均未运行验证。
