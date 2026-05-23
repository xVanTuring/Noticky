(function () {
  "use strict";

  // ---- Simplified-Chinese strings. English is read from the baked-in DOM. ----
  var ZH = {
    "nav.features": "功能",
    "nav.download": "下载",

    "hero.eyebrow": "原生 · 菜单栏常驻 · macOS 15+",
    "hero.title": "常驻菜单栏的便签。",
    "hero.lede": "macOS 原生便签与速记 —— 全局快捷键、多窗浮窗、Markdown，可选 iCloud 同步。无 Dock 图标，不占地方。",
    "hero.download": "下载 macOS 版",
    "hero.github": "在 GitHub 查看",
    "hero.req": "需要 macOS 15.0 或更高版本 · 免费开源 · 通过 Sparkle 自动更新",

    "f.float.title": "浮窗便签",
    "f.float.body": "6 色调色板，三种排版模式。给便签打上 Pin，下次启动自动恢复 —— 关掉 App 也不丢现场。",
    "f.float.li1": "<b>Free</b> —— 屏幕上任意摆放。",
    "f.float.li2": "<b>Stack</b> —— 层叠 cascade，选中谁谁滑到最下方完整可见。",
    "f.float.li3": "<b>Tile</b> —— 自动平铺成网格，拖动即可重排。",
    "f.float.li4": "常驻最上层、双击折叠、失焦半透明 —— 都可在 Settings 关。",

    "f.tile.title": "平铺、重排、一眼全见",
    "f.tile.body": "Tile 模式把所有打开的便签自动排成网格，拖动一个，其余自动让位 —— 整块白板一目了然。",

    "f.menu.title": "一切，一键之遥",
    "f.menu.body": "Perch 常驻菜单栏 —— 无 Dock 图标、无主菜单噪音。一键新建便签、查看最近便签、Show/Hide All、打开管理窗口、切换布局与设置。",
    "f.menu.li1": "菜单里直接列出最近便签 —— 一点即跳。",
    "f.menu.li2": "<b>Show / Hide All Stickies</b> 一次性收起或唤回整个工作集。",
    "f.menu.li3": "100% 原生 AppKit + SwiftUI —— 快、轻，无 Electron。",

    "f.capture.title": "随处速记",
    "f.capture.body": "全局快捷键（默认 ⌘⇧N，可完全自定义）在任何 App 里拉起速记窗口。通过辅助功能 API 抓选中文本、读剪贴板，或直接空白起笔。",
    "f.capture.li1": "<b>AX + 白名单</b> —— 按 bundle ID 抓 frontmost App 的选中文本。",
    "f.capture.li2": "<b>仅剪贴板</b> —— 不调 AX，直接用剪贴板内容预填。",
    "f.capture.li3": "<b>关闭</b> —— 一个空白窗口，记下灵感。",

    "f.md.title": "纯文本，或 Markdown",
    "f.md.body": "纯文本或 Markdown 随你写 —— 原生 NSTextView 编辑器，不锁专有格式。一键在「可编辑源码」与「渲染态」之间切换。",
    "f.md.li1": "<b>编辑态</b> —— 你的原始文本 / Markdown，可全选、可迁出。",
    "f.md.li2": "<b>渲染态</b> —— 标题、列表、任务复选框、代码块（基于 Textual）。",
    "f.md.li3": "全局字号（12–24），实时同步到每一个打开的窗口。",

    "g.manager.title": "管理窗口",
    "g.manager.body": "原生侧栏 —— 分组、Ungrouped、Trash。拖便签进分组、全文搜索、右键重命名/移动，以及多选批量操作。",

    "g.trash.title": "软删除与回收站",
    "g.trash.body": "删除进 Trash。超过 N 天（默认 30，可调 7–365）的旧条目在启动时清理 —— 与 macOS Notes、Mail 一致。",

    "g.io.title": "导入 · 导出 · 备份",
    "g.io.body": "单条或批量 Markdown 导出，以及整库导出 / 导入（SQLite 或 Markdown）。Restore 按 UUID 去重，不覆盖现有数据。",

    "g.icloud.title": "可选 iCloud 同步",
    "g.icloud.body": "默认关闭。开启后走 NSPersistentCloudKitContainer 跨 Mac 实时同步。已验证中国区 iCloud。",

    "g.l10n.title": "中英双语",
    "g.l10n.body": "内置英文与简体中文。默认跟随系统语言，也可在 Settings → General 强制指定。",

    "g.safety.title": "数据安全优先",
    "g.safety.body": "存储加载失败时 Perch 绝不静默销毁 —— 会把 sqlite/shm/wal 三件套备份到桌面并弹窗提示后再退出。",

    "g.oss.title": "免费且开源",
    "g.oss.body": "已签名、已公证、完全开源。通过 Sparkle 自动更新。macOS 15+。",

    "dl.title": "获取 Perch",
    "dl.body": "免费开源。下载已签名、已公证的构建 —— 之后会自动更新。",
    "dl.all": "全部版本"
  };

  var KEYS = Object.keys(ZH);
  var EN = {};
  var nodesByKey = {};

  // Index every [data-i18n] node and snapshot the baked-in English.
  document.querySelectorAll("[data-i18n]").forEach(function (el) {
    var k = el.getAttribute("data-i18n");
    (nodesByKey[k] = nodesByKey[k] || []).push(el);
    if (!(k in EN)) EN[k] = el.innerHTML;
  });

  function apply(lang) {
    var dict = lang === "zh" ? ZH : EN;
    KEYS.concat(Object.keys(EN)).forEach(function (k) {
      var val = (lang === "zh" ? ZH[k] : EN[k]);
      if (val == null) val = EN[k];
      (nodesByKey[k] || []).forEach(function (el) { el.innerHTML = val; });
    });
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    document.documentElement.setAttribute("data-lang", lang);
    var btn = document.getElementById("langToggle");
    if (btn) {
      btn.textContent = lang === "zh" ? "EN" : "中文";
      btn.setAttribute("aria-label", lang === "zh" ? "Switch to English" : "切换到中文");
    }
    try { localStorage.setItem("noticky-lang", lang); } catch (e) {}
  }

  function initialLang() {
    var saved;
    try { saved = localStorage.getItem("noticky-lang"); } catch (e) {}
    if (saved === "zh" || saved === "en") return saved;
    return (navigator.language || "").toLowerCase().indexOf("zh") === 0 ? "zh" : "en";
  }

  apply(initialLang());

  var toggle = document.getElementById("langToggle");
  if (toggle) {
    toggle.addEventListener("click", function () {
      apply(document.documentElement.getAttribute("data-lang") === "zh" ? "en" : "zh");
    });
  }

  // ---- Resolve the latest release: real .dmg URL + version label. ----
  fetch("https://api.github.com/repos/xVanTuring/Perch/releases/latest", {
    headers: { "Accept": "application/vnd.github+json" }
  })
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (rel) {
      var tag = rel.tag_name || "";
      var dmg = (rel.assets || []).filter(function (a) {
        return /\.dmg$/i.test(a.name);
      })[0];
      var url = dmg ? dmg.browser_download_url : rel.html_url;
      ["downloadBtn", "downloadBtn2"].forEach(function (id) {
        var el = document.getElementById(id);
        if (el && url) el.setAttribute("href", url);
      });
      if (tag) {
        ["dlVersion", "dlVersion2"].forEach(function (id) {
          var el = document.getElementById(id);
          if (el) el.textContent = tag;
        });
      }
    })
    .catch(function () { /* keep the static releases/latest fallback href */ });
})();
