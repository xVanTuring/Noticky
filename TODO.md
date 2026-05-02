# Noticky 待办清单

完成一项后改 `[ ]` → `[x]`(保留行,git 历史可追)。每项后括号是简要动机/难度 hint。

## A. 代码里已有 stub(用户在 UI 里能看到"未实现"提示)

- [ ] Settings → **Shortcuts** 允许用户自定义快捷键(目前只读列表 + footer "is on the roadmap")
- [ ] Settings → **Notes** 补 tab 内容:默认便签颜色 / 默认字号 / 默认窗口尺寸 / 渲染态默认开关
- [ ] Settings → **iCloud Sync** 真正接入(`PersistenceController` 注释提到的 Phase 3:切到 `NSPersistentCloudKitContainer`)

## B. 体验类(常见便签 app 有 / 用户可能想要)

- [ ] **拖拽笔记到分组**(目前只能右键 Move to Group)
- [ ] **批量操作扩展**:多选后批量改色 / 批量 pin / 批量打开为浮窗(现在只支持移动 / 删除)
- [ ] **导入 / 导出**(.txt / .md 单条;整库 backup 一个 zip)
- [ ] **自定义颜色** 入口(目前固定 6 色板)
- [ ] **字体大小调整**(单条 / 全局两套?)
- [ ] **搜索结果高亮**(`.searchable` 已经过滤,但匹配文本不高亮)
- [ ] **回收站保留天数自定义**(目前 30 天硬编码在 `purgeExpiredTrash`)
- [ ] **强制暗 / 亮主题**(目前跟随系统)
- [ ] **Markdown 实时分屏预览**(目前是渲染 ↔ 编辑双态切换)
- [ ] **附件 / 图片支持**(当前纯文本)
- [ ] **提醒 / 闹钟**(笔记有时间触发)
- [ ] **多窗口同时编辑同一笔记**(目前 registry 强制一条笔记一个浮窗)

## C. 分发 / 上架

- [ ] **Core Data versioned model**(`PersistenceController.swift:79` 注释:目前是 nuke + 重建兜底,App Store 前必须换)
- [ ] **Developer ID 代码签名** + **notarytool 公证**(目前 Debug 直接跑)
- [ ] **DMG 打包脚本**
- [ ] **Sparkle 自更新框架**
- [ ] **Mac App Store 版本**:需要把 AX 抓取重做成独立 XPC service,因为 MAS 强制 sandbox(`Noticky.entitlements:13` 注释)

## D. 已知 polish / 非功能 bug

- (暂无追踪,出现新 bug 再加在这一节)

---

## 已完成(参考)

近期完成的功能不在此重复 —— 见 `git log --oneline` 看完整列表。
