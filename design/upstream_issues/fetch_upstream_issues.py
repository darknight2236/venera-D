"""Fetch all open issues from the upstream venera-app/venera repo (read-only).

The repo is archived but still readable. Outputs a structured JSON to
design/upstream_issues/open_issues.json for further analysis. Pull requests
are filtered out (GitHub's issues API returns PRs too).
"""
import json
import os
import time
import urllib.request
import urllib.error

REPO = "venera-app/venera"
OUT_DIR = os.path.join("design", "upstream_issues")
OUT_FILE = os.path.join(OUT_DIR, "open_issues.json")


def fetch_page(page):
    url = (
        f"https://api.github.com/repos/{REPO}/issues"
        f"?state=open&per_page=100&page={page}"
    )
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "venera-D-issue-collector",
    })
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    all_issues = []
    page = 1
    while True:
        print(f"Fetching page {page} ...")
        batch = fetch_page(page)
        if not batch:
            break
        for it in batch:
            # Skip pull requests (they carry a 'pull_request' key)
            if "pull_request" in it:
                continue
            all_issues.append({
                "number": it["number"],
                "title": it["title"],
                "labels": [lb["name"] for lb in it.get("labels", [])],
                "created_at": it["created_at"],
                "updated_at": it["updated_at"],
                "comments": it["comments"],
                "url": it["html_url"],
                "body": (it.get("body") or "").strip(),
            })
        if len(batch) < 100:
            break
        page += 1
        time.sleep(1)  # be gentle to the API

    all_issues.sort(key=lambda x: x["number"], reverse=True)
    with open(OUT_FILE, "w", encoding="utf-8") as f:
        json.dump(all_issues, f, ensure_ascii=False, indent=2)
    print(f"Saved {len(all_issues)} open issues to {OUT_FILE}")


if __name__ == "__main__":
    main()
