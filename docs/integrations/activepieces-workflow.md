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

Ini keputusan yang membuat profil ini hanya menambah **satu** container.
Compose resmi Activepieces menjalankan app + 5 worker + Postgres + Redis;
di sini Postgres diarahkan ke [Neon](https://neon.com) dan Redis ke
[Upstash](https://upstash.com), keduanya tier gratis tanpa kartu kredit.

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

### Upstash

Buat database Redis, salin host, port, dan password. Upstash berbicara
protokol RESP standar sehingga dipakai langsung tanpa SDK khusus.

Kuota gratisnya dihitung **per command**, bukan per volume data. Flow yang
sangat sering polling bisa menghabiskannya lebih cepat dari dugaan — pantau
lewat dashboard Upstash kalau mulai banyak flow terjadwal.

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
  karena berisi kredensial Neon dan Upstash.

## Menaikkan versi

Pin saat ini `0.88.3` — versi yang dipasangkan upstream di
`docker-compose.yml` mereka sendiri, bukan tag terbaru, karena pasangan itulah
yang mereka terbitkan sebagai satu set yang teruji. Untuk menaikkan, cek
`docker-compose.yml` di repo Activepieces, ganti tag di
[`docker-compose.yml`](../../docker-compose.yml), lalu jalankan ulang flow
verifikasi di atas.

## Belum diverifikasi

Konfigurasi ini divalidasi secara statis (`docker compose config` terhadap
model gabungan, dan setiap jalur `check_workflow()` di preflight diuji satu
per satu). Yang **belum** dibuktikan karena butuh VPS hidup dengan akun Neon
dan Upstash sungguhan: boot pertama, migrasi skema Activepieces ke Neon, dan
langkah manual AI Provider di atas.
