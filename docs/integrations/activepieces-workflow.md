# Activepieces — lapisan workflow agentic (profil `workflow`)

OmniRoute merutekan panggilan model. Ia tidak menjadwalkan apa pun, tidak
menyimpan state antar-langkah, dan tidak bereaksi terhadap kejadian dari luar.
Profil `workflow` menambahkan bagian itu: [Activepieces](https://www.activepieces.com)
sebagai orkestrator — trigger (webhook, jadwal, manual), langkah bercabang,
retry, dan riwayat eksekusi — dengan OmniRoute tetap menjadi satu-satunya
jalan keluar ke model.

Image resmi yang ditarik apa adanya; tidak ada yang dibangun dari source, dan
`omniroute/` tidak disentuh sama sekali.

## Kenapa Activepieces

Dipilih setelah membandingkan n8n, Dify, Flowise, LangFlow, Windmill,
Trigger.dev, Temporal, Kestra, Camunda, dan Botpress:

- **Lisensi MIT** (kecuali `packages/ee/` yang punya lisensi enterprise
  terpisah — tidak tersentuh oleh profil ini). n8n memakai *Sustainable Use
  License* yang lebih membatasi modifikasi jangka panjang.
- **Provider "OpenAI Compatible" native** — cukup arahkan ke OmniRoute lewat
  dashboard, nol baris kode. LangFlow masih punya isu terbuka untuk base_url
  generik; sebagian node n8n dilaporkan tidak konsisten.
- **MCP dua arah** — bisa jadi client MCP *dan* mengekspos flow-nya sendiri
  sebagai MCP server.
- **Jejak RAM paling kecil** dari semua kandidat. Dify menuntut minimum 4 GB
  untuk dirinya sendiri, terlalu berat berbagi VPS dengan OmniRoute.

## Postgres dan Redis ada di luar VPS

Ini keputusan yang membuat profil ini hanya menambah **dua** container.
Compose resmi Activepieces menjalankan app + 5 worker + Postgres + Redis;
di sini Postgres diarahkan ke [Neon](https://neon.com) tier gratis, sementara
Redis berjalan lokal sebagai `ap-redis` — lihat di bawah kenapa Redis tidak
bisa ikut dipindah ke tier gratis.

Satu container sudah cukup karena `AP_CONTAINER_TYPE` secara default bernilai
`WORKER_AND_APP` — pemisahan app/worker upstream adalah pola horizontal-scale
yang tidak dibutuhkan di sini.

### Neon

Buat project baru, lalu salin connection string. **Gunakan endpoint
ber-`-pooler`** (PgBouncer bawaan Neon, gratis): Activepieces menjaga koneksi
tetap terbuka, dan endpoint non-pooled membatasi koneksi bersamaan jauh lebih
ketat. Preflight akan memperingatkan kalau lupa.

Catatan: Neon auto-suspend setelah ±5 menit idle, jadi query pertama setelah
menganggur kena cold start beberapa ratus milidetik sampai ~2 detik. Untuk
beban workflow ini tidak masalah.

### Redis — lokal, dan kenapa bukan Upstash

Redis berjalan sebagai container `ap-redis` di profil `workflow`. Biayanya
**4,3 MB RAM** dan ia tidak bisa kehabisan apa pun.

Sebelumnya ia diarahkan ke Upstash, dan itu **menjatuhkan seluruh mesin
workflow selama 14 jam pada 2026-08-29**. Bagian yang paling layak dipelajari:
dokumen ini **sudah menuliskan penyebabnya** sebelum kejadian — bahwa kuota
Upstash dihitung per command dan flow yang sering polling bisa
menghabiskannya — lalu menyimpulkan "pantau dashboard-nya". Kesimpulan itu
salah dua kali: tidak ada yang memantau, dan yang mem-polling bukan flow Anda
melainkan **worker BullMQ**, terus-menerus, ada flow yang jalan atau tidak.

Angkanya: 500.000 request sebulan ≈ **11,5 perintah per menit**. Sebuah
worker antrean yang menganggur pun melewatinya. Jadi batas itu bukan fungsi
dari seberapa banyak Anda memakainya — tercapainya hanya soal waktu.

Saat tercapai, tidak ada yang terlihat rusak: semua flow berhenti, tapi
container tetap `healthy` selama 39 jam karena healthcheck-nya menjawab dari
API, dan API tidak butuh antrean. 454.605 baris error identik mengisi log
sampai 376 MB.

**Aturan yang bisa dibawa ke keputusan berikutnya: offload yang ditagih per
UKURAN, bukan yang ditagih per PANGGILAN.** Neon tetap dipakai justru karena
batasnya penyimpanan — sesuatu yang dikonsumsi mesin workflow dengan lambat
(211 MB dari 500 MB setelah berminggu-minggu). Preflight sekarang memberi
peringatan kalau `AP_REDIS_HOST` bukan `ap-redis`; peringatan, bukan
kegagalan, karena Redis terkelola **berbayar** adalah pilihan yang baik —
yang tidak sanggup memegang antrean adalah tier gratisnya.

## Konfigurasi

```bash
cp activepieces/.env.example activepieces/.env
chmod 600 activepieces/.env
```

Isi rahasianya:

```bash
openssl rand -hex 16   # AP_ENCRYPTION_KEY — harus TEPAT 32 karakter heksadesimal
openssl rand -hex 32   # AP_JWT_SECRET
```

`AP_ENCRYPTION_KEY` panjangnya bersifat kaku, bukan sekadar soal kekuatan
kunci — panjang yang salah membuat Activepieces gagal boot. Preflight
memeriksa ini secara eksplisit.

Lalu:

```bash
./scripts/stax-preflight.sh base workflow
```

## Menjalankan

```bash
docker compose --profile base --profile workflow up -d
```

`--profile base` **wajib ikut**: `activepieces` punya
`depends_on: omniroute-base`, jadi menjalankan `--profile workflow` sendirian
gagal dengan `depends on undefined service`. Perilaku yang sama seperti
`agent-sidecar` dan `proxy`.

Portnya sengaja loopback-only. Untuk setup awal, buat terowongan:

```bash
ssh -L 8080:127.0.0.1:8080 user@IP_VPS
```

lalu buka `http://localhost:8080` dan buat akun admin pertama.

## Menyambungkan ke OmniRoute

Langkah manual satu kali lewat dashboard — sama seperti wiring
`Settings > LLM` pada OpenHands Agent Canvas:

1. **Admin → AI Providers**
2. Pilih provider **OpenAI Compatible**
3. Base URL: `http://omniroute-base:20128/v1` (hostname jaringan Docker,
   bukan `localhost` — trafik tidak keluar dari compose network)
4. API key: buat di dashboard OmniRoute dengan **scope minimal**
   (`models`, `routing`, `health`) — jangan `admin` atau `manage`, aturan yang
   sama seperti pada `agent-sidecar/.env.example`

### Verifikasi

Buat satu flow: trigger manual → aksi **HTTP Request** →
`POST http://omniroute-base:20128/v1/chat/completions` dengan body:

```json
{"model":"opencode/big-pickle","messages":[{"role":"user","content":"ping"}]}
```

`opencode/big-pickle` adalah model gratis tanpa kunci, jadi ini membuktikan
jalur Activepieces → OmniRoute → provider hidup tanpa mengeluarkan biaya.

## Memanggil agent-sidecar dari sebuah flow

Sampai di sini flow bisa memanggil model. Langkah berikutnya membuatnya bisa
memanggil **agent** — smolagents `CodeAgent` yang bisa menulis dan menjalankan
kode Python untuk menyelesaikan tugas, bukan sekadar membalas teks.

`agent-sidecar` sebelumnya hanya bisa dijalankan sebagai proses sekali-pakai
dari shell operator (`docker compose run agent-sidecar ...`), yang tidak bisa
dipanggil mesin workflow. Profil `agent-sidecar-http` menyajikan runner yang
**sama persis** lewat HTTP:

```bash
docker compose --profile base --profile agent-sidecar-http up -d
```

Tidak ada logika agent yang pindah ke sana — `smol_runner.run` dan
`pydantic_runner.run_sync` diimpor dan dipanggil apa adanya. Yang berubah
hanya cara memanggilnya.

Dua endpoint:

| Endpoint | Kegunaan |
|---|---|
| `GET /healthz` | Status + konfigurasi efektif (model, base URL, executor). Tidak pernah memuat nilai kunci apa pun. |
| `POST /run` | `{"task": "...", "runner": "smolagents"}` → `{"result": "...", "runner": "..."}`. `runner` opsional, default `smolagents`, alternatifnya `pydantic-ai`. |

Di dalam flow Activepieces, pakai piece **HTTP Request**:

- Method: `POST`
- URL: `http://agent-sidecar-http:8100/run`
- Body (JSON): `{"task": "{{ langkah_sebelumnya.output }}"}`

Karena agent bisa berpikir beberapa menit, naikkan timeout langkah itu
sewajarnya.

### Peringatan keamanan

Endpoint ini **tidak punya autentikasi**, dan menjalankan kode yang
dihasilkan model. Seluruh alasan mengapa itu bisa diterima adalah karena
port-nya loopback-only dan hanya bisa dijangkau dari dalam compose network —
argumen yang sama dengan `AGENT_SIDECAR_EXECUTOR=local`.

Jangan pernah menaruhnya di belakang `proxy`, dan jangan mengubah
`AGENT_SIDECAR_HTTP_BIND_HOST`. Kalau suatu saat memang harus dijangkau dari
luar, ia butuh autentikasi lebih dulu — dan keputusan executor di
[`vps-hardening.md`](./vps-hardening.md) harus ditinjau ulang pada saat yang
sama, karena premis "tugas datang dari shell operator" tidak lagi berlaku.
Preflight memperingatkan kalau bind host-nya diubah:

```bash
./scripts/stax-preflight.sh base agent-sidecar-http workflow
```

## MCP dua arah

Ini yang menyambungkan semuanya ke Claude Code Anda.

**Arah masuk** — Activepieces sebagai client MCP: daftarkan MCP server
OmniRoute (110 tools) lewat **Admin → MCP** sebagai sumber tool. Perhatikan
bahwa endpoint MCP OmniRoute menuntut kunci ber-scope `manage`/`admin` —
jauh lebih berprivilese daripada kunci `models,routing,health` di atas.
Lakukan hanya kalau memang butuh, dengan sadar konsekuensinya
(lihat [`scalability-system.md`](./scalability-system.md)).

**Arah keluar** — Activepieces sebagai MCP *server*: setiap flow bisa
diekspos sebagai tool MCP. Karena Claude Code Anda sudah diarahkan ke gateway
ini lewat `ANTHROPIC_BASE_URL`, hasilnya adalah Claude Code bisa **memicu
automation multi-langkah** sebagai tool call — bukan sekadar menerima jawaban
chat. Satu flow bisa memanggil model, memanggil agent-sidecar, menyentuh
layanan luar, lalu mengembalikan hasilnya.

Keduanya adalah konfigurasi lewat dashboard, bukan perubahan kode.

## Mengekspos ke publik

Hanya diperlukan kalau butuh trigger dari layanan luar (Slack, GitHub).
Tambahkan site block kedua di [`caddy/Caddyfile`](../../caddy/Caddyfile):

```
flows.arject.co {
	reverse_proxy activepieces:80
}
```

lalu ubah `AP_FRONTEND_URL` di `activepieces/.env` menjadi
`https://flows.arject.co` — URL webhook dibangun dari nilai ini, jadi selama
masih `localhost` tidak ada layanan luar yang bisa memicunya. Preflight
memperingatkan kalau nilainya masih localhost.

Jangan membuka port 8080 langsung di firewall: endpoint webhook Activepieces
memang tidak terautentikasi (itu sifatnya), jadi TLS di depannya bukan
opsional.

## Keputusan keamanan

- **`AP_EXECUTION_MODE=UNSANDBOXED`** — kode flow berjalan langsung di dalam
  container ini. Itu setelan yang tepat selama hanya operator yang menulis
  flow, penalaran yang sama dengan `AGENT_SIDECAR_EXECUTOR=local`. `SANDBOXED`
  baru relevan kalau orang lain boleh menjalankan kode yang tidak dipercaya.
- **Tanpa `no-new-privileges`** — sengaja, mengikuti preseden
  `openhands-agent-canvas`: image pihak ketiga yang memasang paket piece lewat
  npm saat runtime, dan belum ada bukti bahwa run yang diperketat tetap sehat
  saat melakukannya. Pengerasan yang belum teruji dan rusak saat runtime lebih
  buruk daripada tidak sama sekali.
- `activepieces/.env` ikut dimask (`/dev/null`) di mount OpenHands Canvas,
  karena berisi kredensial Neon.

## Menaikkan versi

Pin saat ini `0.88.3` — versi yang dipasangkan upstream di
`docker-compose.yml` mereka sendiri, bukan tag terbaru, karena pasangan itulah
yang mereka terbitkan sebagai satu set yang teruji. Untuk menaikkan, cek
`docker-compose.yml` di repo Activepieces, ganti tag di
[`docker-compose.yml`](../../docker-compose.yml), lalu jalankan ulang flow
verifikasi di atas.

## Belum diverifikasi

Semuanya sudah terbukti live di VPS, bukan sekadar divalidasi statis: boot,
migrasi skema ke Neon, eksekusi flow, dan pemulihan setelah Redis dipindah ke
lokal (container sehat dalam 35 detik, nol error Upstash, flow uji SUCCEEDED
dalam 34,9 detik).
