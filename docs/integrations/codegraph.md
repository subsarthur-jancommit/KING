# Code graph — satu peta kode, dipakai bersama (profil `codegraph`)

## Kenapa ada

Repo ini menyimpan 220 ribu baris kode OmniRoute yang di-vendor. Menjawab
"fungsi X dipakai di mana" dengan grep berarti membakar token Claude untuk
pekerjaan yang sebenarnya deterministik.

[graphify](https://github.com/Graphify-Labs/graphify) menjawabnya dari AST
tree-sitter lokal — **tanpa panggilan model, tanpa API key, tanpa vector store**.
Sebelum ini ia dipasang per mesin, dan hasilnya: ia tidak ada di mesin mana pun,
sementara `CLAUDE.md` tetap menyuruh setiap agent memakainya. Profil ini
memindahkannya ke satu tempat yang nyata.

**Tidak ada kode yang ditulis untuk ini.** graphify sudah punya server MCP
Streamable HTTP bawaan; yang ditambahkan repo ini hanya sebuah Dockerfile
sepuluh baris dan dua service compose.

## Yang diukur, bukan ditebak

Semua angka di bawah dari VPS ini (2 vCPU, 7,8 GB, tanpa GPU):

| | |
|---|---|
| Ukuran image | **496 MB** (base `python:3.11-slim` 189 MB) — `graphifyy[mcp]` terpasang 26 detik |
| Durasi ekstraksi | **265 detik**, 10.272 file, 2 worker |
| Memori build | **butuh 4 GB.** Di 3 GB kernel membunuhnya: `oom-kill:constraint=CONSTRAINT_MEMCG`, anon-rss 3,0 GB |
| Hasil | `graph.json` **82 MB** — **58.390 node, 163.274 edge** (`graph_stats` lewat MCP melaporkan 59.301 node; selisihnya node referensi yang tidak ditulis extractor) |
| Memori serve | **392 MB anon**, 717 MB termasuk page cache → `mem_limit: 768m` |

Angka node itu sekaligus menyelesaikan kontradiksi di
[`scalability-system.md`](./scalability-system.md), yang melaporkan 58.205 di
satu paragraf dan 129.621 di paragraf lain: **58 ribu adalah angka
`--code-only`**, dan itulah yang dihasilkan container ini.

Catatan: 157 file `.sql` tidak terindeks karena `tree_sitter_sql` tidak
terpasang. Menambah extra `[sql]` akan memperbaikinya, dengan biaya ukuran
image — belum dianggap sepadan.

## Menjalankan

```bash
echo "GRAPHIFY_API_KEY=$(openssl rand -hex 24)" >> .env
./scripts/stax-preflight.sh codegraph
docker compose --profile codegraph run --rm codegraph-build
docker compose --profile codegraph up -d codegraph-serve
```

Kunci itu **satu-satunya** kontrol di depan indeks seluruh basis kode, karena
itu preflight memblokir kalau ia kosong. `--api-key ""` bukan berarti "tolak
semuanya" — server jadi tidak punya kunci untuk diwajibkan.

Port di-publish loopback saja. Activepieces menjangkaunya lewat jaringan Docker
di `http://codegraph-serve:8130/mcp`, tanpa exposure apa pun.

## Memakainya dari Claude Code di laptop

```bash
ssh -i ~/.ssh/king-gcp -L 8130:127.0.0.1:8130 subsa@34.101.62.94
```

lalu daftarkan MCP server-nya dengan kunci **dari environment**, jangan literal
— `.mcp.json` ter-commit:

```bash
claude mcp add --transport http codegraph http://127.0.0.1:8130/mcp \
  --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

Ini yang membuat pembagian kerja jadi nyata: Claude di laptop bertanya ke peta
yang sama dengan yang dipakai flow free-tier di VPS, dan tidak perlu menjelajah
file untuk menjawab pertanyaan struktural.

## Kesegaran

`graph.json` yang basi lebih buruk daripada tidak ada grafik: ia menjawab dengan
percaya diri tentang kode yang sudah pindah, dan `CLAUDE.md` menyuruh agent
memilihnya di atas grep. Karena itu setiap build mencatat commit asalnya:

```bash
./scripts/codegraph-refresh.sh --check   # exit 1 kalau tertinggal dari HEAD
./scripts/codegraph-refresh.sh           # bangun ulang, verifikasi, restart serve
```

Jadwalnya milik **systemd timer**, bukan compose. Unitnya ada di repo:

```bash
mkdir -p ~/.config/systemd/user
cp codegraph/codegraph-refresh.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now codegraph-refresh.timer
sudo loginctl enable-linger "$USER"   # tanpa ini, timer hanya jalan saat login
```

Unit *user*, bukan system: akun operator sudah ada di grup docker (seluruh stack
dijalankan tanpa sudo), jadi menjalankannya sebagai root hanya menambah hak
tanpa alasan.

Timer memberi tiga hal yang compose tidak bisa: `Persistent=true` (menyusul
setelah reboot yang cepat atau lambat pasti dialami VPS), jitter lewat
`RandomizedDelaySec`, dan tempat menggantung `flock`. Menjadwal di dalam compose
berarti entrypoint sleep-loop — mengubah one-shot empat menit jadi proses yang
menahan plafon 4 GB seharian.

Dijadwalkan 03:00 karena rebuild me-restart `codegraph-serve`, dan itu memutus
sesi MCP yang sedang terbuka di laptop.

Skrip itu juga **menurunkan model Ollama yang sedang residen** sebelum
membangun. Build 3,5 GB dan model 2,5 GB tidak muat bersama di mesin ini, dan
kalau dibiarkan kernel yang memilih korban, ia memilih berdasarkan RSS — yang di
host ini berarti Activepieces atau gateway, bukan proses build.

`graphify.serve` memuat grafik ke memori saat start, jadi menulis ulang
`graph.json` tidak mengubah apa pun sampai prosesnya di-restart. Skrip
mengurusnya.

## Kegagalan senyap yang dijaga

Deployment ini sudah tiga kali digigit kegagalan yang menyisakan container
berstatus *healthy*. Yang berikut ini kelas yang sama:

| Kegagalan | Kalau tidak dijaga | Yang menjaga |
|---|---|---|
| Serve jalan tanpa grafik | Setiap query balas kosong, dan agent menyimpulkan kodenya tidak ada | Command menolak start kalau `graph.json` hilang/kosong; `restart: on-failure:3` supaya penolakan itu tidak jadi crashloop yang membanjiri disk |
| Healthcheck hijau padahal grafik tidak termuat | Port terbuka ≠ grafik siap | Healthcheck melakukan **MCP `initialize` sungguhan dengan kunci** — sekaligus membuktikan grafik termuat, transport jalan, dan auth ditegakkan |
| Named volume salah kepemilikan | Tulis gagal, mungkin tanpa error — persis cara `omniroute/data` kehilangan semua API key | `/out` dibuat dan di-`chown` **di Dockerfile**, sebelum apa pun di-mount ke sana |
| Grafik menyusut karena ekstraksi rusak | Grafik cacat menggantikan yang baik | `codegraph-refresh.sh` menolak restart kalau node di bawah 40.000, dan **grafik lama tetap disajikan** |
| Rahasia repo ikut terindeks | Rahasia dengan antarmuka query, di balik satu kunci statis | Sumber di-mount `:ro`, dan batas bacanya `.gitignore`, yang dihormati graphify. Mask `/dev/null` gaya openhands **sengaja tidak dipakai**: Docker harus membuat mountpoint dulu sebelum bisa menimpanya, dan di dalam mount `:ro` itu gagal total untuk `.env` yang kebetulan tidak ada di host — sudah dicoba, dan itu menggagalkan build pertama di VPS. CI menanam canary di path gitignored dan memastikan ia tidak muncul di grafik |
| Kunci bocor lewat argv | `ps` menampilkannya | Kunci datang dari `GRAPHIFY_API_KEY`, bukan flag `--api-key` |

## Batasan yang diketahui

`query_graph` mencocokkan node awal secara fuzzy dari pertanyaan bahasa alami,
dan pencocokan itu bisa meleset: pertanyaan "which classes inherit from
CloudAgentBase" ikut mengambil `rtl-logical-classes.test.tsx` dan
`inheritTrustedLocalRateLimitResponse()` sebagai titik awal, hanya karena
namanya memuat "inherit". Jawabannya tetap benar, tapi anggarannya terbuang.

Untuk pertanyaan yang simpulnya sudah Anda tahu, `get_neighbors` dan `get_node`
jauh lebih tajam. Sepuluh tool yang tersedia: `query_graph`, `get_node`,
`get_neighbors`, `shortest_path`, `god_nodes`, `graph_stats`, `get_community`,
`get_pr_impact`, `list_prs`, `triage_prs`.

## Status jujur

**Terbukti live di VPS, ujung ke ujung (2026-08-29):**

- Image dibangun (496 MB), ekstraksi selesai, grafik ditulis, `BUILD_INFO`
  mencatat commit yang benar.
- `codegraph-serve` healthy dalam 24 detik, memakai **407 MiB dari plafon
  768 MiB**.
- **Auth ditegakkan**: `initialize` tanpa kunci dibalas **401**; dengan kunci
  dibalas handshake MCP valid dari `graphify 0.9.51`.
- **Jawabannya benar lewat MCP**, bukan hanya lewat CLI:
  `get_neighbors label=CloudAgentBase relation_filter=inherits` mengembalikan
  tepat empat subclass dengan file:line yang tepat — `CodexCloudAgent`
  (codex.ts:L10), `CursorCloudAgent` (cursor.ts:L45), `DevinAgent`
  (devin.ts:L10), `JulesAgent` (jules.ts:L186). Jawaban benarnya sudah tercatat
  sebelum grafik ini dibangun, jadi jawaban salah tidak akan ambigu.
- **Deteksi basi bekerja**: setelah repo maju satu commit, `--check` melaporkan
  `Graph is STALE: built from 09c1c41c, tree is at 5954ae32` dan exit 1.

**Diuji di CI**: preflight menolak kunci kosong dan menerima kunci nyata, build
menghasilkan lebih dari 40.000 node, `BUILD_INFO` memuat SHA commit yang benar,
canary di path gitignored tidak bocor ke grafik, serve menolak start tanpa
grafik, dan permintaan MCP tanpa kunci ditolak.

**Terbukti sejak 2026-09-04, dan tanpa tunnel.** codegraph disajikan lewat
Caddy di `https://gateway.arject.co/king-codegraph/mcp`:

```bash
claude mcp add --transport http codegraph   https://gateway.arject.co/king-codegraph/mcp   --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

Diuji ujung ke ujung lewat internet publik: tanpa token → 401, token salah →
401, token benar → `initialize` menjawab `{"name":"graphify","version":"0.9.51"}`.

Autentikasinya diperiksa **sebelum** rute ditambahkan, bukan sesudah: default
`GRAPHIFY_API_KEY` di compose adalah string kosong, jadi kunci yang tidak
terisi akan menerbitkan seluruh peta repo ini ke internet terbuka. Konsekuensinya
dicatat di `king-system.md` §11 — kunci itu kini satu-satunya batas yang tersisa.
