# Reverse proxy + TLS (profil `proxy`)

Panduan ini melengkapi [`vps-deploy-guide.md`](./vps-deploy-guide.md) untuk kasus
**gateway publik dengan domain sendiri**: OmniRoute diakses lewat HTTPS di
domain Anda, bukan lewat `http://IP:20128`.

Ditulis dalam bahasa Indonesia mengikuti `vps-deploy-guide.md`; keputusan
keamanannya ada di [`vps-hardening.md`](./vps-hardening.md) yang berbahasa
Inggris (pembagian bahasa yang sama sudah dicatat di sana).

## Kenapa ini ada

`vps-hardening.md` menyebut reverse proxy + TLS sebagai penunjuk satu kalimat,
bukan prosedur. Profil `proxy` mengisi kekosongan itu dengan Caddy, yang
mengurus penerbitan dan perpanjangan sertifikat Let's Encrypt secara otomatis
tanpa cron atau certbot terpisah.

Yang berubah dibanding deploy tanpa proxy:

| | Tanpa `proxy` | Dengan `proxy` |
|---|---|---|
| Pintu publik | `DASHBOARD_PORT` (20128), HTTP polos | 80 + 443 saja, HTTPS |
| Sertifikat | tidak ada | Let's Encrypt, otomatis diperpanjang |
| Firewall cloud | buka 20128 | buka 80 + 443, **20128 tetap tertutup** |

Caddy menghubungi OmniRoute lewat hostname jaringan Docker
(`omniroute-base:20128`), jadi trafik antara keduanya tidak pernah keluar dari
compose network. `DASHBOARD_PORT` memang masih dipublikasikan ke host oleh
`omniroute/docker-compose.yml`, tapi tidak perlu — dan tidak boleh — dibuka di
firewall cloud.

## Prasyarat

1. Domain yang Anda kuasai, dengan akses ke pengaturan DNS-nya.
2. **A record** yang mengarah ke IP publik VPS. Contoh di Porkbun untuk
   `gateway.arject.co`: Type `A`, Host `gateway`, Answer `<IP publik VPS>`.
3. Port **80 dan 443** terbuka di firewall penyedia cloud (di GCP: centang
   "Allow HTTP traffic" + "Allow HTTPS traffic") **dan** di `ufw`
   (`ufw allow 80/tcp && ufw allow 443/tcp`).

Port 80 wajib terbuka, bukan opsional: Let's Encrypt memakai tantangan
HTTP-01 lewat port itu. Caddy sendiri yang mengalihkan `http://` ke `https://`
setelah sertifikat terbit.

**Tunggu DNS propagasi sebelum menjalankan profil ini.** Kalau A record belum
resolve, ACME gagal dan Caddy akan mengulang terus. Cek dulu:

```bash
dig +short gateway.arject.co    # harus mengembalikan IP VPS Anda
```

## Konfigurasi

Satu variabel, dibaca dari `.env` di root repo (bukan `omniroute/.env`):

```bash
echo "OMNIROUTE_PUBLIC_DOMAIN=gateway.arject.co" >> .env
```

Lalu jalankan preflight — ini menolak nilai kosong, placeholder, dan hostname
yang bukan FQDN:

```bash
./scripts/stax-preflight.sh base proxy
```

## Menjalankan

```bash
docker compose --profile base --profile proxy up -d
```

Profil `proxy` **tidak berdiri sendiri** — `caddy` punya
`depends_on: omniroute-base`, jadi `--profile base` harus selalu ikut
disertakan. Ini pola yang sama dengan `agent-sidecar`.

Pantau penerbitan sertifikat pada boot pertama:

```bash
docker compose logs -f caddy
```

## Verifikasi

```bash
curl -sf https://gateway.arject.co/healthz
curl -vI https://gateway.arject.co 2>&1 | grep -i "issuer\|HTTP/"
```

Lalu pastikan port aplikasi memang tertutup dari luar — ini yang membuktikan
proxy benar-benar jadi satu-satunya pintu masuk:

```bash
curl -sS --max-time 5 http://<IP_VPS>:20128/healthz   # harus timeout / connection refused
```

## Integrasi Claude Code

OmniRoute mengekspos endpoint Anthropic Messages API asli di `/v1/messages`
(lihat `omniroute/src/app/api/v1/messages/route.ts`), sehingga bisa dipakai
langsung sebagai target `ANTHROPIC_BASE_URL` tanpa lapisan penerjemah apa pun.

Prosedur lengkapnya sudah ada di upstream:
`omniroute/docs/guides/CLAUDE-CODE-CONFIGURATION.md` — ikuti dokumen itu,
jangan duplikasi isinya di sini. Yang khusus untuk deploy ini hanyalah nilai
base URL-nya: `https://gateway.arject.co` (bukan `http://localhost:20128`).

Buat API key lewat dashboard dengan **scope minimal** (`models`, `routing`,
`health`) — jangan `admin` atau `manage`, mengikuti aturan yang sama seperti
pada `agent-sidecar/.env.example`.

## Catatan operasional

- Sertifikat dan state ACME disimpan di named volume `caddy-data`. Jangan
  hapus volume ini sembarangan — Let's Encrypt punya rate limit penerbitan,
  dan kehilangan state memaksa penerbitan ulang dari nol.
- Mengganti domain berarti mengubah `OMNIROUTE_PUBLIC_DOMAIN` lalu
  `docker compose --profile base --profile proxy up -d` lagi; Caddy akan
  menerbitkan sertifikat baru untuk domain baru itu.
- Belum diverifikasi secara live saat konfigurasi ini ditulis (tidak ada
  Docker daemon yang bisa dipakai saat itu). Boot pertama di VPS dengan DNS
  yang sudah benar adalah verifikasi end-to-end yang sesungguhnya — sama
  seperti catatan serupa pada integrasi lain di repo ini.
