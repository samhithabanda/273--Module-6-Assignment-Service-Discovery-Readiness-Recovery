"""Turn the captured terminal logs in docs/logs/ into PNG screenshots.

Each log is wrapped in a terminal-style HTML page and captured with headless Chrome.
Lines starting with "$ " (commands) and "# " (notes) are highlighted.
"""
import html
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOGS = ROOT / "docs" / "logs"
OUT = ROOT / "docs" / "screenshots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TITLES = {
    "01-deploy": "1. Deployment, Service and DNS lookup",
    "02-load-balancing": "1. Requests reach both replicas",
    "03-readiness-failure": "2. Readiness failure",
    "04-readiness-recovery": "2. Readiness restored",
    "05-pod-recovery": "3. Pod deletion and replacement",
}


def render(log: pathlib.Path) -> None:
    lines = log.read_text().rstrip("\n").splitlines()
    body = []
    for line in lines:
        esc = html.escape(line)
        if line.startswith("$ "):
            esc = f'<span class="p">samhitha@mac:~/module6</span> <span class="c">{esc}</span>'
        elif line.startswith("# "):
            esc = f'<span class="n">{esc}</span>'
        elif "0/1" in line or "Unhealthy" in line or "Terminating" in line:
            esc = f'<span class="w">{esc}</span>'
        body.append(esc)
    title = TITLES.get(log.stem, log.stem)
    page = f"""<!doctype html><meta charset="utf-8"><style>
body{{margin:0;background:#1e1e1e}}
.bar{{background:#323233;color:#ccc;font:13px -apple-system,sans-serif;padding:8px 12px}}
.dot{{display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:6px}}
pre{{margin:0;padding:14px 16px;color:#d4d4d4;font:13px/1.45 Menlo,monospace;white-space:pre}}
.p{{color:#4ec9b0}} .c{{color:#fff;font-weight:bold}} .n{{color:#dcdcaa}} .w{{color:#f48771}}
</style><div class="bar"><span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span>&nbsp; zsh — {html.escape(title)}</div>
<pre>{chr(10).join(body)}</pre>"""
    page_file = OUT / f"{log.stem}.html"
    page_file.write_text(page)
    width = min(2000, max(900, 8 * max(len(l) for l in lines) + 60))
    height = 70 + int(13 * 1.45 * len(lines))
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--window-size={width},{height}",
                    f"--screenshot={OUT / (log.stem + '.png')}", page_file.as_uri()],
                   check=True, capture_output=True)
    page_file.unlink()
    print("wrote", OUT / f"{log.stem}.png")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for log in sorted(LOGS.glob("*.txt")):
        render(log)
