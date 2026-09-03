#!/usr/bin/env python3
# =============================================================================
#  build-html.py — แปลง docs/*.md เป็นเว็บคู่มือที่ใช้ทำงานจริงได้
# =============================================================================
#  รัน:  python tools/build-html.py
#  ผลลัพธ์: html/  (เปิด html/index.html ด้วยเบราว์เซอร์)
#
#  สิ่งที่เพิ่มให้จาก markdown เดิม:
#   · ทุก code block มีปุ่ม copy
#   · ทุกหัวข้อ (##) มีปุ่ม "ทำแล้ว" — กดแล้วเปลี่ยนสีพื้นหลัง จำไว้ใน localStorage
#   · ปุ่มลอยขวาล่าง กระโดดไปขั้นที่ต้องทำต่อไป
#   · แถบความคืบหน้าต่อบท และหน้าแรกสรุปทุกบท
#
#  ไฟล์ที่ได้เป็น self-contained ทั้งหมด — เปิดแบบ file:// ได้ ไม่ต้องมีเน็ต
# =============================================================================
#  ⚠️ กติกาการเขียน docs/*.md ที่มาจากข้อจำกัดของ renderer นี้:
#     ปุ่ม copy คัดลอก "ทั้งบล็อก" เสมอ เลือกทีละบรรทัดไม่ได้
#     คำสั่งที่เป็นทางเลือกแทนกัน (เช่น เลือก config ตามเครื่องที่ทำอยู่)
#     จึงห้ามอยู่บล็อกเดียวกัน ต้องแยกเป็นคนละบล็อกพร้อมหัวข้อกำกับ
#     ไม่งั้นคนที่กดปุ่มจะได้ทุกทางเลือกมารันรวดเดียว แล้วเหลือผลของอันสุดท้าย
# =============================================================================
import io
import json
import posixpath
import re
import sys
from pathlib import Path

try:
    from markdown_it import MarkdownIt
except ImportError:
    sys.exit("ต้องมี markdown-it-py ก่อน:  pip install markdown-it-py")

# console ของ Windows เป็น cp1252 — บรรทัดสรุปที่เป็นภาษาไทยจะทำให้ทั้งสคริปต์ตาย
# ตอนนั้นไฟล์ html/ ถูกเขียนไปแล้วบางส่วน จึงเหลือ html/ ที่อัปเดตครึ่งเดียว
# โดยที่คนรันเห็นแค่ traceback แล้วนึกว่าไม่มีอะไรถูกเขียนเลย
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = ROOT / "html"

# ลำดับบทตามที่ควรอ่าน — ไฟล์ที่ไม่อยู่ในนี้จะไม่ถูกแปลง
ANSIBLE_SRC = "ansible/README.md"   # runbook ของ Ansible — คนละโฟลเดอร์กับ docs/
ANSIBLE_OUT = "ansible.html"

CHAPTERS = [
    ("00-overview.md", "ภาพรวมและลำดับงาน"),
    ("01-prepare-os.md", "เตรียม OS"),
    ("02-container-runtime.md", "Container Runtime"),
    ("03-ha-layer.md", "HA Layer"),
    ("04-create-cluster.md", "สร้าง Cluster"),
    ("05-cilium.md", "Cilium"),
    ("06-verify.md", "ตรวจรับระบบ"),
    ("07-gateway-tls.md", "Gateway + TLS"),
    ("08-storage.md", "Storage"),
    ("09-observability.md", "Observability"),
    ("10-security.md", "Security"),
    ("11-deploy-app.md", "Deploy App"),
    ("12-day2-operations.md", "Day-2 Operations"),
    ("13-troubleshooting.md", "Troubleshooting"),
    ("CHECKLIST.md", "เช็กลิสต์งานค้าง"),
]


def make_md():
    md = MarkdownIt("gfm-like").disable("linkify")

    def fence(self, tokens, idx, options, env):   # add_render_rule ผูกเป็น method จึงต้องมี self
        tok = tokens[idx]
        lang = (tok.info or "").strip().split()[0] if tok.info else ""
        code = tok.content
        esc = (code.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        label = lang or "text"
        return (
            '<div class="cb">'
            # แถบ copy อยู่ใต้โค้ด — อ่านจบแล้วปุ่มอยู่ตรงนั้นพอดี ไม่ต้องเลื่อนย้อนขึ้น
            f'<pre><code class="language-{label}">{esc}</code></pre>'
            f'<div class="cb-bar"><span class="cb-lang">{label}</span>'
            '<button class="cb-copy" type="button">คัดลอก</button></div>'
            "</div>\n"
        )

    md.add_render_rule("fence", fence)
    return md


def rewrite_links(html: str, src_dir: str = "docs") -> str:
    """แปลงลิงก์ให้ถูกเมื่ออ่านจาก html/

    src_dir คือโฟลเดอร์ของไฟล์ .md ต้นทาง (เทียบจาก root ของ repo)
    ต้องรู้เพราะลิงก์ในไฟล์เป็น relative กับที่มันอยู่ ไม่ใช่กับ html/
    """
    def repl(m):
        href = m.group(1)
        if href.startswith(("http://", "https://", "#", "mailto:")):
            return m.group(0)
        base, _, frag = href.partition("#")
        tail = ("#" + frag) if frag else ""

        # แปลงเป็น path เทียบจาก root ของ repo ก่อน แล้วค่อยคิดว่าจะชี้ยังไงจาก html/
        abs_path = posixpath.normpath(posixpath.join(src_dir, base))

        if base.endswith(".md"):
            name = Path(abs_path).name
            if any(name == c for c, _ in CHAPTERS):
                return f'href="{name[:-3]}.html{tail}"'
            if abs_path == ANSIBLE_SRC:
                return f'href="{ANSIBLE_OUT}{tail}"'
        # ไฟล์อื่นในrepo — html/ อยู่ชั้นเดียวกับ docs/ จึงถอยออกหนึ่งชั้น
        return f'href="../{abs_path}{tail}"'

    return re.sub(r'href="([^"]+)"', repl, html)


SPLIT = re.compile(r'(?=<h2[ >])')


def split_steps(html: str):
    """แบ่งเนื้อหาตาม <h2> — ก้อนแรกก่อน h2 แรกคือส่วนนำ ไม่นับเป็นขั้นตอน"""
    parts = SPLIT.split(html)
    intro = parts[0] if parts else ""
    steps = []
    for i, chunk in enumerate(parts[1:], start=1):
        m = re.match(r"<h2[^>]*>(.*?)</h2>", chunk, re.S)
        title = re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else f"ขั้นที่ {i}"
        body = chunk[m.end():] if m else chunk
        steps.append({"n": i, "title": title, "body": body})
    return intro, steps


MACHINES = [
    ("m01",     "👑", "master01"),
    ("masters", "🎩", "master ทุกตัว"),
    ("workers", "⚙️", "worker"),
]


def machine_of(text):
    """อ่านอีโมจิหน้าหัวข้อว่าขั้นนี้ทำบนเครื่องไหน — ไม่มีอีโมจิ = ใช้ได้ทุกเครื่อง

    ใช้ตัวเดียวกับที่บทที่ 00 ประกาศไว้ คนอ่านจึงไม่ต้องจำสัญลักษณ์ชุดใหม่
    """
    for key, emoji, _label in MACHINES:
        if emoji in text:
            return key
    return "all"


def wrap_subs(body, step_machine):
    """ห่อแต่ละหัวข้อย่อย (h3) ด้วย div ที่ติดป้ายเครื่อง เพื่อให้แถบกรองซ่อนได้ทีละอัน

    ข้อความก่อน h3 แรกถือเป็น "all" เสมอ — มันคือย่อหน้านำที่บอกภาพรวมของขั้นนั้น
    ซ่อนไปแล้วคนจะอ่านไม่รู้เรื่องว่ากำลังอยู่ตรงไหน
    """
    parts = body.split("<h3")
    if len(parts) == 1:
        return f'<div class="sub" data-machine="{step_machine}">{body}</div>', {step_machine}
    out, machines = [], set()
    if parts[0].strip():
        out.append(f'<div class="sub" data-machine="all">{parts[0]}</div>')
        machines.add("all")
    for chunk in parts[1:]:
        html = "<h3" + chunk
        head = html.split(">", 1)[1].split("</h3>", 1)[0] if ">" in html else ""
        m = machine_of(head)
        machines.add(m)
        out.append(f'<div class="sub" data-machine="{m}">{html}</div>')
    return "".join(out), machines


def page(chapter_file, title, subtitle, intro, steps, prev_ch, next_ch, nav, totals):
    step_html = []
    present = set()
    for s in steps:
        own = machine_of(s["title"])
        body, subs = wrap_subs(s["body"], own)
        tags = sorted(subs | {own})
        present |= {t for t in tags if t != "all"}
        s = dict(s, body=body, tags=" ".join(tags))
        step_html.append(
            f'<section class="step" id="step-{s["n"]}" data-step="{s["n"]}" data-machines="{s["tags"]}">'
            '<div class="step-head">'
            f'<h2>{s["title"]}</h2>'
            f'<span class="head-tick" title="ทำแล้ว">✓</span>'
            "</div>"
            f'<div class="step-body">{s["body"]}</div>'
            # ปุ่มอยู่ท้ายส่วน ตรงกับลำดับที่คนใช้จริง:
            # อ่าน -> copy -> รัน -> เช็ค expected -> กดทำแล้ว โดยไม่ต้องเลื่อนย้อน
            '<div class="step-foot">'
            f'<button class="done-btn" type="button" data-step="{s["n"]}">'
            '<span class="tick">✓</span><span class="lbl">ทำแล้ว</span></button>'
            '</div>'
            "</section>"
        )

    nav_html = "".join(
        f'<a href="{f[:-3]}.html" class="nav-item{" cur" if f == chapter_file else ""}" '
        f'data-chapter="{f}"><span class="nav-num">{f[:2] if f[0].isdigit() else "✓"}</span>'
        f'<span class="nav-t">{t}</span>'
        f'<span class="nav-p" data-progress-for="{f}" data-total="{totals.get(f, 0)}"></span></a>'
        for f, t in nav
    )

    # แถบกรองตามเครื่อง — โผล่เฉพาะบทที่มีมากกว่าหนึ่งเครื่อง บทที่ทำบน master01 อย่างเดียว
    # ไม่ต้องมีปุ่มให้กดเล่น
    if len(present) > 1:
        btns = ['<button class="mtab on" type="button" data-m="all">ทั้งหมด</button>']
        btns += [
            f'<button class="mtab" type="button" data-m="{k}">{e} {lb}</button>'
            for k, e, lb in MACHINES if k in present
        ]
        tabs_html = '<div class="mtabs" id="mtabs"><span class="mtabs-l">แสดงเฉพาะ:</span>' + "".join(btns) + "</div>"
    else:
        tabs_html = ""

    prev_html = (f'<a class="pn" href="{prev_ch[0][:-3]}.html">← {prev_ch[1]}</a>'
                 if prev_ch else '<span class="pn dim">— เริ่มที่นี่ —</span>')
    next_html = (f'<a class="pn" href="{next_ch[0][:-3]}.html">{next_ch[1]} →</a>'
                 if next_ch else '<span class="pn dim">— บทสุดท้าย —</span>')

    # ใช้ replace ไม่ใช่ .format() — CSS กับ JS เต็มไปด้วยปีกกา format จะพัง
    out = TEMPLATE
    for k, val in (
        ("{title}", title),
        ("{subtitle}", subtitle),
        ("{chapter}", chapter_file),
        ("{total}", str(len(steps))),
        ("{nav}", nav_html),
        ("{intro}", intro),
        ("{steps}", "".join(step_html)),
        ("{prev}", prev_html),
        ("{next}", next_html),
        ("{tabs}", tabs_html),
    ):
        out = out.replace(k, val)
    return out


TEMPLATE = """<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — MyHR Kubernetes</title>
<style>{css}</style>
</head>
<body data-chapter="{chapter}" data-total="{total}">

<aside class="sidebar" id="sidebar">
  <a class="brand" href="index.html">MyHR Kubernetes 1.36</a>
  <nav>{nav}</nav>
</aside>

<div class="wrap">
  <header class="top">
    <button class="burger" id="burger" type="button" aria-label="เมนู">☰</button>
    <div class="top-t">
      <h1>{title}</h1>
      <p class="sub">{subtitle}</p>
    </div>
    <div class="top-p">
      <span id="pcount">0/{total}</span>
      <div class="bar"><i id="pbar"></i></div>
      <button id="reset" class="reset" type="button" title="ล้างสถานะของบทนี้">ล้าง</button>
    </div>
  </header>

  <main>
    <div class="intro">{intro}</div>
    {tabs}
    {steps}
    <div class="pn-row">{prev}{next}</div>
  </main>
</div>

<button class="fab" id="fab" type="button">
  <span class="fab-ico">↓</span><span class="fab-txt">ขั้นที่ต้องทำ</span>
</button>

<div class="toast" id="toast"></div>

<script>{js}</script>
</body>
</html>
"""

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{
  --bg:#f6f7f9; --panel:#fff; --ink:#1c1f24; --dim:#5d6570; --line:#e0e4e9;
  --accent:#2d6ae0; --accent-soft:#eaf1fe;
  --done-bg:#eaf7ee; --done-line:#8fd3a8; --done-ink:#1c6b3c;
  --code-bg:#1e2530; --code-ink:#e6edf3; --warn:#b4530a;
  --radius:10px;
  --font:"Segoe UI","Noto Sans Thai",-apple-system,BlinkMacSystemFont,sans-serif;
  --mono:"Cascadia Mono",Consolas,"Noto Sans Thai Mono",monospace;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:#12151a; --panel:#181c23; --ink:#e5e9ef; --dim:#98a2b0; --line:#272d37;
    --accent:#6ea3ff; --accent-soft:#1b2740;
    --done-bg:#152a1e; --done-line:#2f6b47; --done-ink:#7fd9a3;
    --code-bg:#0d1117; --code-ink:#e6edf3; --warn:#e0913f;
  }
}
html{scroll-behavior:smooth;scroll-padding-top:84px}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--font);
     font-size:15.5px;line-height:1.75}

/* ---------- sidebar ---------- */
.sidebar{position:fixed;inset:0 auto 0 0;width:260px;background:var(--panel);
  border-right:1px solid var(--line);overflow-y:auto;padding:14px 0;z-index:40}
.brand{display:block;padding:8px 18px 14px;font-weight:700;font-size:15px;
  color:var(--ink);text-decoration:none;border-bottom:1px solid var(--line);margin-bottom:8px}
.nav-item{display:flex;align-items:center;gap:9px;padding:7px 18px;text-decoration:none;
  color:var(--dim);font-size:13.5px;border-left:3px solid transparent}
.nav-item:hover{background:var(--accent-soft);color:var(--ink)}
.nav-item.cur{border-left-color:var(--accent);color:var(--ink);font-weight:600;
  background:var(--accent-soft)}
.nav-num{font-family:var(--mono);font-size:11.5px;opacity:.65;min-width:18px}
.nav-t{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.nav-p{font-size:11px;font-family:var(--mono);opacity:.8}
.nav-p.full{color:var(--done-ink);font-weight:700}

/* ---------- layout ---------- */
.wrap{margin-left:260px;min-height:100vh}
.top{position:sticky;top:0;z-index:30;display:flex;align-items:center;gap:16px;
  padding:12px 30px;background:var(--panel);border-bottom:1px solid var(--line)}
.top-t{flex:1;min-width:0}
.top h1{margin:0;font-size:19px;line-height:1.3}
.sub{margin:2px 0 0;font-size:12.5px;color:var(--dim)}
.top-p{display:flex;align-items:center;gap:10px;font-size:12.5px;color:var(--dim);
  font-family:var(--mono);white-space:nowrap}
.bar{width:96px;height:6px;border-radius:3px;background:var(--line);overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .3s}
.reset{border:1px solid var(--line);background:transparent;color:var(--dim);
  border-radius:6px;padding:3px 9px;font-size:11.5px;cursor:pointer;font-family:var(--font)}
.reset:hover{border-color:var(--accent);color:var(--accent)}
.burger{display:none;border:0;background:transparent;color:var(--ink);font-size:20px;cursor:pointer}
main{max-width:920px;padding:24px 30px 120px}

/* ---------- steps ---------- */
.intro{padding:0 2px 6px}
.step{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);
  padding:4px 22px 14px;margin:0 0 18px;transition:background .25s,border-color .25s}
.step.done{background:var(--done-bg);border-color:var(--done-line)}
.step.done .step-body{opacity:.62}
.step-head{display:flex;align-items:flex-start;gap:10px;padding-top:14px}
.step-head h2{flex:1;margin:0;font-size:17.5px;line-height:1.45}
.step.done .step-head h2{color:var(--done-ink)}
/* เครื่องหมายถูกที่หัวข้อ — โผล่เฉพาะตอนทำแล้ว ให้กวาดตาหาได้เร็วตอนเลื่อนผ่าน */
.head-tick{display:none;flex-shrink:0;color:var(--done-ink);font-size:19px;
  font-weight:700;line-height:1.5}
.step.done .head-tick{display:block}

/* ปุ่มอยู่ท้ายส่วน ตรงกับลำดับที่คนใช้จริง */
.step-foot{display:flex;justify-content:flex-end;padding:6px 0 2px;margin-top:14px;
  border-top:1px dashed var(--line)}
.step.done .step-foot{border-top-color:var(--done-line)}
.done-btn{display:inline-flex;align-items:center;gap:7px;cursor:pointer;
  border:1px solid var(--line);background:var(--panel);color:var(--dim);
  border-radius:20px;padding:7px 18px;font-size:13px;font-family:var(--font);
  transition:all .2s;margin-top:10px}
.done-btn:hover{border-color:var(--accent);color:var(--accent)}
.done-btn .tick{opacity:.35;font-weight:700}
.step.done .done-btn{background:var(--done-line);border-color:var(--done-line);color:#08301b}
.step.done .done-btn .tick{opacity:1}

/* ---------- เนื้อหา ---------- */
h3{font-size:15.5px;margin:22px 0 8px}
h4{font-size:14px;margin:18px 0 6px;color:var(--dim)}
p{margin:10px 0}
a{color:var(--accent)}
ul,ol{padding-left:22px;margin:10px 0}
li{margin:4px 0}
blockquote{margin:14px 0;padding:10px 16px;border-left:3px solid var(--warn);
  background:var(--accent-soft);border-radius:0 6px 6px 0;color:var(--ink)}
blockquote p{margin:5px 0}
code{font-family:var(--mono);font-size:.9em;background:var(--accent-soft);
  padding:1.5px 5px;border-radius:4px}
table{border-collapse:collapse;width:100%;margin:14px 0;font-size:14px;display:block;
  overflow-x:auto;white-space:nowrap}
th,td{border:1px solid var(--line);padding:7px 11px;text-align:left;vertical-align:top}
th{background:var(--accent-soft);font-weight:600}
tbody tr:nth-child(even){background:rgba(128,128,128,.045)}
hr{border:0;border-top:1px solid var(--line);margin:22px 0}
img{max-width:100%}

/* ---------- code block ---------- */
.cb{margin:14px 0;border-radius:8px;overflow:hidden;border:1px solid var(--line)}
.cb-bar{display:flex;align-items:center;justify-content:space-between;
  padding:5px 8px 5px 12px;background:rgba(128,128,128,.13);border-top:1px solid var(--line)}
.cb-lang{font-family:var(--mono);font-size:11px;color:var(--dim);text-transform:uppercase;
  letter-spacing:.5px}
.cb-copy{border:1px solid var(--line);background:var(--panel);color:var(--dim);
  border-radius:5px;padding:3px 11px;font-size:11.5px;cursor:pointer;font-family:var(--font);
  transition:all .15s}
.cb-copy:hover{border-color:var(--accent);color:var(--accent)}
.cb-copy.ok{background:var(--done-line);border-color:var(--done-line);color:#08301b}
.cb pre{margin:0;padding:13px 15px;background:var(--code-bg);color:var(--code-ink);
  overflow-x:auto;font-size:13px;line-height:1.65}
.cb pre code{background:none;padding:0;color:inherit;font-size:inherit}

/* ---------- prev/next ---------- */
/* <details> ที่ใช้เก็บทางเลือกที่ยังไม่ต้องทำ */
.step-body details{margin:16px 0;border:1px solid var(--line);border-radius:8px;
  background:rgba(128,128,128,.05)}
.step-body details[open]{background:transparent}
.step-body summary{cursor:pointer;padding:10px 14px;font-size:14px;color:var(--dim);
  user-select:none;list-style:none}
.step-body summary::-webkit-details-marker{display:none}
.step-body summary::before{content:'▸ ';color:var(--accent)}
.step-body details[open] summary::before{content:'▾ '}
.step-body summary:hover{color:var(--accent)}
.step-body details > *:not(summary){margin-left:14px;margin-right:14px}
.step-body details > *:last-child{margin-bottom:14px}

.pn-row{display:flex;justify-content:space-between;gap:14px;margin-top:34px;
  padding-top:18px;border-top:1px solid var(--line)}
.pn{color:var(--accent);text-decoration:none;font-size:14px}
.pn.dim{color:var(--dim);opacity:.6}

/* ---------- ปุ่มลอย ---------- */
.fab{position:fixed;right:24px;bottom:24px;z-index:50;display:inline-flex;align-items:center;
  gap:9px;border:0;border-radius:26px;padding:13px 20px;cursor:pointer;
  background:var(--accent);color:#fff;font-family:var(--font);font-size:14px;font-weight:600;
  box-shadow:0 5px 18px rgba(0,0,0,.28);transition:transform .18s,opacity .18s,background .18s}
.fab:hover{transform:translateY(-2px)}
.fab.alldone{background:var(--done-line);color:#08301b}
.fab-ico{font-size:16px;line-height:1}

.toast{position:fixed;left:50%;bottom:30px;transform:translate(-50%,26px);z-index:60;
  background:var(--ink);color:var(--bg);padding:9px 18px;border-radius:20px;font-size:13px;
  opacity:0;pointer-events:none;transition:all .25s}
.toast.show{opacity:1;transform:translate(-50%,0)}

@media(max-width:900px){
  .sidebar{transform:translateX(-100%);transition:transform .22s}
  .sidebar.open{transform:none}
  .wrap{margin-left:0}
  .burger{display:block}
  main{padding:18px 16px 120px}
  .top{padding:10px 14px}
  .top h1{font-size:16px}
  .top-p .bar{display:none}
  .fab-txt{display:none}
  .fab{padding:15px;border-radius:50%}
}
@media print{
  .sidebar,.fab,.done-btn,.cb-copy,.top-p,.burger{display:none}
  .wrap{margin-left:0}
}

/* ---------- แถบกรองตามเครื่อง ---------- */
/* บทที่ join ทีละเครื่องมีขั้นของ master01 กับของเครื่องปลายทางสลับกัน
   คนที่นั่งอยู่หน้าเครื่องไหนควรเห็นเฉพาะของเครื่องนั้นได้ ไม่ต้องเลื่อนข้าม */
.mtabs{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 20px}
.mtabs-l{color:var(--dim);font-size:13px;margin-right:2px}
.mtab{border:1px solid var(--line);background:var(--panel);color:var(--ink);
  border-radius:999px;padding:6px 14px;font:inherit;font-size:14px;cursor:pointer;transition:all .15s}
.mtab:hover{border-color:var(--accent);color:var(--accent)}
.mtab.on{background:var(--accent);border-color:var(--accent);color:#fff}
.hide-m{display:none !important}
.mnote{color:var(--dim);font-size:13px;margin:-10px 0 18px}

"""

JS = r"""
(function(){
  var CH    = document.body.dataset.chapter;
  var TOTAL = +document.body.dataset.total;
  var KEY   = 'myhr-k8s-progress';

  function load(){ try{ return JSON.parse(localStorage.getItem(KEY)||'{}'); }catch(e){ return {}; } }
  function save(o){ try{ localStorage.setItem(KEY, JSON.stringify(o)); }catch(e){} }
  function mine(){ var a=load(); return (a[CH]||[]); }
  function setMine(list){ var a=load(); a[CH]=list; save(a); }

  var toastEl=document.getElementById('toast'), toastT;
  function toast(msg){
    toastEl.textContent=msg; toastEl.classList.add('show');
    clearTimeout(toastT); toastT=setTimeout(function(){toastEl.classList.remove('show');},1600);
  }

  /* ---------- ทำแล้ว / ยังไม่ทำ ---------- */
  function paint(){
    var done=mine();
    document.querySelectorAll('.step').forEach(function(s){
      var n=+s.dataset.step, is=done.indexOf(n)>=0;
      s.classList.toggle('done', is);
      var b=s.querySelector('.done-btn');
      if(b) b.querySelector('.lbl').textContent = is ? 'ทำแล้ว' : 'ทำแล้ว';
    });
    var n=done.length;
    document.getElementById('pcount').textContent=n+'/'+TOTAL;
    document.getElementById('pbar').style.width=(TOTAL?100*n/TOTAL:0)+'%';
    paintFab();
    paintNav();
  }

  document.querySelectorAll('.done-btn').forEach(function(btn){
    btn.addEventListener('click', function(){
      var n=+btn.dataset.step, done=mine(), i=done.indexOf(n);
      var marking = i<0;
      if(i>=0){ done.splice(i,1); } else { done.push(n); }
      setMine(done); paint();
      // กดทำแล้ว = พาไปขั้นถัดไปให้เลย ไม่ต้องเลื่อนหาเอง
      // ตอนยกเลิกไม่พาไปไหน เพราะคนน่าจะอยากอยู่ตรงนั้นต่อ
      if(marking){
        var nx=nextStep();
        if(nx){ nx.scrollIntoView({behavior:'smooth', block:'start'}); }
        else { toast('ครบทุกขั้นของบทนี้แล้ว'); }
      }
    });
  });

  document.getElementById('reset').addEventListener('click', function(){
    if(!confirm('ล้างสถานะ "ทำแล้ว" ทั้งหมดของบทนี้?')) return;
    setMine([]); paint(); toast('ล้างแล้ว');
  });

  /* ---------- ขั้นที่ต้องทำต่อไป ---------- */
  function nextStep(){
    var done=mine(), out=null;
    document.querySelectorAll('.step').forEach(function(s){
      if(out) return;
      if(done.indexOf(+s.dataset.step)<0) out=s;
    });
    return out;
  }
  function paintFab(){
    var fab=document.getElementById('fab'), s=nextStep();
    if(s){
      fab.classList.remove('alldone');
      fab.querySelector('.fab-ico').textContent='↓';
      fab.querySelector('.fab-txt').textContent='ขั้นที่ต้องทำ';
      fab.title='ไปที่: '+s.querySelector('h2').textContent.trim();
    }else{
      fab.classList.add('alldone');
      fab.querySelector('.fab-ico').textContent='✓';
      fab.querySelector('.fab-txt').textContent='บทนี้เสร็จแล้ว';
      fab.title='ไปบทถัดไป';
    }
  }
  document.getElementById('fab').addEventListener('click', function(){
    var s=nextStep();
    if(s){
      s.scrollIntoView({behavior:'smooth', block:'start'});
      s.animate([{outline:'2px solid var(--accent)'},{outline:'2px solid transparent'}],
                {duration:1100});
    }else{
      var nx=document.querySelector('.pn-row a:last-child');
      if(nx && nx.classList.contains('pn')) nx.click(); else toast('ครบทุกขั้นแล้ว');
    }
  });

  /* ---------- ความคืบหน้าใน sidebar ---------- */
  function paintNav(){
    var all=load();
    document.querySelectorAll('[data-progress-for]').forEach(function(el){
      var f=el.dataset.progressFor, d=(all[f]||[]).length, t=+el.dataset.total||0;
      el.textContent = d ? (d+'/'+t) : '';
      el.classList.toggle('full', t>0 && d>=t);
    });
  }

  /* ---------- ปุ่มคัดลอก ---------- */
  function copyText(t){
    if(navigator.clipboard && window.isSecureContext){
      return navigator.clipboard.writeText(t);
    }
    return new Promise(function(res,rej){
      var ta=document.createElement('textarea');
      ta.value=t; ta.setAttribute('readonly','');
      ta.style.cssText='position:fixed;top:-1000px;opacity:0';
      document.body.appendChild(ta); ta.select();
      try{ document.execCommand('copy') ? res() : rej(); }
      catch(e){ rej(e); }
      finally{ document.body.removeChild(ta); }
    });
  }
  document.querySelectorAll('.cb-copy').forEach(function(btn){
    btn.addEventListener('click', function(){
      var code=btn.closest('.cb').querySelector('code');
      copyText(code.innerText).then(function(){
        btn.textContent='คัดลอกแล้ว'; btn.classList.add('ok');
        setTimeout(function(){ btn.textContent='คัดลอก'; btn.classList.remove('ok'); },1400);
      }).catch(function(){
        // คัดลอกอัตโนมัติไม่ได้ (เบราว์เซอร์บล็อก) — เลือกข้อความให้เลย เหลือแค่กด Ctrl+C
        try{
          var sel=window.getSelection(), rng=document.createRange();
          rng.selectNodeContents(code); sel.removeAllRanges(); sel.addRange(rng);
          toast('เบราว์เซอร์บล็อกการคัดลอก — เลือกให้แล้ว กด Ctrl+C ได้เลย');
        }catch(e){ toast('คัดลอกไม่สำเร็จ — ลากเลือกข้อความแล้วกด Ctrl+C'); }
      });
    });
  });

  /* ---------- กรองตามเครื่อง ---------- */
  /* จำไว้ข้ามบทด้วย เพราะคนหนึ่งรอบมักนั่งอยู่หน้าเครื่องเดียว
     ถ้าบทถัดไปไม่มีเครื่องนั้น จะเด้งกลับเป็น "ทั้งหมด" เองไม่ให้หน้าว่างเปล่า */
  var MKEY='myhr-k8s-machine';
  var tabs=document.getElementById('mtabs');
  if(tabs){
    var avail=[].map.call(tabs.querySelectorAll('.mtab'), function(b){ return b.dataset.m; });
    var applyM=function(m){
      if(avail.indexOf(m)<0) m='all';
      document.body.dataset.mfilter=m;
      tabs.querySelectorAll('.mtab').forEach(function(b){ b.classList.toggle('on', b.dataset.m===m); });
      document.querySelectorAll('.step').forEach(function(sec){
        var list=(sec.dataset.machines||'all').split(' ');
        /* ขั้นที่ไม่ได้ระบุเครื่องเลย = ใช้ได้ทุกเครื่อง ต้องเห็นเสมอ
           ขั้นที่ระบุแล้ว ต้องมีเครื่องที่เลือกอยู่ในรายการถึงจะโชว์ */
        var show = (m==='all') || (list.length===1 && list[0]==='all') || list.indexOf(m)>=0;
        sec.classList.toggle('hide-m', !show);
      });
      document.querySelectorAll('.sub').forEach(function(d){
        var dm=d.dataset.machine||'all';
        d.classList.toggle('hide-m', !(m==='all' || dm===m || dm==='all'));
      });
      try{ localStorage.setItem(MKEY,m); }catch(e){}
      paintFab();
    };
    tabs.addEventListener('click', function(e){
      var b=e.target.closest('.mtab');
      if(b){ applyM(b.dataset.m); }
    });
    var savedM='all';
    try{ savedM=localStorage.getItem(MKEY)||'all'; }catch(e){}
    applyM(savedM);
  }

  /* ---------- เมนูบนจอเล็ก ---------- */
  var burger=document.getElementById('burger'), sb=document.getElementById('sidebar');
  if(burger) burger.addEventListener('click', function(){ sb.classList.toggle('open'); });

  paint();
})();
"""


INDEX_TEMPLATE = """<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>คู่มือ Kubernetes 1.36 — MyHR</title>
<style>{css}
.hero{max-width:940px;margin:0 auto;padding:44px 30px 24px}
.hero h1{font-size:29px;margin:0 0 8px}
.hero p{color:var(--dim);margin:0 0 6px}
.cards{max-width:940px;margin:0 auto;padding:8px 30px 90px;
  display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
.card{display:block;background:var(--panel);border:1px solid var(--line);
  border-radius:var(--radius);padding:15px 17px;text-decoration:none;color:var(--ink);
  transition:transform .16s,border-color .16s}
.card:hover{transform:translateY(-2px);border-color:var(--accent)}
.card.done{background:var(--done-bg);border-color:var(--done-line)}
.card-n{font-family:var(--mono);font-size:11.5px;color:var(--dim)}
.card h3{margin:3px 0 9px;font-size:16px}
.card .bar{width:100%}
.card-p{font-family:var(--mono);font-size:11.5px;color:var(--dim);margin-top:6px;
  display:flex;justify-content:space-between}
.tools{max-width:940px;margin:0 auto;padding:0 30px 60px}
.tools a{margin-right:16px;font-size:13.5px}
</style>
</head>
<body>
<div class="hero">
  <h1>คู่มือ Kubernetes 1.36 — MyHR</h1>
  <p>on-prem HA cluster · Oracle Linux 9.8 · Cilium · kubeadm</p>
  <p style="font-size:13px">ความคืบหน้าเก็บไว้ในเบราว์เซอร์เครื่องนี้เท่านั้น ไม่ได้ส่งไปไหน</p>
</div>
<div class="cards">{cards}</div>
<div class="tools">
  <a href="cilium-envoy-scenarios.html">สถานการณ์ Cilium + Envoy Gateway (ค้นหาได้)</a>
  <a href="../README.md">README ของ repo</a>
  <a href="../k8s-architecture-blueprint.html">Blueprint (เหตุผลเบื้องหลัง)</a>
  <a href="../docs/versions.env">versions.env</a>
</div>
<script>
(function(){
  var KEY='myhr-k8s-progress', all={};
  try{ all=JSON.parse(localStorage.getItem(KEY)||'{}'); }catch(e){}
  document.querySelectorAll('.card').forEach(function(c){
    var f=c.dataset.file, total=+c.dataset.total, d=(all[f]||[]).length;
    c.querySelector('.bar i').style.width=(total?100*d/total:0)+'%';
    c.querySelector('.card-p span').textContent=d+'/'+total;
    if(total && d>=total) c.classList.add('done');
  });
})();
</script>
</body>
</html>
"""


def sources():
    """ทุกหน้าที่จะสร้าง — (ชื่อเสมือน, ชื่อสั้น, path จริง, โฟลเดอร์ต้นทาง)

    ansible/README.md อยู่คนละโฟลเดอร์กับ docs/ จึงต้องบอกโฟลเดอร์ต้นทางด้วย
    ไม่งั้นลิงก์ relative ในไฟล์จะถูกแปลผิด
    """
    out = []
    for f, t in CHAPTERS:
        if (DOCS / f).exists():
            out.append((f, t, DOCS / f, "docs"))
    ans = ROOT / ANSIBLE_SRC
    if ans.exists():
        out.append((ANSIBLE_OUT[:-5] + ".md", "Ansible runbook", ans, "ansible"))
    return out


def main():
    md = make_md()
    OUT.mkdir(exist_ok=True)
    srcs = sources()
    nav = [(f, t) for f, t, _, _ in srcs]

    missing = [f for f, _ in CHAPTERS if not (DOCS / f).exists()]
    if missing:
        print("  ข้าม (ไม่มีไฟล์): " + ", ".join(missing))

    # รอบแรก: นับจำนวนขั้นของทุกหน้าก่อน เพื่อให้ sidebar โชว์ x/y ได้ครบ
    totals = {}
    for fname, _, path, _sd in srcs:
        body = io.open(path, encoding="utf-8").read()
        body = re.sub(r"^#\s+.+\n", "", body, count=1)
        totals[fname] = len(split_steps(md.render(body))[1])

    cards = []
    for i, (fname, short, path, src_dir) in enumerate(srcs):
        raw = io.open(path, encoding="utf-8").read()

        m = re.match(r"#\s+(.+)", raw)
        title = m.group(1).strip() if m else short
        raw = re.sub(r"^#\s+.+\n", "", raw, count=1)

        # บรรทัด quote ต้น ๆ (ผู้อ่าน/รันที่ไหน) เอามาเป็นคำโปรย
        sub = ""
        sm = re.match(r"\s*((?:>\s?.*\n)+)", raw)
        if sm:
            sub = re.sub(r"^>\s?", "", sm.group(1), flags=re.M).strip().replace("\n", " · ")
            sub = re.sub(r"\*\*(.*?)\*\*", r"\1", sub)
            sub = re.sub(r"`(.*?)`", r"\1", sub)
            raw = raw[sm.end():]

        html = rewrite_links(md.render(raw), src_dir)
        intro, steps = split_steps(html)

        prev_ch = nav[i - 1] if i > 0 else None
        next_ch = nav[i + 1] if i + 1 < len(nav) else None

        out = page(fname, title, sub, intro, steps, prev_ch, next_ch, nav, totals)
        out = out.replace("{css}", CSS).replace("{js}", JS)
        dest = OUT / (fname[:-3] + ".html")
        io.open(dest, "w", encoding="utf-8", newline="\n").write(out)
        print(f"  {dest.name:28} {len(steps):2} ขั้นตอน")

        # หน้าที่ไม่ใช่บท (ansible, checklist) ไม่ควรขึ้นว่า "บทที่ •"
        num = ("บทที่ " + fname[:2]) if fname[0].isdigit() else "เครื่องมือ"
        cards.append(
            f'<a class="card" href="{fname[:-3]}.html" data-file="{fname}" data-total="{len(steps)}">'
            f'<div class="card-n">{num}</div><h3>{short}</h3>'
            '<div class="bar"><i></i></div>'
            f'<div class="card-p"><span>0/{len(steps)}</span><span>{len(steps)} ขั้นตอน</span></div></a>'
        )

    idx = INDEX_TEMPLATE.replace("{css}", CSS).replace("{cards}", "".join(cards))
    io.open(OUT / "index.html", "w", encoding="utf-8", newline="\n").write(idx)
    print(f"  {'index.html':28} {len(cards)} หน้า")
    print(f"\nเปิดที่: {OUT / 'index.html'}")

if __name__ == "__main__":
    main()
