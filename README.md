# Mail Lite 0.1.4

基于本目录 REA 分析结果重新编写的个人 Zoho Mail 桌面窗口。邮件界面沿用 Zoho 网页；未复制官方应用 JavaScript、图片或原生模块。应用 Logo 使用用户提供的 `Glossy_Blue_Glass_Mail_Icon.png`，保留透明背景。

macOS 应用图标另外使用 Icon Composer 的 `.icon` 图层布局和蓝色背景填充，由 Xcode 编译为 `Assets.car` 并设置 `CFBundleIconName`；旧系统保留 `.icns`。原始 PNG 不重绘，图层放大以填满系统图标轮廓，修正新版 macOS 的外层白色底板和缩小问题。现代图标构建需要 Xcode 26 或更高版本。

第一版聚焦登录、查看邮件、搜索、撰写、回复、发送和附件。邮件操作由在线 Zoho 页面提供，桌面层负责独立窗口、持久登录分区、地区选择、导航和附件保存。没有新增托盘、自动更新、设备信任、打印预览、本地 EML 查看或离线邮箱。Zoho 网页自身的内容由服务端提供。

## 运行和打包

```sh
npm ci
npm start
npm test
npm run test:desktop
npm run test:inboxes
npm run package
npm run package:dmg
```

Mac ARM64 应用输出到 `dist/0.1.4/Mail Lite-darwin-arm64/Mail Lite.app`，安装镜像为 `dist/Mail-Lite-0.1.4-arm64.dmg`。本地 ad-hoc 签名用于开发试用，不是 Developer ID 签名或 Apple 公证。应用没有安装到 `/Applications`，也不替换官方 Zoho 客户端。

0.1.2 将顶部工具栏由 64px 缩为 44px，同步缩小按钮、Logo、文字和账号选择框，并调整原生窗口控制按钮及邮件视图位置。

0.1.3 的 ↻ 按钮表示刷新当前页面；原来的信封按钮改成主页图标，表示返回邮箱首页，并改为在原有 renderer/session 内导航，不再销毁重建邮件页面。首页地址跟随实际邮件服务地区。登录或身份验证页面暂停这两项操作（包括快捷键），以免重启验证流程；连接错误页仍可重试。状态栏在 Accounts 页面显示“正在登录或验证账号”。此修正不绕过 Zoho 服务端要求的身份验证；用户报告的复验触发原因尚未通过真实账号运行证据确认。

打包成功并验证新应用后，构建流程自动把本项目 `dist/` 中更旧的 Mail Lite 应用和安装镜像移到废纸篓，同时移除旧应用的系统启动注册。保留正在运行的版本，避免打断编辑；下次打包或执行 `npm run cleanup:releases` 会再次清理。此操作不访问账号数据目录。

首次启动在右上角选择邮箱所在地区，然后点击“打开 Zoho 邮箱”，直接在 Zoho 登录页面登录。普通账号登录不需要设置开发者 Client ID 或 Secret。企业自定义 SSO 域名和第三方账号的完整登录链尚未实测；原生 FIDO/Passkey 桥接没有实现。

## 添加和切换账号

1. 点击右上角账号列表旁的 **＋**，或选择菜单 **账号 → 添加账号…**（⌘⇧N）。
2. 填写账号名称或邮箱，选择邮箱地区，然后点击 **添加并登录**。名称仅用于本机识别，不代替 Zoho 登录；每个新账号都打开独立登录会话。
3. 添加后，在右上角下拉列表选择另一个账号即可切换，不必退出已有账号。同一地区可添加多个账号。
4. 可通过 **账号 → 重命名当前账号…** 修改显示名称。重启后保留账号列表、上次选中的账号和各自登录会话；Zoho 服务端仍可按自身策略要求重新认证。

从 0.1.0 升级时，旧的地区分区作为“原有账号”直接保留，不复制或清除 Cookie。已有名称只是本机标签，可以重命名为自己的邮箱。

## 所有收件箱（0.1.4）

- 顶部 **所有收件箱**、账号下拉列表或 **邮件 → 所有收件箱**（⌘⇧I）进入合并列表；已有多个账号时启动默认进入此页。
- 各账号的 Inbox 按时间倒序合并，每封信标明所属邮箱和未读状态；首屏最多 50 封，支持加载更多。可见窗口每分钟刷新，⌘R 可立即刷新。
- 点击邮件自动打开所属账号的网页及目标邮件，可继续阅读、回复、写信；顶部 **所有收件箱** 返回汇总页。进入汇总页只隐藏网页，不销毁草稿；跳转其他账号仍尊重原有未完成编辑提示。
- 账号失效时在汇总页单独提示 **去验证**，其他账号仍显示。验证完成后返回汇总页重新读取。
- 通过本应用各自的 Electron Session 和 Zoho 浏览器会话读取账号、Inbox 文件夹与邮件摘要，不要求设置 OAuth Client ID/Secret，不读取其他应用的 Cookie。服务仅发送固定的 GET 请求，不自动标记已读、删除、移动或发送邮件。点击后进入 Zoho 网页产生的阅读状态由该网页管理。
- Cookie 和 CSRF 只在主进程的原有 Session 内使用，不传给本地工具栏，不保存到新文件。汇总邮件摘要仅存于内存，清除登录和退出时取消请求并清空。服务接口改变时显示读取错误，不伪造邮件。
- 同一账号的 Newsletter / Notification 文件夹不因 `folderType=Inbox` 被误选；匹配根路径 `/Inbox`。来源账号和消息 ID 保留为字符串，避免大整数精度和跨账号混淆。

`npm run test:inboxes` 在独立临时账号分区的真实 Electron 中验证请求、CSRF、合并分页、来源标注、安全文本渲染、邮件定位、草稿取消、部分账号复验和空列表。最终在打包后的 0.1.4 中实测：两个现有账号均成功读取收件箱，合并首屏 50 封，加载更多入口可用。真实邮件打开及回复未操作，以免验证过程改变邮件阅读状态或发送内容；定位和草稿保护由临时测试邮箱页面验证。

## 数据和安全边界

- 默认数据目录为本应用的 Electron userData，即 macOS 下 `~/Library/Application Support/Mail Lite/`。不读取官方 Zoho 客户端的账号或 Cookie。
- 每个账号有独立持久分区，即使地区相同也不共享 Cookie 或网页存储。普通模式不记录密码或授权 URL；本地 preferences 保存账号 ID、名称、地区、上次选中项、启动状态和窗口尺寸。分区名称由本地 ID 推导，不接受外部传入的任意分区路径。
- 远端邮件页面启用 sandbox、contextIsolation，关闭 Node 集成，不加载 preload，不暴露桌面 IPC。只有本地工具栏可调用经过 sender 与主 frame 验证的有限 IPC。
- 页面中的外站链接交给默认浏览器，禁用本地/可执行 URL；证书错误不做放行。相机、麦克风、定位、屏幕捕获等桌面权限没有启用。
- 附件由系统保存对话框确认，不自动打开；Mac 下载完成后写入 quarantine 来源标记。
- “邮件 → 清除本机登录状态”只作用于本应用的全部账号及旧版地区分区，用户确认后清理站点存储、缓存和 HTTP 认证状态，保留账号名称，不删除服务器邮件或下载文件。
- 切换账号和关闭主页面尊重网页的 beforeunload 提示。辅助弹窗属于当前邮件会话，切换账号时关闭。

## 验证

`npm test` 检查 URL 信任边界、危险协议、仿冒域名、旧版迁移、独立账号分区和偏好文件输入。

`npm run test:desktop` 启动真实 Electron，在临时 userData 中对 HTTPS 使用本地静态响应：验证旧版分区迁移、同地区账号的 Cookie / localStorage 隔离、添加/切换/重命名、重启后的账号与 Cookie 保留、远端 View 的隔离参数、附件下载和 quarantine、前进后退、最小窗口、断网恢复及正常退出。测试不登录邮箱、不发送邮件，结束后删除临时会话。截图输出在 `test-results/`。

`node scripts/live-login-check.cjs` 只在临时会话打开公开 Zoho 登录页，记录是否到达 Accounts 域名，停止在输入凭据之前。真实账号的收发、上传附件、复杂 HTML 编辑及会话重启保持，需用户登录后验证，不能由静态分析或测试页面替代。

修复记录：首次桌面测试暴露已销毁 View 的 `webContents` 失效引用；清理函数已兼容对象不存在和已销毁状态，地区切换及退出重新验证通过。

## 实现参考

- 本地 `analysis/Zoho-Mail-1.10.5-REA分析报告.md` 与保留的发布包证据。
- [Electron WebContentsView](https://www.electronjs.org/docs/latest/api/web-contents-view)
- [Electron BaseWindow 的资源释放](https://www.electronjs.org/docs/latest/api/base-window#resource-management)
- [Electron DownloadItem](https://www.electronjs.org/docs/latest/api/download-item)
- [Apple Icon Composer 图标布局和系统遮罩](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

这些文档用于桌面 API 实现；不构成对邮件账号业务功能已经实测的声明。
