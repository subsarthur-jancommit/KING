# Panduan Deploy ke VPS — Langkah demi Langkah

Panduan operasional untuk menjalankan OmniRoute + STAX di VPS sungguhan,
dari server kosong sampai semua profile yang Anda perlukan hidup dan
terverifikasi. Untuk alasan *kenapa* setiap default dikonfigurasi seperti
ini (bind loopback, masking secret, dua trade-off docker.sock/executor),
baca [vps-hardening.md](./vps-hardening.md) — dokumen ini fokus ke *apa
yang harus dijalankan, urut*.

## Peta port — referensi cepat

| Service | Port | Bind default | Kenapa |
|---|---|---|---|
| OmniRoute dashboard/API | 20128 | `0.0.0.0` (publik) | Auth sendiri: password + JWT |
| OmniRoute API internal | 20129 | `0.0.0.0` (publik) | Bagian dari OmniRoute |
| OmniRoute Live WS | 20132 | `0.0.0.0` (publik) | Bagian dari OmniRoute |
| OmniRoute Redis | 6379 | `127.0.0.1` | Tanpa auth — sengaja loopback |
| OpenHands Agent Canvas | 8000 | `127.0.0.1` | Tidak ada auth default yang terdokumentasi |
| Langfuse web | 3000 | `127.0.0.1` | Ada login, tapi juga self-service signup |
| Langfuse worker | 3030 | `127.0.0.1` | Internal, tidak perlu diakses manual |
| MinIO S3 API | 9090 | `127.0.0.1` | Hanya dijaga `MINIO_ROOT_PASSWORD` |
| MinIO console | 9091 | `127.0.0.1` | Hanya dijaga `MINIO_ROOT_PASSWORD` |
| ClickHouse | 8123 / 9000 | `127.0.0.1` | Hanya dijaga `CLICKHOUSE_PASSWORD` |
| Postgres (Langfuse) | 5432 | `127.0.0.1` | Hanya dijaga `POSTGRES_PASSWORD` |
| Langfuse Redis | 16379 | `127.0.0.1` | Hanya dijaga `REDIS_AUTH` |

Hanya OmniRoute sendiri yang publik by default, karena dia satu-satunya yang
punya auth sendiri. Semua yang lain sengaja loopback-only — akses lewat SSH
tunnel (Langkah 8), bukan dengan membuka port di firewall.

## Pilih stack Anda

| Stack | Profile | Isinya |
|---|---|---|
| Minimal | `base` | OmniRoute saja — gateway LLM |
| + agent | `base agent-sidecar` | + runtime agent Python (smolagents/pydantic-ai) |
| + observability | `base agent-sidecar observability` | + tracing Langfuse (6 container tambahan: Postgres, ClickHouse, MinIO, Redis, 2 service Langfuse — cukup berat) |
| Penuh | `base agent-sidecar observability openhands` | + panel kontrol OpenHands Agent Canvas |

Mulai dari `base` saja, pastikan stabil, baru tambah profile lain. Setiap
profile di Langkah 7 independen — lewati yang tidak Anda perlukan.

## Prasyarat

- VPS Ubuntu 22.04/24.04 LTS atau Debian 12, akses root/sudo.
- **RAM**: minimal 4GB untuk `base` saja. Build OmniRoute dari source (Next.js
  + native deps `onnxruntime-node`/`@huggingface/transformers`) adalah
  langkah paling lapar memori di seluruh proses ini — bahkan runner CI
  dengan 15GB RAM pernah gagal build karena preemption/tekanan memori yang
  intermiten. 8GB+ direkomendasikan kalau mau tambah `observability` +
  `openhands` sekaligus.
- Disk kosong minimal 20GB (image Docker + build cache + data Postgres/ClickHouse
  kalau pakai `observability`).
- Repo ini sudah punya `scripts/stax-preflight.sh` dan
  `scripts/ci-build-omniroute-base.sh` yang dipakai di langkah-langkah bawah.

---

## Langkah 1 — Setup dasar VPS

```bash
sudo apt update && sudo apt upgrade -y
```

**Install Docker** (cara resmi):

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker
docker compose version   # pastikan v2.x+
```

**Swap** — sangat disarankan kalau RAM di bawah 8GB, karena build OmniRoute
butuh headroom nyata:

```bash
free -h   # cek yang sudah ada
# kalau belum ada / kurang dari ~4G:
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h   # verifikasi
```

Repo ini juga punya `scripts/ci-build-omniroute-base.sh` yang menyediakan
swap otomatis ala-CI setiap kali dipanggil (lihat isinya untuk detail) —
tapi itu didesain untuk runner CI yang sekali pakai. Untuk VPS yang hidup
terus-menerus, swap permanen lewat `/etc/fstab` di atas lebih tepat.

**Firewall dasar (ufw)**:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
```

Tidak perlu membuka port lain secara manual — lihat tabel port di atas:
semua service selain OmniRoute sendiri memang tidak terpasang ke interface
publik. Kalau mau OmniRoute bisa diakses langsung dari browser tanpa
tunnel:

```bash
sudo ufw allow 20128/tcp
```

Kalau lebih suka tidak membuka port sama sekali (lebih aman), skip baris di
atas dan pakai SSH tunnel di Langkah 8 — juga untuk OmniRoute.

---

## Langkah 2 — Clone repo

```bash
git clone https://github.com/subsarthur-jancommit/KING.git
cd KING
git checkout claude/ecc-install-validation-33xduy   # atau branch/tag produksi Anda
```

Kalau repo private, siapkan deploy key atau token GitHub sebelum `clone`.

---

## Langkah 3 — Isi semua secret

### 3.1 OmniRoute (wajib)

```bash
cp omniroute/.env.example omniroute/.env
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -base64 48)|" omniroute/.env
sed -i "s|^API_KEY_SECRET=.*|API_KEY_SECRET=$(openssl rand -hex 32)|" omniroute/.env
sed -i "s|^INITIAL_PASSWORD=.*|INITIAL_PASSWORD=$(openssl rand -base64 18)|" omniroute/.env

# Dua default OmniRoute yang aman di localhost dan berbahaya begitu publik.
# Keduanya ship sebagai nilai tidak aman — benar untuk aplikasi local-first,
# salah begitu Caddy menaruhnya di internet.
sed -i "s|^REQUIRE_API_KEY=.*|REQUIRE_API_KEY=true|" omniroute/.env
sed -i "s|^AUTH_COOKIE_SECURE=.*|AUTH_COOKIE_SECURE=true|" omniroute/.env

grep -E '^(JWT_SECRET|API_KEY_SECRET|INITIAL_PASSWORD|REQUIRE_API_KEY|AUTH_COOKIE_SECURE)=' omniroute/.env
```

**`REQUIRE_API_KEY=true` bukan opsional kalau Anda memakai profil `proxy`.**
Dengan `false`, `/v1/*` melayani siapa pun tanpa kunci — kunci ngawur pun
diterima. Ditemukan langsung pada deploy pertama 2026-08-28: request tanpa
header auth sama sekali mengembalikan 200 beserta jawaban model. Hari ini
kerugiannya kuota free-tier; begitu ada provider berbayar terpasang, siapa pun
yang menemukan domain Anda bisa membelanjakan uang Anda. `preflight proxy`
memblokir deploy kalau nilainya bukan `true`.

`AUTH_COOKIE_SECURE=true` disyaratkan oleh `omniroute/.env.example` sendiri
untuk deployment non-localhost apa pun — tanpa itu cookie sesi admin tidak
membawa flag `Secure`.

Verifikasi setelah menyala:

```bash
# 401 = benar. 200 = gerbang Anda terbuka untuk dunia.
curl -s -o /dev/null -w '%{http_code}
' -X POST https://DOMAIN_ANDA/v1/chat/completions   -H 'Content-Type: application/json'   -d '{"model":"oc/big-pickle","messages":[{"role":"user","content":"hi"}]}'
```

**Catat `INITIAL_PASSWORD`-nya** — itu password login pertama ke dashboard.
Kalau lupa, tetap ada tersimpan di `omniroute/.env` selama tidak dihapus
manual.

Jangan sentuh baris `OMNIROUTE_DISABLE_BACKGROUND_SERVICES` — defaultnya
sudah nonaktif (background services jalan normal). Baris itu cuma
diaktifkan CI untuk mempercepat test, bukan untuk deploy sungguhan.

### 3.2 agent-sidecar (opsional)

```bash
cat > agent-sidecar/.env <<'EOF'
OMNIROUTE_API_KEY=
AGENT_SIDECAR_MODEL_ID=opencode/big-pickle
EOF
```

`OMNIROUTE_API_KEY` diisi di Langkah 7.1, setelah OmniRoute hidup dan bisa
provisioning key. Jangan set `AGENT_SIDECAR_EXECUTOR` di sini — biarkan
default `local` kecuali Anda sudah baca alasannya di
[vps-hardening.md](./vps-hardening.md#2-where-smolagents-executes-generated-code).

### 3.3 observability / Langfuse (opsional)

```bash
cat > observability/.env <<EOF
SALT=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
NEXTAUTH_URL=http://localhost:3000
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(openssl rand -hex 24)
POSTGRES_DB=postgres
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)
REDIS_AUTH=$(openssl rand -hex 24)
LANGFUSE_REDIS_PORT=16379
EOF
PGPASS=$(grep '^POSTGRES_PASSWORD=' observability/.env | cut -d= -f2-)
echo "DATABASE_URL=postgresql://postgres:${PGPASS}@postgres:5432/postgres" >> observability/.env
```

### 3.4 OpenHands Agent Canvas (opsional, tapi wajib kalau pakai profile ini)

```bash
echo "export OH_AGENT_CANVAS_SECRET_KEY=$(openssl rand -base64 32)" >> ~/.bashrc
source ~/.bashrc
```

Kalau ini tidak di-set, `docker-compose.yml` jatuh ke fallback
`CHANGEME-openssl-rand-base64-32` — string yang **sudah publik** di git
history repo ini. Key ini dipakai OpenHands mengenkripsi credential LLM
yang tersimpan, jadi jangan sampai kelewat sebelum pakai profile
`openhands` beneran.

---

## Langkah 4 — Preflight check

```bash
./scripts/stax-preflight.sh base                                    # kalau cuma base
./scripts/stax-preflight.sh base agent-sidecar observability openhands  # sesuaikan profile Anda
```

- **FAIL** (merah) → wajib dibenahi dulu, jangan lanjut.
- **WARN** (kuning) → bukan pemblokir, tapi baca dan pahami (biasanya soal
  `AGENT_SIDECAR_EXECUTOR=local` atau bind non-loopback).

---

## Langkah 5 — Build & jalankan OmniRoute (`base`)

Build image dipisah dari `up` supaya heap ceiling-nya bisa diatur — pola
yang sama dipakai CI setelah pernah ditemukan build ini bisa gagal
kehabisan memori:

```bash
docker build --target runner-base --build-arg OMNIROUTE_BUILD_MEMORY_MB=1536 -t omniroute:base omniroute/
```

Proses ini berat dan bisa makan beberapa menit. Kalau RAM VPS Anda pas-pasan,
pastikan swap dari Langkah 1 sudah aktif (`free -h` untuk cek) sebelum
menjalankan ini.

Setelah image jadi, jalankan (tanpa `--build` lagi):

```bash
docker compose --profile base up -d
```

---

## Langkah 6 — Verifikasi OmniRoute hidup

```bash
curl -sf http://localhost:20128/healthz && echo " -> OK"
```

Login pakai `INITIAL_PASSWORD` dari Langkah 3.1:

```bash
curl -sf -c /tmp/king-cookies.txt -X POST http://localhost:20128/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"password":"ISI_INITIAL_PASSWORD_ANDA"}'
curl -sf -b /tmp/king-cookies.txt http://localhost:20128/api/auth/status
```

Tes chat completion pakai model gratis tanpa API key eksternal (kalau ini
jalan, gateway-nya sehat):

```bash
curl -sf -X POST http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"opencode/big-pickle","messages":[{"role":"user","content":"Say OK"}]}'
```

Kalau ketiganya jalan, `base` sudah beres. Berhenti di sini kalau memang
cuma butuh gateway OmniRoute — lanjut ke Langkah 7 hanya untuk profile yang
Anda perlukan.

---

## Langkah 7 — Profile tambahan (opsional, pilih sesuai kebutuhan)

### 7.1 agent-sidecar

Generate API key ter-scope minimal khusus sidecar — **jangan pernah** pakai
key ber-scope admin:

```bash
curl -sf -b /tmp/king-cookies.txt -X POST http://localhost:20128/api/keys \
  -H "Content-Type: application/json" \
  -d '{"name":"agent-sidecar","scopes":["models","routing","health"]}'
```

Salin nilai `"key"` dari respons ke `agent-sidecar/.env`
(`OMNIROUTE_API_KEY=...`), lalu:

```bash
docker compose --profile base --profile agent-sidecar build agent-sidecar
docker compose --profile base --profile agent-sidecar run --rm agent-sidecar \
  uv run pytest tests/ -v
```

**Kedua profile wajib disertakan bersamaan** (`--profile base --profile
agent-sidecar`) — `agent-sidecar` bergantung pada `omniroute-base` yang
cuma "ada" di bawah profile `base`; tanpa itu Compose akan menolak dengan
error "depends on undefined service".

### 7.2 observability (Langfuse)

```bash
docker compose --profile observability --env-file observability/.env up -d
```

(`--env-file` wajib di sini — beda dengan `base`/`agent-sidecar`/`openhands`
yang membaca `omniroute/.env` lewat `env_file:` internal, service Langfuse
murni mengandalkan interpolasi `${VAR}` dari environment/`--env-file`.)

Cek sehat:

```bash
curl -sf "http://localhost:3000/api/public/health?failIfDatabaseUnavailable=true"
```

Buka `http://localhost:3000` lewat SSH tunnel (Langkah 8), daftar akun
pertama, buat project + API key di sana untuk dipakai `agent-sidecar` atau
OpenHands kalau mau kirim trace.

### 7.3 OpenHands Agent Canvas

```bash
docker compose --profile base --profile openhands up -d
```

Buka `http://localhost:8000` lewat SSH tunnel (Langkah 8) →
`Settings > LLM`:
- **Base URL**: `http://omniroute-base:20128/v1` (hostname jaringan compose)
- **API key**: key ter-scope, dibuat dengan pola sama seperti 7.1
- **Model**: mulai dengan `opencode/big-pickle` untuk tes gratis sebelum
  pakai model berbayar

Tidak ada cara scripting langkah ini — wiring LLM OpenHands murni manual
lewat UI, sekali per deployment.

---

## Langkah 8 — Akses UI dari luar VPS dengan aman

Sesuai tabel port di atas, OpenHands/Langfuse/MinIO/Postgres/ClickHouse
sengaja `127.0.0.1`-only — tidak bisa diakses langsung dari internet
walau Anda tahu IP VPS-nya. Ini keputusan sadar, bukan kelalaian (lihat
[vps-hardening.md](./vps-hardening.md)).

Cara akses: SSH tunnel dari komputer Anda ke VPS, port sesuai yang Anda
perlukan:

```bash
ssh -L 8000:127.0.0.1:8000 -L 3000:127.0.0.1:3000 -L 9091:127.0.0.1:9091 user@IP_VPS_ANDA
```

Lalu buka `http://localhost:8000` (OpenHands) atau `http://localhost:3000`
(Langfuse) di browser komputer Anda seperti biasa — port di sisi Anda,
bukan di VPS, yang terbuka.

Kalau memang perlu expose ke publik (misal Langfuse dipakai satu tim),
**jangan** langsung buka portnya — pasang reverse proxy (Caddy/nginx)
dengan TLS + auth tambahan di depan dulu, baru set
`LANGFUSE_WEB_BIND_HOST=0.0.0.0` dkk. Detail trade-off tiap opsi ada di
[vps-hardening.md](./vps-hardening.md).

---

## Langkah 9 — Operasional harian

**Cek status semua container aktif:**

```bash
docker compose --profile base --profile agent-sidecar --profile observability --profile openhands ps
```

**Lihat log:**

```bash
docker compose --profile base logs -f omniroute-base
```

**Restart satu service:**

```bash
docker compose restart omniroute-base
```

**Update ke versi terbaru:**

```bash
git pull
docker build --target runner-base --build-arg OMNIROUTE_BUILD_MEMORY_MB=1536 -t omniroute:base omniroute/
docker compose --profile base up -d   # compose otomatis restart container yang image-nya berubah
```

**Backup** (kalau pakai `observability`): volume `langfuse_postgres_data`
dan `langfuse_clickhouse_data` menyimpan seluruh data trace —
`docker run --rm -v langfuse_postgres_data:/data ...` atau `pg_dump` biasa
secara berkala.

**Matikan semuanya:**

```bash
docker compose --profile base --profile agent-sidecar --profile observability --profile openhands down
```

Tambahkan `-v` di akhir **hanya** kalau memang mau menghapus data volume
juga — ini destruktif dan tidak bisa dibatalkan.

---

## Troubleshooting

**Build OmniRoute mati sendiri / proses "Killed" saat `npm run build`.**
Kemungkinan kehabisan memori. Pastikan swap aktif (Langkah 1) dan RAM
tersedia minimal ~5GB saat build berlangsung (`free -h` di terminal lain).
Ini kegagalan yang pernah terbukti *intermiten* bahkan di lingkungan
dengan 15GB RAM — kalau gagal sekali, coba ulang perintah `docker build`
yang sama sebelum curiga ada yang salah di konfigurasi Anda.

**`docker compose ... build agent-sidecar` atau `... openhands` gagal
dengan `depends on undefined service`.** Lupa menyertakan `--profile base`
bersamaan. Semua command yang menyentuh `agent-sidecar` atau `openhands`
wajib `--profile base` juga.

**Lupa `INITIAL_PASSWORD`.** Cek `omniroute/.env` — masih tersimpan di
sana selama tidak sengaja dihapus atau file-nya diganti.

**Preflight melaporkan FAIL soal `OH_AGENT_CANVAS_SECRET_KEY`.** Env var
itu di-`export` di shell (Langkah 3.4), bukan di file `.env` mana pun —
pastikan `source ~/.bashrc` sudah dijalankan di sesi shell yang sama
dengan yang menjalankan `docker compose`.
