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
| Ukuran image | **~400 MB** — `graphifyy[mcp]` 250 MB, terpasang 26 detik |
| Durasi ekstraksi | **265 detik**, 10.272 file, 2 worker |
| Memori build | **butuh 4 GB.** Di 3 GB kernel membunuhnya: `oom-kill:constraint=CONSTRAINT_MEMCG`, anon-rss 3,0 GB |
| Hasil | `graph.json` **82 MB** — **58.382 node, 163.257 edge** |
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
| Rahasia repo ikut terindeks | Rahasia dengan antarmuka query, di balik satu kunci statis | graphify menghormati `.gitignore`, **dan** compose me-mask tiap `.env` ke `/dev/null` — termasuk `.env` root, yang daftar mask openhands justru melewatkannya. CI menanam canary di path gitignored dan memastikan ia tidak muncul di grafik |
| Kunci bocor lewat argv | `ps` menampilkannya | Kunci datang dari `GRAPHIFY_API_KEY`, bukan flag `--api-key` |

## Status jujur

- **Terbukti live di VPS**: image dibangun, ekstraksi selesai, grafik ditulis.
- **Terbukti benar**: `graphify explain "CloudAgentBase"` mengembalikan keempat
  subclass nyata dengan edge `[inherits]` dan file:line yang tepat —
  `CursorCloudAgent` (cursor.ts:L45), `CodexCloudAgent` (codex.ts:L10),
  `DevinAgent` (devin.ts:L10), `JulesAgent` (jules.ts:L186). Jawaban benarnya
  sudah tercatat sebelumnya, jadi jawaban salah tidak akan ambigu.
- **Diuji di CI**: preflight menolak kunci kosong, build menghasilkan >40.000
  node, `BUILD_INFO` mencatat commit yang benar, canary tidak bocor, serve
  menolak start tanpa grafik, dan permintaan MCP tanpa kunci ditolak.
- **Belum diuji**: systemd timer belum dipasang, dan wiring MCP dari Claude Code
  di laptop lewat SSH tunnel belum pernah dijalankan ujung ke ujung.
