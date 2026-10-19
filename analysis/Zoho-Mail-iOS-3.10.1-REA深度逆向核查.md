# Zoho Mail 3.10.1：REA 深度逆向核查

日期：2026-10-19。用户要求：先用 REA 逆向 IPA，确认原版统一收件箱的实现，再考虑客户端修改。

本轮只分析 IPA 及其提取内容，没有修改 Mail Lite 的界面、业务代码或版本，没有打包。此前临时创建的桌面列表探测脚本已删除；没有将它作为 IPA 实现证据。

## 结论与完成边界

本次完成了包内界面档案解析、原生元数据读取、Mach-O 区间核对、邮件资源核对及证据导出。**尚未恢复统一收件箱的业务函数、调用链或网络协议，因此不能声称已逆向清楚其内部实现。**

主程序声明加密，且代码与关键 Swift / Objective-C 字符串区均落入加密范围。原生元数据读取出现大量无法解析的字符串和指针，不能把这些结果转成可信的类型或方法结论。

用户的 iPhone 截图能确认该运行画面具有搜索、筛选、日期分组、头像、会话数量和账号标签；截图不证明 IPA 内部使用哪个接口、如何归并、如何分页，截图与所给二进制的精确版本对应也尚未独立验证。

## 样本身份

- 输入：`/Users/cavon/Downloads/ZohoMail.ipa`
- IPA SHA-256：`3d526423855d48f9ce2177a99443764c92b1acc3428f30320caae76c0ee2e5cb`
- 主程序 SHA-256：`f00473aaac88fe8ccda0238df5afad202424e9497861e6da9e8c059216d0e817`
- Bundle ID：`com.zoho.zmail`；版本 / 构建：`3.10.1 / 478`
- 本轮复用上次 REA 提取目录中的同一主程序，没有替换或修改样本字节。

## 1. REA 实际读取了哪些内容

1. `open_binary` 选择 IPA；然后选择提取的 `.app` 以运行需要 app 上下文的界面解析。
2. `binary_session` 核对工具和分析能力。Hopper 可用；Ghidra / IDA 未配置。未更改 REA 配置或安装工具。
3. `decode_interface_builder(detail=summary)` 解析 NIB / Storyboard。
4. `inspect_native_dispatch_metadata(max_records=20000)` 读取原生派发和 Swift 元数据。结果超过单次 MCP 响应预算，按照 REA 提示导出完整证据，没有重复执行同一读取来规避限制。
5. `inspect_macho(detail=summary)` 读取布局；`inspect_analysis_view` 按 segments 分页读取区间。
6. `inspect_asset_catalog` 先读取目录页，再定位 `ZMMailListKit.bundle/Assets.car` 的页。
7. `inspect_plist` 读取主 App 的中文邮件资源。
8. `export_evidence_bundle` 保存完整本轮证据；分析结束关闭目标。

一次 IPA 直接调用界面解析被工具拒绝，原因是该工具要求 `.app` 上下文；改为打开提取的 `.app` 后成功。一次旧证据引用不可用，原因是先前 `close_binary` 已清空会话保留记录；重新产生本次 Mach-O 证据后继续。两项都没有被记作成功分析。

## 2. 界面档案解析结果

REA 读取到 **63 个 NIB / Storyboard 文档、1,869 个节点、599 条关系**。识别出的文档主要属于登录 SDK、Apptics、ZohoDesk、媒体选择器，以及启动界面。

主 App 根层的已识别 Storyboard 文档是：

- `LaunchScreen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib`
- `LaunchScreen.storyboardc/UIViewController-01J-lp-oVM.nib`

这些结果没有提供可直接复建统一收件箱的完整界面树。不能把 ZohoDesk 的列表控件或 SDK 的表格控件当作 Zoho Mail 收件箱。各文档层级覆盖存在限制，动态创建的界面不在这项静态档案解析的证明范围内；本次也没有从这些档案恢复像素布局。

证据：`ev_46bedab2d448f6dd727d81acabcf20054d2717345d8f970d70aee136d8c51134`。

## 3. 加密区间与业务代码的关系

主程序的 `LC_ENCRYPTION_INFO_64`：

- `cryptid = 1`
- `cryptoff = 16384`
- `cryptsize = 38535168`
- 声明加密范围为文件偏移 `[16384, 38551552)`。

| 节 | 文件偏移 | 长度 | 与声明加密范围的关系 |
| --- | ---: | ---: | --- |
| `__TEXT,__text` | 16,384 | 32,398,960 | 完全位于其内 |
| `__TEXT,__cstring` | 33,603,600 | 1,178,072 | 完全位于其内 |
| `__TEXT,__swift5_typeref` | 35,441,616 | 1,176,645 | 完全位于其内 |
| `__TEXT,__swift5_reflstr` | 36,618,272 | 416,801 | 完全位于其内 |
| `__TEXT,__swift5_fieldmd` | 37,035,076 | 466,812 | 完全位于其内 |
| `__TEXT,__objc_methname` | 37,506,128 | 113,053 | 完全位于其内 |
| `__TEXT,__swift5_types` | 37,691,972 | 27,152 | 完全位于其内 |

仅修改加密标记不能恢复这些区间的明文字节。当前未获得这些区间的解密内容。

REA Mach-O 母证据：`ev_621dbe9dadaac3591334fb63ab36bdac5b851c727eaf7f74ce990aa4d693b366`。分段视图：`ev_f157f2bd4981afa86038242dc4be33299d6be04ab63bf546de620ec66c0ef051`。

补充的只读 Mach-O 头遍历检查了 17 个 thin 64-bit Mach-O 文件，它们均声明 `cryptid=1`。其中包括主程序、Widgets、Share 和 Notification 扩展。该补充脚本不覆盖所有其他架构或 Fat Mach-O，完整结果在 `zoho-ios-3.10.1/deep/macho-encryption-inventory.json`；它不是 REA 反编译结果。

## 4. 原生元数据读取没有恢复可用业务调用链

REA 读取结果中：

- `objc_dispatch_implementations = 0`
- `swift_decls = 0`
- `swift_conformances = 0`
- `swift_dispatch_slots = 0`
- `swift_symbols = 0`

工具返回少量 ObjC 类记录，但名字包含控制字符和残缺文本，并报告大量 UTF-8 解码失败、未映射 / 歧义指针及记录预算耗尽。没有将这些类记录认作可靠业务类型。

**这里的零不证明 App 没有相应方法或 Swift 类型，只说明这次读取在当前加密样本与覆盖限制下没有恢复它们。** 增加记录预算不会解密代码或修复被加密的类型字符串。

证据：`ev_540d4952c4269ac8212ee77905a0e590f336cf06ae2fc43cd19fc4ae22d15a3b`。可读摘要：`zoho-ios-3.10.1/deep/dispatch-summary.json`。完整原始诊断保存在本轮证据包。

## 5. 对先前 UnifiedMail 字符串线索的进一步校正

REA 的 Mach-O 导出读取仅返回 `__mh_execute_header`；没有恢复有效的统一收件箱导出函数。

补充的原始 export-trie 格式遍历从根节点只到达 2 个节点、1 个终端，其名称同样为 `__mh_execute_header`。声明的 trie 区域长 2,814,944 字节，但先前扫到的 `UnifiedMailList` 等片段位于未由该根遍历触达的剩余字节。

因此，先前的名称片段只能保留为原始字节线索，**不能证明它们是当前有效导出、完整 Swift 符号、已恢复类型、实际调用函数或运行中的请求模型**。本轮没有从这些片段拼出调用链，也没有把它们变成实现方案。

补充遍历记录：`zoho-ios-3.10.1/deep/export-trie-observations.json`。这是对 REA 导出结果的本地格式核对，非原始源码恢复。

## 6. 可以直接确认的资源

REA 从 `ZMMailStrings.bundle/zh-Hans.lproj/Localizable.strings` 读取到：

| 键 | 值 |
| --- | --- |
| `title_allInboxes` | 所有收件箱 |
| `title_unifiedInbox` | 统一收件箱 |
| `title_unread` | 未读 |
| `title_withAttachment` | 包含附件 |
| `title_flag` | 标记 |
| `title_archived` | 已归档 |
| `title_today` | 今天 |
| `title_yesterday` | 昨天 |
| `title_conversationsCount` | `%d 个对话` |

证据：`ev_c7acc30cd058b598b1cba675f2b1cfdae7122baf25360279218487f53d22eafd`。

资源目录共记录 3,823 条资产元数据。本轮取了目录首页，并额外读取邮件列表资源包的完整 35 条元数据记录。该包包含 `envelope.arrow.custom`、`envelope.arrow.left.custom`、`envelope.arrow.right.custom` 等矢量字形以及引导图片。字形记录包含参考字号、字重等元数据，不能据此确定截图中行高、头像算法或控件的实际布局。

目录页证据：`ev_2df646b3dd8eb87f958abfe8ccb109c1e80fc944e492bd18be62fdf0545b90c7`；邮件列表资源页：`ev_3ff5bada88548e276132bf5c95fcb12438672f42fbd6f09f59dfe5232df21498`。

## 7. 原问题逐项状态

| 问题 | 当前状态 |
| --- | --- |
| 包内是否有统一收件箱及相关筛选文案 | 已确认资源存在 |
| 截图是否展示会话数量和日期分组 | 用户截图可见；未独立绑定其运行版本 |
| 能否恢复统一收件箱完整界面树 | 本轮未恢复；已识别档案没有提供它 |
| 会话如何判定、归并、计数 | 未确认 |
| 多账号邮件在客户端还是服务器汇总 | 未确认 |
| 实际请求地址、方法、参数、鉴权 | 未确认 |
| 已归档、标记、附件筛选的真实实现 | 未确认 |
| 邮件点击后的原版导航与阅读控制流程 | 未确认 |

下一步要恢复业务实现，需要该版本主程序及相关组件的明文字节，例如合法取得的解密 IPA / 可分析的开发构建；运行时请求和交互则需要对应 iPhone App 的可采集运行证据。只有截图和当前加密 IPA，仍不足以确认原版内部流程。

## 证据文件

- 完整 REA 证据：`zoho-ios-3.10.1/deep/rea-native-evidence.json`
- 原生读取摘要：`zoho-ios-3.10.1/deep/dispatch-summary.json`
- 补充头部遍历：`zoho-ios-3.10.1/deep/macho-encryption-inventory.json`
- 补充 export-trie 检查：`zoho-ios-3.10.1/deep/export-trie-observations.json`

本报告不把桌面客户端接口试验、公开 Web API 文档或 Zoho 网页代码当作 iOS IPA 的内部实现证据。
