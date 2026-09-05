# Observability — melihat apa yang terjadi di gateway (profil `tracing`)

Dokumen ini runbook. Alasan di balik pemilihan Langfuse Cloud alih-alih
self-host ada di [`langfuse.md`](./langfuse.md) yang berbahasa Inggris.

## Kenapa dokumen ini ada

Pertanyaan yang perlu dijawab sebuah gateway free-tier bukan "berapa biayanya",
melainkan **kunci mana yang hampir habis, provider mana yang sedang tumbang,
dan siapa yang memakai apa**. Tanpa itu, kolam API gratis akan berhenti bekerja
diam-diam dan Anda baru sadar saat semuanya sudah mati.

Sebagian besar jawabannya **sudah ada di OmniRoute** dan tidak perlu dibangun.
Bagian yang benar-benar ditambahkan repo ini hanya satu: sebuah kolektor OTel
yang menempelkan header autentikasi yang tidak bisa dikirim eksportir bawaan.

## Yang sudah ada tanpa dikonfigurasi

OmniRoute mencatat **setiap panggilan** ke tabel `call_logs`
(`omniroute/src/lib/usage/callLogs.ts`), tanpa syarat dan tanpa saklar. Kolomnya
persis yang dibutuhkan: `provider`, `model`, `status`, `duration`, `tokens_in`,
`tokens_out`, `api_key_name`, dan `error_summary`.

Halaman dashboard yang sudah siap pakai:

| Halaman | Isinya |
|---|---|
| `/dashboard/usage` | ringkasan pemakaian |
| `/dashboard/logs` | riwayat panggilan, dengan tab activity/console/proxy/timeline |
| `/dashboard/analytics` | agregat per provider dan model |
| `/dashboard/provider-stats` | statistik per provider |

Lewat API — perhatikan bahwa semuanya bersarang di bawah `/api/usage/`, bukan
`/api/usage` saja:

```
GET /api/usage/call-logs      riwayat panggilan
GET /api/usage/analytics      agregat, mendukung range=1d|7d|30d|...
GET /api/provider-metrics     success rate per provider
GET /api/keys/{id}/usage-limits  sisa kuota per kunci
```

### Autentikasi untuk klien mesin

Endpoint di atas menolak kunci `/v1` biasa — mereka memakai
`requireManagementAuth`. Untuk flow atau skrip, **jangan** pakai kunci ber-scope
`manage`: kunci itu juga bisa **mencetak kunci admin baru**, sehingga satu
kebocoran berarti kendali penuh atas gateway.

Pakai token ber-scope `read`:

```bash
curl -X POST http://localhost:20128/api/cli/connect \
  -H 'Content-Type: application/json' \
  -d '{"password":"<INITIAL_PASSWORD>","scope":"read","name":"nama-klien"}'
```

Token yang keluar berprefix `oma_`, tidak kedaluwarsa, dan dikirim sebagai
`Authorization: Bearer <token>`. Diverifikasi pada 2026-08-29 bahwa ia bisa
membaca `/api/usage/*` (200) dan **ditolak 403** saat mencoba `POST /api/keys`
maupun menonaktifkan plugin.

## Memisahkan trafik per konsumen

Buat kunci `/v1` terpisah untuk tiap pemakai — Claude Code, Activepieces,
agent-sidecar — semuanya scope minimal `models,routing,health`. Kolom
`call_logs.api_key_name` lalu memisahkan trafiknya tanpa konfigurasi tambahan:

```
04:51:40 | claude-code   | opencode | big-pickle
02:09:30 | activepieces  | opencode | big-pickle
```

Ini cara termurah menjawab "siapa memakai apa", dan gratis.

## Retensi

Default `CALL_LOG_RETENTION_DAYS` adalah **7 hari** — terlalu pendek untuk
melihat pola kuota mingguan. Deployment ini menyetelnya ke `30` di
`omniroute/.env`, bersama `OMNIROUTE_LOG_REQUEST_SHAPE=1` yang mencatat bentuk
tiap request.

**Jangan menyetel `APP_LOG_LEVEL=debug`.** Nilai itu diam-diam mengaktifkan
`CHAT_DEBUG_FILE`, yang menyimpan body request dan response **mentah tanpa
pemotongan** — bahaya ruang disk sekaligus privasi.
`OMNIROUTE_LOG_REQUEST_SHAPE=1` memberi hampir semua manfaatnya dengan biaya
jauh lebih kecil.

## Profil `tracing` — trace ke Langfuse

### Prasyarat

Akun gratis di [cloud.langfuse.com](https://cloud.langfuse.com), lalu
**Settings → API Keys** untuk mendapat sepasang `pk-lf-...` dan `sk-lf-...`.

### Konfigurasi

Ketiga variabel wajib, tapi **tidak semuanya di file yang sama** — dan salah
menaruhnya adalah kegagalan senyap: kolektor menyala sempurna dan tidak pernah
menerima apa pun.

Di `.env` **root** (dibaca Compose, dipakai service `otel-collector`):

```bash
LANGFUSE_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
LANGFUSE_OTLP_AUTH="Basic $(printf '%s:%s' 'pk-lf-...' 'sk-lf-...' | base64 -w0)"
```

Di **`omniroute/.env`** (dibaca gateway lewat `env_file: .env` miliknya sendiri):

```bash
OMNIROUTE_OTEL_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=omniroute
```

Yang terakhir itu **tidak boleh** diletakkan di `.env` root. Dulu memang bisa,
lewat override `omniroute-base:` di `docker-compose.yml` root — dan override itu
melanggar spesifikasi Compose (file yang meng-`include` tidak boleh menimpa
resource yang di-include). Compose v5.3+ menerimanya dan VPS memakai v5.5,
jadi ia bekerja di kedua tempat yang diperiksa manusia, sementara **setiap job
CI yang memakai Docker merah** dengan `services.omniroute-base conflicts with
imported resource`. Override-nya sudah dihapus.

Konsekuensi kedua dari penghapusan itu: mount `omniroute/plugins` ikut hilang,
sehingga plugin gateway yang terpasang **tidak lagi bertahan** melewati
`up --force-recreate`. Tidak ada yang rusak karenanya — satu-satunya plugin yang
pernah dipasang adalah plugin Langfuse, yang memang tidak bisa bekerja (lihat
bagian di bawah), dan jalur trace yang nyata adalah eksportir OTLP inti.

Dua jebakan yang sudah dijaga preflight:

- **Endpoint tidak boleh menyertakan `/v1/traces`.** Eksportir menambahkannya
  sendiri, sehingga URL yang sudah memuatnya menghasilkan jalur ganda dan 404
  yang terbaca seperti masalah autentikasi.
- **`LANGFUSE_OTLP_AUTH` harus diawali `Basic `.** Kolektor meneruskannya apa
  adanya dan tidak punya fungsi base64 sendiri.

### Menjalankan

```bash
./scripts/stax-preflight.sh base proxy tracing
docker compose --profile base --profile tracing up -d
```

### Verifikasi

```bash
curl -u "pk-lf-...:sk-lf-..." "https://cloud.langfuse.com/api/public/traces?limit=5"
```

Trace bernama `chat <provider>/<model>` berarti berhasil. Ingestion Langfuse
asinkron — beri jeda sekitar 40 detik sebelum menyimpulkan gagal.

## Kenapa bukan plugin Langfuse bawaan

OmniRoute menyertakan plugin Langfuse di `omniroute/examples/plugins/langfuse/`,
dan itu tampak jalur yang paling jelas. Plugin itu **tidak bisa bekerja**.

Ia menandai request lewat `ctx.metadata.__langfuseSampled` di `onRequest` lalu
membacanya di `onResponse`. Tapi `pluginOnRequest.ts:38` dan
`pluginOnResponse.ts` **masing-masing membuat objek `metadata: {}` baru**,
sehingga penanda itu tidak pernah terlihat dan penjaganya memulangkan lebih awal
pada setiap request.

Memperbaiki bug itu membuat plugin mengirim dengan benar bila dipanggil
langsung — sebuah harness menghasilkan trace `omniroute:auto/best-coding` yang
nyata di Langfuse. Tapi gateway tetap tidak memanggil hook-nya, dan
`runOnResponse(...).catch(() => {})` menelan penyebabnya. Menelusuri lebih jauh
berarti mengedit `omniroute/`, yang dilarang di repo ini.

Eksportir OTLP bawaan justru pilihan lebih baik: ia ada di **inti gateway**,
bukan runtime plugin, dan sudah memancarkan GenAI semantic conventions. Satu
kekurangannya hanya header autentikasi — dan itulah satu-satunya tugas kolektor.

Ini juga menutup titik buta yang tidak bisa dilihat Caddy: panggilan
Activepieces → OmniRoute lewat jaringan Docker internal, tidak pernah menyentuh
reverse proxy.

## Alert

Dua flow Activepieces bekerja berpasangan.

**`gateway_alerts`** menerima webhook. Trigger-nya memverifikasi HMAC-SHA256
dengan header `x-webhook-signature`, prefix `sha256=`, encoding hex — cocok
persis dengan yang dikirim OmniRoute. Kiriman tanpa tanda tangan sah didiamkan
tanpa menjalankan flow. Satu langkah kode menormalkan payload menjadi
`{event, at, apiKey, provider, model, reason}`.

Daftarkan webhook-nya di OmniRoute lewat `POST /api/webhooks` dengan `secret`
yang sama, lalu uji dengan `POST /api/webhooks/{id}/test`.

**`gateway_monitor`** berjalan tiap 15 menit, membaca `call-logs` memakai token
`read`, dan menilai sendiri. Ia mengirim alert ke `gateway_alerts` — jalur yang
sama, bukan jalur kedua — bila rasio error melewati **30%** dengan **minimal 3
panggilan** dalam jendela.

Tiga keputusan di dalamnya layak diketahui:

- **Baris `active:true` dibuang.** Respons `call-logs` menyisipkan baris
  in-flight dari memori yang **melewati filter SQL sepenuhnya** dan membawa
  `status:0`. Tanpa dibuang, tiap request yang sedang berjalan terhitung gagal.
- **Jendela waktu disaring di sisi klien.** Route `call-logs` tidak pernah
  membaca `since`/`until` walau lapisan query mendukungnya.
- **Jendela kosong bukan kegagalan.** `total === 0` tidak pernah memicu alert —
  sunyi semalaman adalah kondisi normal, bukan gangguan.
- **Tidak ada panggilan AI di jalur alert.** Alert harus tetap hidup justru
  ketika jalur model yang bermasalah.

Ambangnya memakai minimal 3 panggilan karena tanpa itu, satu kegagalan tunggal
dari dua panggilan sudah 50% dan akan berisik — provider free-tier memang
naik-turun.

## Status

**Terbukti live pada 2026-08-29:**

- `call_logs` merekam setiap panggilan, terpisah per `api_key_name`
- Token `read` bisa membaca `/api/usage/*` dan ditolak 403 saat mencoba menulis
- Trace mendarat di Langfuse Cloud lewat kolektor, termasuk panggilan yang
  berasal dari flow Activepieces
- `gateway_alerts` menerima `test.ping` dari OmniRoute dengan HMAC tervalidasi
- `gateway_monitor` mendeteksi rasio error 80% dari 5 panggilan, menunjuk
  `felo-web` sebagai penyebab (4 dari 4 gagal) sementara `opencode` bersih, dan
  alertnya mendarat dengan `alertStatus: 200`
- Jendela tanpa trafik menghasilkan `breach: false`

**Belum terbukti:**

- `quota.exceeded` — call site-nya ada di `omniroute/src/lib/quota/enforce.ts`,
  tapi butuh cap kuota terpasang, dan model gratis berbiaya $0 sehingga cap
  berbasis USD kemungkinan tidak pernah tersentuh.
- `request.failed` — **tidak berbunyi untuk kegagalan biasa.** Ia hanya dikirim
  dari `omniroute/open-sse/services/combo.ts`, yaitu jalur combo routing.
  Diuji langsung: panggilan yang gagal dengan 400 dan 403 tidak menghasilkan
  webhook apa pun. Inilah alasan `gateway_monitor` ada.

## Catatan operasional

- `gateway_monitor` berjalan 96 kali sehari, dan tiap eksekusi menulis riwayat
  ke Postgres Neon yang jatah gratisnya 0,5 GB. Diukur pada 2026-08-29: satu
  eksekusi ≈ 6,7 kB, jadi sekitar **19 MB per bulan** — dan Activepieces sudah
  membatasinya lewat `AP_EXECUTION_DATA_RETENTION_DAYS` yang **default 30
  hari**, sehingga ukurannya mencapai kondisi tunak, bukan tumbuh terus.

  Yang justru memakan ruang adalah `piece_metadata` — **198 MB dari 211 MB**
  yang terpakai, yakni katalog 761 piece bawaan Activepieces. Statis, tidak
  tumbuh, dan tidak ada hubungannya dengan flow Anda. Kalau suatu saat Neon
  mendekati penuh, di situlah tempat melihat lebih dulu.
- Token `read` tidak kedaluwarsa, jadi tidak ada rotasi paksa. Kalau dicabut,
  monitor akan diam-diam mengembalikan `ok: false` dengan `monitorError` —
  bukan `breach`, sehingga tidak salah membunyikan alarm.
- Ke depan, penilaian ambang statis di `gateway_monitor` bisa digantikan model
  lokal yang berjalan di VPS. Strukturnya sudah menyiapkan itu: langkah kode
  hanya menghasilkan angka, dan keputusannya terpisah.

## Agent runs tidak ada di Langfuse, dan itu disengaja

Kalau Anda mencari jejak `agent-sidecar` di sini, tidak akan ketemu. Servis itu
tidak terinstrumentasi OTel sama sekali — tidak ada `opentelemetry` di
`pyproject.toml`-nya, dan tidak ada satu pun span yang dikirim ke collector.

Yang ada sebagai gantinya: **satu baris JSON per run** di `/audit/runs.jsonl`,
dibaca dengan `./scripts/agent-report.sh`. Isinya cap waktu, pemanggil (`http`
atau `mcp`), model yang diminta, model yang benar-benar menjawab, jumlah token,
tool yang dipegang, durasi, `step_errors`, dan `degraded`.

Alasannya bukan ideologis, tapi urutan: jurnal itu nol dependensi baru, bekerja
tanpa profil `tracing` menyala, dan langsung menjawab pertanyaan yang memang
ditanyakan — berapa biayanya, seberapa sering terdegradasi, tool mana yang
dipakai. Instrumentasi OTel penuh tetap masuk akal kalau nanti dibutuhkan
korelasi antar-servis; jurnal ini tidak menghalanginya.

Catatan yang membuat perbedaannya nyata: **collector-nya hidup** (`Up 4 days`
saat diperiksa 2026-09-05), jadi ketiadaan jejak agen bukan gejala tracing yang
rusak. Tidak ada yang mengirim.
