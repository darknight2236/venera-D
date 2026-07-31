"""Group issues by inferred theme keywords for the analysis report."""
import json
import sys

sys.stdout.reconfigure(encoding="utf-8")
d = json.load(open("design/upstream_issues/open_issues.json", encoding="utf-8"))

themes = {
    "阅读器/翻页": ["翻页", "阅读", "双页", "滚动", "下一话", "下一章", "章节", "缩放", "自动滚"],
    "下载": ["下载", "导出"],
    "本地漫画/收藏": ["本地", "收藏", "标签", "目录"],
    "同步/WebDAV": ["webdav", "同步", "网盘", "sftp", "icloud", "云"],
    "格式支持": ["epub", "mobi", "pdf", "cbz", "avif", "格式", "动图"],
    "崩溃/打不开": ["崩溃", "打不开", "打不開", "报错", "闪退", "无法"],
    "平台特定": ["windows", "win10", "win", "macos", "ipad", "ios", "hyperos", "coloros", "arm", "鸿蒙"],
    "UI/交互": ["全屏", "菜单", "手势", "旋转", "字体", "封面", "通知"],
}


def kind(it):
    return "BUG" if any("bug" in l for l in it["labels"]) else "ENH"


assigned = set()
for name, kws in themes.items():
    hits = []
    for it in d:
        text = (it["title"] + it["body"]).lower()
        if any(k.lower() in text for k in kws):
            hits.append(it)
    hits.sort(key=lambda x: -x["comments"])
    print(f"\n### {name} ({len(hits)})")
    for it in hits[:12]:
        print(f"  {kind(it)} #{it['number']} c{it['comments']} {it['title'][:45]}")
        if it["number"] not in assigned:
            assigned.add(it["number"])

print(f"\n覆盖 {len(assigned)}/{len(d)} 个 issue")
