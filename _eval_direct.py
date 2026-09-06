import re, time, httpx

# Kasus dan prompt diambil dari skripnya sendiri, bukan disalin — kalau
# local-router.sh berubah, ini ikut berubah, dan tidak ada dua definisi yang
# bisa berselisih diam-diam.
src = open("/tmp/lr.sh", encoding="utf-8").read()
cases_src = re.search(r"^CASES = \[.*?^\]", src, re.S | re.M).group(0)
system_src = re.search(r'^SYSTEM = """.*?"""', src, re.S | re.M).group(0)
ns = {}
exec(cases_src, ns)
exec(system_src, ns)
CASES, SYSTEM = ns["CASES"], ns["SYSTEM"]
VALID = {"LOCAL", "FREE", "PAID", "WEB"}

BASE = "http://ollama:11434/v1/chat/completions"
MODELS = ["qwen2.5:1.5b-instruct-q4_K_M", "qwen3:1.7b", "qwen3:4b"]

print("  %d kasus, langsung ke Ollama (tanpa gateway, jadi tanpa reroute)\n" % len(CASES))
for model in MODELS:
    ok = offlabel = 0
    lat = []
    misses = []
    for task, want in CASES:
        t0 = time.time()
        try:
            r = httpx.post(BASE, timeout=900.0, json={
                "model": model, "temperature": 0, "max_tokens": 2048,
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": "Task: " + task}]})
            m = (r.json().get("choices") or [{}])[0].get("message") or {}
            raw = (m.get("content") or m.get("reasoning") or "").strip().upper()
        except Exception:
            raw = ""
        lat.append(time.time() - t0)
        got = ""
        for w in raw.replace("\n", " ").split():
            if w.strip(".,:!*#") in VALID:
                got = w.strip(".,:!*#")
                break
        if not got:
            offlabel += 1
            misses.append("%s -> (tak terbaca)" % task[:34])
        elif got == want:
            ok += 1
        else:
            misses.append("%s -> %s (mau %s)" % (task[:34], got, want))
    acc = round(100 * ok / len(CASES))
    print("  %-30s akurasi %2d/%d = %3d%%  | tak terbaca %d | rerata %5.1fs | total %5.1fs"
          % (model, ok, len(CASES), acc, offlabel, sum(lat) / len(lat), sum(lat)))
    for miss in misses[:4]:
        print("      salah: %s" % miss)
    print()
