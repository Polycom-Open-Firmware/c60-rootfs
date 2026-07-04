#!/usr/bin/env python3
import fcntl
import json
import os
import select
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EVENT_DIR = "/dev/input"
EVENT_STRUCT = struct.Struct("llHHI")

EV_TYPES = {
    0x00: "EV_SYN",
    0x01: "EV_KEY",
    0x02: "EV_REL",
    0x03: "EV_ABS",
    0x04: "EV_MSC",
    0x11: "EV_LED",
    0x12: "EV_SND",
    0x14: "EV_REP",
    0x15: "EV_FF",
    0x16: "EV_PWR",
    0x17: "EV_FF_STATUS",
}

KEY_NAMES = {
    28: "KEY_ENTER",
    57: "KEY_SPACE",
    102: "KEY_HOME",
    103: "KEY_UP",
    105: "KEY_LEFT",
    106: "KEY_RIGHT",
    108: "KEY_DOWN",
    114: "KEY_VOLUMEDOWN",
    115: "KEY_VOLUMEUP",
    116: "KEY_POWER",
    139: "KEY_MENU",
    158: "KEY_BACK",
    172: "KEY_HOMEPAGE",
    217: "KEY_SEARCH",
    330: "BTN_TOUCH",
    331: "BTN_STYLUS",
    332: "BTN_STYLUS2",
    333: "BTN_TOOL_DOUBLETAP",
    334: "BTN_TOOL_TRIPLETAP",
    335: "BTN_TOOL_QUADTAP",
    336: "BTN_TOOL_QUINTTAP",
}

ABS_NAMES = {
    0x00: "ABS_X",
    0x01: "ABS_Y",
    0x18: "ABS_PRESSURE",
    0x2f: "ABS_MT_SLOT",
    0x30: "ABS_MT_TOUCH_MAJOR",
    0x31: "ABS_MT_TOUCH_MINOR",
    0x32: "ABS_MT_WIDTH_MAJOR",
    0x35: "ABS_MT_POSITION_X",
    0x36: "ABS_MT_POSITION_Y",
    0x39: "ABS_MT_TRACKING_ID",
    0x3a: "ABS_MT_PRESSURE",
}

state_lock = threading.Lock()
state = {
    "started": time.time(),
    "devices": {},
    "events": [],
}


def parse_proc_input_devices():
    devices = {}
    try:
        text = open("/proc/bus/input/devices", "r", encoding="utf-8", errors="replace").read()
    except OSError:
        return devices

    for block in text.strip().split("\n\n"):
        name = "unknown"
        handlers = []
        phys = ""
        for line in block.splitlines():
            if line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("P: Phys="):
                phys = line.split("=", 1)[1].strip()
            elif line.startswith("H: Handlers="):
                handlers = line.split("=", 1)[1].split()
        for h in handlers:
            if h.startswith("event"):
                devices[h] = {"name": name, "phys": phys, "handler": h}
    return devices


def key_name(code):
    return KEY_NAMES.get(code, f"KEY_{code}")


def abs_name(code):
    return ABS_NAMES.get(code, f"ABS_{code}")


def ensure_device(handler, meta):
    if handler not in state["devices"]:
        state["devices"][handler] = {
            "handler": handler,
            "name": meta.get("name", handler),
            "phys": meta.get("phys", ""),
            "path": os.path.join(EVENT_DIR, handler),
            "last_seen": None,
            "keys": {},
            "abs": {},
            "last": None,
        }
    else:
        state["devices"][handler]["name"] = meta.get("name", state["devices"][handler]["name"])
        state["devices"][handler]["phys"] = meta.get("phys", state["devices"][handler]["phys"])


def record_event(handler, ev_type, code, value):
    now = time.time()
    with state_lock:
        dev = state["devices"].setdefault(handler, {
            "handler": handler,
            "name": handler,
            "phys": "",
            "path": os.path.join(EVENT_DIR, handler),
            "last_seen": None,
            "keys": {},
            "abs": {},
            "last": None,
        })
        dev["last_seen"] = now
        if ev_type == 0x01:
            dev["keys"][str(code)] = {
                "code": code,
                "name": key_name(code),
                "value": value,
                "pressed": value != 0,
                "updated": now,
            }
            label = key_name(code)
        elif ev_type == 0x03:
            dev["abs"][str(code)] = {
                "code": code,
                "name": abs_name(code),
                "value": value,
                "updated": now,
            }
            label = abs_name(code)
        else:
            label = f"{EV_TYPES.get(ev_type, f'EV_{ev_type}')}:{code}"

        dev["last"] = {"type": EV_TYPES.get(ev_type, f"EV_{ev_type}"), "code": code, "label": label, "value": value, "time": now}
        state["events"].append({"device": handler, "device_name": dev["name"], "label": label, "value": value, "time": now})
        del state["events"][:-80]


def input_thread():
    fds = {}
    last_scan = 0
    while True:
        now = time.time()
        if now - last_scan > 2:
            meta = parse_proc_input_devices()
            with state_lock:
                for handler, info in meta.items():
                    ensure_device(handler, info)
            for handler in sorted(meta):
                path = os.path.join(EVENT_DIR, handler)
                if handler in fds:
                    continue
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                    fcntl.fcntl(fd, fcntl.F_SETFL, os.O_NONBLOCK)
                    fds[handler] = fd
                except OSError:
                    pass
            last_scan = now

        if not fds:
            time.sleep(0.25)
            continue

        try:
            readable, _, _ = select.select(list(fds.values()), [], [], 0.5)
        except OSError:
            readable = []
        reverse = {fd: handler for handler, fd in fds.items()}
        for fd in readable:
            handler = reverse.get(fd)
            if not handler:
                continue
            while True:
                try:
                    data = os.read(fd, EVENT_STRUCT.size)
                except BlockingIOError:
                    break
                except OSError:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    fds.pop(handler, None)
                    break
                if len(data) != EVENT_STRUCT.size:
                    break
                _, _, ev_type, code, value = EVENT_STRUCT.unpack(data)
                if ev_type != 0x00:
                    record_event(handler, ev_type, code, value)


HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>C60 Input Status</title>
<style>
html,body{margin:0;min-height:100%;background:#080b10;color:#e5edf7;font:18px/1.35 system-ui,sans-serif;}
body{padding:18px;box-sizing:border-box;}
h1{margin:0 0 10px;font-size:34px;letter-spacing:.03em}
.top{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:14px}.pill{background:#152033;border:1px solid #293852;border-radius:999px;padding:8px 12px}.ok{color:#55f08b}.warn{color:#ffcc66}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:14px}.dev{background:#0f1724;border:1px solid #2a3650;border-radius:16px;padding:14px;box-shadow:0 10px 30px #0008}.dev h2{margin:0 0 8px;font-size:22px}.muted{color:#91a0b7}.keys,.abs{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px;margin-top:10px}.item{border:1px solid #2d3954;border-radius:12px;padding:8px;background:#121b2a}.pressed{background:#17351f;border-color:#43d56e;color:#baffc9}.changed{outline:2px solid #facc15}.events{font-family:ui-monospace,monospace;font-size:14px;background:#05070b;border:1px solid #263047;border-radius:12px;padding:10px;height:220px;overflow:hidden}.event{white-space:nowrap}.big{font-size:56px;font-weight:800;color:#223048;text-align:center;margin:18px 0}.small{font-size:13px}.touchdot{position:fixed;width:38px;height:38px;border:3px solid #fff;border-radius:50%;pointer-events:none;transform:translate(-50%,-50%);box-shadow:0 0 20px #fff8}.footer{margin-top:14px;color:#6f7f99;font-size:13px}
</style>
</head>
<body>
<h1>C60 Input Status</h1>
<div class="top"><div class="pill">devices: <b id="ndev">0</b></div><div class="pill">pressed keys: <b id="nkeys">0</b></div><div class="pill">last update: <b id="age">never</b></div></div>
<div class="big" id="banner">POKE BUTTONS / TOUCH</div>
<div class="grid" id="devices"></div>
<h2>Recent Events</h2><div class="events" id="events"></div>
<div class="footer">Served by c60-input-status-web.py reading /dev/input/event*. Browser pointer events also draw rings.</div>
<script>
const devicesEl=document.getElementById('devices'), eventsEl=document.getElementById('events');
const ndev=document.getElementById('ndev'), nkeys=document.getElementById('nkeys'), age=document.getElementById('age'), banner=document.getElementById('banner');
function ago(t){if(!t)return'never'; const s=Math.max(0,Date.now()/1000-t); return s<1?'now':s.toFixed(1)+'s ago'}
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function item(x, cls=''){return `<div class="item ${cls}"><b>${esc(x.name)}</b><br><span class="muted">${x.value}</span></div>`}
async function tick(){
  const r=await fetch('/state.json',{cache:'no-store'}); const s=await r.json();
  const devs=Object.values(s.devices).sort((a,b)=>a.handler.localeCompare(b.handler));
  ndev.textContent=devs.length; let pressed=0,last=0;
  devicesEl.innerHTML=devs.map(d=>{ const keys=Object.values(d.keys||{}).sort((a,b)=>a.code-b.code); const abs=Object.values(d.abs||{}).sort((a,b)=>a.code-b.code); pressed+=keys.filter(k=>k.pressed).length; last=Math.max(last,d.last_seen||0); return `<section class="dev"><h2>${esc(d.handler)} <span class="muted">${esc(d.name)}</span></h2><div class="small muted">${esc(d.path)} ${esc(d.phys||'')}</div><div class="small">last: ${d.last?esc(d.last.label)+' = '+esc(d.last.value):'none'}</div><div class="keys">${keys.map(k=>item(k,k.pressed?'pressed':'')).join('')||'<div class="muted">no key/button events yet</div>'}</div><div class="abs">${abs.map(a=>item(a)).join('')}</div></section>`; }).join('');
  nkeys.textContent=pressed; age.textContent=ago(last); banner.textContent=pressed?`${pressed} PRESSED`:'POKE BUTTONS / TOUCH'; banner.className=pressed?'big ok':'big';
  eventsEl.innerHTML=(s.events||[]).slice().reverse().map(e=>`<div class="event"><span class="muted">${new Date(e.time*1000).toLocaleTimeString()}</span> ${esc(e.device)} ${esc(e.device_name)}: <b>${esc(e.label)}</b> = ${esc(e.value)}</div>`).join('');
}
setInterval(tick,200); tick();
addEventListener('pointerdown',e=>{const d=document.createElement('div');d.className='touchdot';d.style.left=e.clientX+'px';d.style.top=e.clientY+'px';document.body.appendChild(d);setTimeout(()=>d.remove(),700)});
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_body(self, body, content_type):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_body(HTML, "text/html; charset=utf-8")
            return
        if self.path == "/state.json":
            with state_lock:
                body = json.dumps(state, sort_keys=True)
            self.send_body(body, "application/json")
            return
        self.send_error(404)


def main():
    threading.Thread(target=input_thread, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()


if __name__ == "__main__":
    main()
