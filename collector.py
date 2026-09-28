#!/usr/bin/env python3
# Oracle VM collector — streamed over SSH (`ssh host python3 - <tier>`) and
# never written to the VM. Read-only: it only inspects /proc, systemd, dnf's
# cache and the instance metadata service. It never signals, restarts or
# edits anything, and it treats the Hermes agent as look-but-don't-touch.
#
#   fast  → counters and live state (every few seconds)
#   slow  → inventory, security, updates, logs (every few minutes)
import json
import os
import re
import subprocess
import sys
import time

TIER = sys.argv[1] if len(sys.argv) > 1 else "fast"
CLK_TCK = os.sysconf("SC_CLK_TCK")
HERMES_RE = re.compile(r"(\.hermes/|hermes_cli|hermes-agent|/hermes(\s|$))")
KEY_SERVICES = ["sshd", "firewalld", "tailscaled", "chronyd", "crond", "rsyslog",
                "auditd", "NetworkManager", "oracle-cloud-agent", "pmlogger"]


def run(cmd, timeout=6, sudo=False):
    if sudo:
        cmd = ["sudo", "-n"] + cmd
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception:
        return -1, ""


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""


def cpu_counters():
    out = {}
    for line in read("/proc/stat").splitlines():
        if line.startswith("cpu"):
            parts = line.split()
            out[parts[0]] = [int(x) for x in parts[1:9]]
        elif line.startswith("ctxt "):
            out["ctxt"] = int(line.split()[1])
        elif line.startswith("procs_running"):
            out["running"] = int(line.split()[1])
    return out


def meminfo():
    m = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        try:
            m[k] = int(v.split()[0])
        except Exception:
            pass
    keys = ["MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached", "SReclaimable",
            "Shmem", "SwapTotal", "SwapFree", "Dirty", "Committed_AS"]
    return {k: m.get(k, 0) for k in keys}


def net():
    ifaces = []
    for line in read("/proc/net/dev").splitlines()[2:]:
        name, _, rest = line.partition(":")
        name = name.strip()
        if name == "lo":
            continue
        f = rest.split()
        ifaces.append({"name": name, "rx": int(f[0]), "rxp": int(f[1]), "rxe": int(f[2]),
                       "tx": int(f[8]), "txp": int(f[9]), "txe": int(f[10])})
    return ifaces


def diskstats():
    rd = wr = ios = 0
    for line in read("/proc/diskstats").splitlines():
        f = line.split()
        if len(f) < 14:
            continue
        name = f[2]
        # Whole disks only: partitions and device-mapper would double count.
        if re.fullmatch(r"(sd[a-z]+|vd[a-z]+|nvme\d+n\d+|xvd[a-z]+)", name):
            rd += int(f[5])
            wr += int(f[9])
            ios += int(f[12])
    return {"readSectors": rd, "writeSectors": wr, "ioMs": ios}


def pressure():
    out = {}
    for kind in ("cpu", "memory", "io"):
        txt = read("/proc/pressure/" + kind)
        m = re.search(r"some avg10=([\d.]+) avg60=([\d.]+) avg300=([\d.]+)", txt)
        if m:
            out[kind] = [float(m.group(1)), float(m.group(2)), float(m.group(3))]
    return out


def filesystems():
    rc, out = run(["df", "-kPT", "-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs",
                   "-x", "overlay", "-x", "squashfs"])
    fs = []
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) < 7:
            continue
        fs.append({"dev": f[0], "type": f[1], "size": int(f[2]), "used": int(f[3]),
                   "avail": int(f[4]), "mount": f[6]})
    return fs


def processes():
    # Raw per-PID CPU ticks straight from /proc; the panel diffs consecutive
    # samples for a live CPU%, which `ps` (lifetime average) can't give.
    import pwd
    names = {}
    page_kb = os.sysconf("SC_PAGE_SIZE") // 1024
    boot_ticks = float(read("/proc/uptime").split()[0] or 0) * CLK_TCK
    me = os.getpid()
    procs = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        pid = int(d)
        if pid == me:
            continue
        stat = read("/proc/%d/stat" % pid)
        if not stat:
            continue
        rp = stat.rfind(")")
        comm = stat[stat.find("(") + 1:rp]
        f = stat[rp + 2:].split()
        if len(f) < 22:
            continue
        try:
            uid = os.stat("/proc/%d" % pid).st_uid
        except Exception:
            continue
        if uid not in names:
            try:
                names[uid] = pwd.getpwuid(uid).pw_name
            except Exception:
                names[uid] = str(uid)
        args = read("/proc/%d/cmdline" % pid).replace("\0", " ").strip() or "[" + comm + "]"
        if f[3] == "0" and args.startswith("["):  # skip idle kernel threads
            if int(f[11]) + int(f[12]) == 0:
                continue
        procs.append({"pid": pid, "user": names[uid], "state": f[0],
                      "ticks": int(f[11]) + int(f[12]), "rss": int(f[21]) * page_kb,
                      "etime": int(max(0, boot_ticks - int(f[19])) / CLK_TCK),
                      "threads": int(f[17]), "comm": comm, "args": args[:110],
                      "hermes": bool(HERMES_RE.search(args))})
    return procs


def service_states(units, user=False):
    cmd = ["systemctl"] + (["--user"] if user else []) + ["is-active"] + units
    rc, out = run(cmd)
    states = out.split()
    return {u: (states[i] if i < len(states) else "unknown") for i, u in enumerate(units)}


def failed_units():
    rc, out = run(["systemctl", "--failed", "--plain", "--no-legend", "--no-pager"])
    return [l.split()[0] for l in out.splitlines() if l.strip()]


def hermes_info(procs):
    hp = [p for p in procs if p["hermes"]]
    rc, units = run(["systemctl", "--user", "list-units", "--all", "--plain", "--no-legend",
                     "--no-pager", "*hermes*"])
    svc = []
    for l in units.splitlines():
        f = l.split(None, 4)
        if len(f) >= 4:
            svc.append({"unit": f[0], "load": f[1], "active": f[2], "sub": f[3],
                        "desc": f[4] if len(f) > 4 else ""})
    # Headline the long-running gateway service, not a short-lived worker scope.
    svc.sort(key=lambda u: (not u["unit"].startswith("hermes-gateway"), not u["unit"].endswith(".service"), u["unit"]))
    since = ""
    if svc:
        rc, o = run(["systemctl", "--user", "show", svc[0]["unit"], "-p",
                     "ActiveEnterTimestamp", "-p", "NRestarts", "-p", "MemoryCurrent"])
        since = o.strip()
    return {"procs": hp, "units": svc, "unitInfo": since}


def socket_summary():
    est = listen = tw = 0
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in read(path).splitlines()[1:]:
            f = line.split()
            if len(f) < 4:
                continue
            st = f[3]
            if st == "01":
                est += 1
            elif st == "0A":
                listen += 1
            elif st == "06":
                tw += 1
    return {"established": est, "listen": listen, "timeWait": tw}


def fast():
    procs = processes()
    load = read("/proc/loadavg").split()
    rc, who = run(["who"])
    return {
        "tier": "fast",
        "t": time.time(),
        "hostname": os.uname().nodename,
        "uptime": float(read("/proc/uptime").split()[0] or 0),
        "ncpu": os.cpu_count(),
        "cpu": cpu_counters(),
        "load": [float(x) for x in load[:3]] if load else [0, 0, 0],
        "tasks": load[3] if len(load) > 3 else "",
        "mem": meminfo(),
        "net": net(),
        "disk": diskstats(),
        "psi": pressure(),
        "fs": filesystems(),
        "clkTck": CLK_TCK,
        "procs": procs,
        "sessions": [l.split()[0] + " " + (l.split()[-1] if "(" in l else "") for l in who.splitlines()],
        "services": service_states(KEY_SERVICES),
        "failed": failed_units(),
        "sockets": socket_summary(),
        "hermes": hermes_info(procs),
    }


# ---------------------------------------------------------------- slow tier

def imds():
    rc, out = run(["curl", "-s", "-m", "3", "-H", "Authorization: Bearer Oracle",
                   "http://169.254.169.254/opc/v2/instance/"])
    try:
        d = json.loads(out)
    except Exception:
        return {}
    sc = d.get("shapeConfig") or {}
    return {"displayName": d.get("displayName"), "shape": d.get("shape"),
            "region": d.get("canonicalRegionName") or d.get("region"),
            "ad": d.get("availabilityDomain"), "faultDomain": d.get("faultDomain"),
            "ocpus": sc.get("ocpus"), "memoryGB": sc.get("memoryInGBs"),
            "bandwidthGbps": sc.get("networkingBandwidthInGbps"),
            "created": d.get("timeCreated"), "id": d.get("id"),
            "state": d.get("state")}


def os_info():
    rel = {}
    for line in read("/etc/os-release").splitlines():
        k, _, v = line.partition("=")
        rel[k] = v.strip('"')
    u = os.uname()
    return {"pretty": rel.get("PRETTY_NAME", ""), "kernel": u.release, "arch": u.machine}


def updates():
    rc, out = run(["dnf", "-q", "check-update", "--cacheonly"], timeout=25, sudo=True)
    pkgs = []
    for l in out.splitlines():
        f = l.split()
        if len(f) == 3 and "." in f[0] and not l.startswith(" "):
            pkgs.append({"name": f[0], "version": f[1], "repo": f[2]})
    rc2, sec = run(["dnf", "-q", "updateinfo", "list", "--security", "--cacheonly"], timeout=25, sudo=True)
    sec_lines = [l for l in sec.splitlines() if l.strip()]
    rc3, _ = run(["needs-restarting", "-r"], timeout=20, sudo=True)
    return {"count": len(pkgs), "packages": pkgs[:40], "security": len(sec_lines),
            "rebootRequired": rc3 == 1, "checked": rc in (0, 100)}


def listening():
    rc, out = run(["ss", "-Htulnp"], sudo=True)
    if rc != 0:
        rc, out = run(["ss", "-Htuln"])
    rows = []
    seen = set()
    for l in out.splitlines():
        f = l.split()
        if len(f) < 5:
            continue
        local = f[4]
        addr, _, port = local.rpartition(":")
        m = re.search(r'users:\(\("([^"]+)"', l)
        key = (f[0], port, m.group(1) if m else "")
        if key in seen:
            continue
        seen.add(key)
        rows.append({"proto": f[0], "addr": addr.strip("[]"), "port": port,
                     "proc": m.group(1) if m else ""})
    rows.sort(key=lambda r: (int(r["port"]) if r["port"].isdigit() else 99999))
    return rows


def firewall():
    rc, zone = run(["firewall-cmd", "--get-default-zone"], sudo=True)
    rc1, svc = run(["firewall-cmd", "--list-services"], sudo=True)
    rc2, ports = run(["firewall-cmd", "--list-ports"], sudo=True)
    rc3, state = run(["firewall-cmd", "--state"], sudo=True)
    return {"zone": zone.strip(), "services": svc.split(), "ports": ports.split(),
            "running": state.strip() == "running"}


def tailscale():
    rc, out = run(["tailscale", "status", "--json"])
    try:
        d = json.loads(out)
    except Exception:
        return {}
    peers = d.get("Peer") or {}
    plist = []
    for p in peers.values():
        plist.append({"name": (p.get("HostName") or p.get("DNSName") or "?"),
                      "os": p.get("OS", ""), "online": bool(p.get("Online")),
                      "ip": (p.get("TailscaleIPs") or [""])[0]})
    plist.sort(key=lambda p: (not p["online"], p["name"].lower()))
    s = d.get("Self") or {}
    return {"state": d.get("BackendState"), "ips": s.get("TailscaleIPs") or [],
            "dns": (s.get("DNSName") or "").rstrip("."), "peers": plist[:20],
            "online": sum(1 for p in plist if p["online"])}


def ssh_security():
    rc, out = run(["journalctl", "-u", "sshd", "--since", "24 hours ago", "--no-pager",
                   "-o", "short-iso"], timeout=15, sudo=True)
    failed = 0
    ips = {}
    users = {}
    accepted = []
    for l in out.splitlines():
        m = re.search(r"(Failed password|Invalid user|authentication failure|Connection closed by invalid user)", l)
        if m:
            failed += 1
            ipm = re.search(r"from ([0-9a-fA-F:.]+)", l) or re.search(r"rhost=([0-9a-fA-F:.]+)", l)
            if ipm:
                ips[ipm.group(1)] = ips.get(ipm.group(1), 0) + 1
            um = re.search(r"[Ii]nvalid user (\S+)", l)
            if um:
                users[um.group(1)] = users.get(um.group(1), 0) + 1
            continue
        am = re.search(r"^(\S+) .*Accepted (\S+) for (\S+) from (\S+)", l)
        if am:
            accepted.append({"time": am.group(1), "method": am.group(2),
                             "user": am.group(3), "ip": am.group(4)})
    top = sorted(ips.items(), key=lambda kv: kv[1], reverse=True)[:6]
    topu = sorted(users.items(), key=lambda kv: kv[1], reverse=True)[:6]
    return {"available": rc == 0, "failed24h": failed, "uniqueIps": len(ips),
            "topIps": [{"ip": k, "count": v} for k, v in top],
            "topUsers": [{"user": k, "count": v} for k, v in topu],
            "accepted": accepted[-6:][::-1]}


def journal_errors():
    rc, out = run(["journalctl", "-p", "err", "-b", "-n", "25", "--no-pager", "-o",
                   "short-iso"], timeout=10, sudo=True)
    rows = []
    for l in out.splitlines():
        if l.startswith("--"):
            continue
        m = re.match(r"(\S+) (\S+) ([^:\[]+)(?:\[\d+\])?: (.*)", l)
        if m:
            rows.append({"time": m.group(1), "unit": m.group(3), "msg": m.group(4)[:220]})
    return rows[::-1]


def chrony():
    rc, out = run(["chronyc", "tracking"])
    d = {}
    for l in out.splitlines():
        k, _, v = l.partition(":")
        d[k.strip()] = v.strip()
    return {"ref": d.get("Reference ID", ""), "offset": d.get("System time", ""),
            "leap": d.get("Leap status", ""), "stratum": d.get("Stratum", "")}


def sshd_config():
    rc, out = run(["sshd", "-T"], sudo=True)
    want = {"passwordauthentication", "permitrootlogin", "pubkeyauthentication",
            "maxauthtries", "port", "x11forwarding"}
    cfg = {}
    for l in out.splitlines():
        k, _, v = l.partition(" ")
        if k in want:
            cfg[k] = v
    return cfg


def slow():
    rc, se = run(["getenforce"])
    rc, boot = run(["uptime", "-s"])
    return {
        "tier": "slow",
        "t": time.time(),
        "os": os_info(),
        "oci": imds(),
        "bootTime": boot.strip(),
        "selinux": se.strip(),
        "listening": listening(),
        "firewall": firewall(),
        "tailscale": tailscale(),
        "ssh": ssh_security(),
        "journal": journal_errors(),
        "chrony": chrony(),
        "sshd": sshd_config(),
        "sudo": run(["true"], sudo=True)[0] == 0,
    }


def pkg():
    # dnf is the one heavy check (seconds of CPU on a 1-OCPU shape), so it
    # runs on its own, rarer tier.
    rc, lastdnf = run(["bash", "-c", "stat -c %Y /var/cache/dnf/*.solv 2>/dev/null | sort -n | tail -1"])
    return {"tier": "pkg", "t": time.time(), "updates": updates(),
            "metadataAge": int(lastdnf.strip() or 0)}


try:
    data = {"slow": slow, "pkg": pkg}.get(TIER, fast)()
except Exception as e:  # never leave the panel with half a JSON document
    data = {"tier": TIER, "error": str(e)}
sys.stdout.write(json.dumps(data, separators=(",", ":")))
