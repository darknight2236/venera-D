"""Print label distribution and hottest issues for quick triage."""
import json
import sys
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

d = json.load(open("design/upstream_issues/open_issues.json", encoding="utf-8"))
print("总数:", len(d))

lc = Counter()
for it in d:
    if not it["labels"]:
        lc["(无标签)"] += 1
    for l in it["labels"]:
        lc[l] += 1

print("=== 标签分布 ===")
for l, c in lc.most_common():
    print(f"{c:4d}  {l}")

print("=== 评论数最高的 15 个（热度）===")
for it in sorted(d, key=lambda x: -x["comments"])[:15]:
    lbls = ",".join(it["labels"]) or "-"
    print(f"#{it['number']} [{it['comments']}评论] [{lbls}] {it['title'][:50]}")
