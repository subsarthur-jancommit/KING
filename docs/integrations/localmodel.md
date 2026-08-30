# Model lokal — prajurit yang tidak bisa kehabisan kuota (profil `localmodel`)

## Kenapa ada

Inti KING adalah memakai kolam API gratis untuk tugas receh, supaya Claude tidak
terpakai untuk hal yang tidak membutuhkannya. Tapi free tier punya satu sifat
yang tidak bisa diperbaiki dengan konfigurasi: ia bisa tumbang. CI repo ini
sudah pernah melihat `opencode/big-pickle` membalas `service_unavailable`, dan
kode CI-nya sampai harus menoleransi itu secara eksplisit.

Model lokal menutup celah terakhir itu. Ia tidak lebih pintar dari model gratis
mana pun — ia hanya **selalu ada**, tidak punya kuota, dan tidak mengirim apa
pun keluar dari VPS.

**Tidak ada kode gateway yang ditulis untuk ini.** OmniRoute sudah mendaftarkan
`ollama-local` (`omniroute/src/shared/constants/providers/local.ts:32-44`)
dengan `passthroughModels: true` dan tanpa API key wajib. Yang ditambahkan repo
ini hanya sebuah container dan skrip pendaftaran.

## Untuk apa — dan bukan untuk apa

**Untuk**: triage dan klasifikasi. Menilai apakah sebuah alert penting,
melabeli log, memilih cabang di flow. Keluaran pendek, keputusan kecil, dijalankan
terjadwal.

**Bukan untuk review kode.** Model yang cukup pintar untuk itu berarti 7B ke
atas, dan di 2 vCPU tanpa GPU itu hitungan menit per jawaban. Review kode tetap
lewat free tier OmniRoute atau Claude.

## Yang diukur, bukan ditebak

Semua dari VPS ini (2 vCPU AMD EPYC 7B12, 7,8 GB, tanpa GPU):

| | |
|---|---|
| Latensi, model **residen** | **median 2,1 detik**, maks 2,2 (12 panggilan, prompt unik) |
| Memori saat model residen | **1,126 GiB** (1,5B) → `mem_limit: 1536m` |
| Ukuran model | 986 MB (`qwen2.5:1.5b-instruct-q4_K_M`) |
| Waktu tarik model | 17 detik |
| **Ukuran image ollama** | **8,45 GB** |

Angka terakhir itu kejutan yang tidak menyenangkan: perkiraannya 3–4 GB. Image
`ollama/ollama` membawa runtime CUDA dan ROCm **meski host tidak punya GPU**.
Menariknya membawa disk VPS dari 19 GB sisa ke **9,2 GB (81% terpakai)**.

`docker builder prune -f` mengembalikan **9,4 GB** dan disk kembali ke 20 GB,
jadi ini muat — tapi build cache tumbuh lagi setiap kali OmniRoute dibangun.
Karena itu preflight untuk profil ini menuntut **12 GB** dan menyebutkan
perintah itu.

Dua koreksi terhadap angka yang pernah saya tulis di dokumen ini.

Perkiraan awal 55–60 detik (dari aritmetika token/detik) mengabaikan bahwa prompt
triage pendek dan jawabannya satu kata — prefill yang dominan, bukan generasi.

Lalu saya melaporkan "~9 detik overhead OmniRoute", dari selisih 2,9 detik
langsung ke Ollama versus 11,6–12,5 detik lewat gateway. **Itu salah.** Selisih
itu adalah model yang dimuat ulang dari disk setiap panggilan karena
`KEEP_ALIVE=0`. Dengan model residen, lewat gateway justru **2,1 detik** —
gateway-nya nyaris tidak menambah apa pun.

Satu instrumen hampir menipu saya saat mengukurnya: dua belas panggilan dengan
prompt identik melaporkan median 0,0 detik, karena cache OmniRoute yang
menjawab. Angka di atas dari prompt yang seluruhnya unik.

## Menjalankan

```bash
./scripts/stax-preflight.sh localmodel
docker compose --profile localmodel up -d ollama
docker compose --profile localmodel run --rm -T ollama-pull
./scripts/localmodel-register.sh
```

Tidak ada port yang di-publish sama sekali. OmniRoute menjangkaunya di
`http://ollama:11434/v1` lewat jaringan Docker.

### Kenapa pendaftarannya pakai skrip, bukan dashboard

Ini jebakan paling mahal di seluruh profil ini. Untuk provider self-hosted,
executor menyelesaikan URL-nya begini
(`omniroute/open-sse/executors/default.ts:319-322`):

```
credentials?.providerSpecificData?.baseUrl || localDefault || config.baseUrl
```

dan `localDefault` milik `ollama-local` adalah `http://localhost:11434/v1`
(`local.ts:41`). **Dari dalam container gateway, `localhost` adalah gateway itu
sendiri.** Operator yang mengklik dashboard tanpa mengetik Base URL mendapat
koneksi yang tersimpan bersih, terlihat terhubung, dan menolak setiap permintaan
dengan gejala yang **tidak bisa dibedakan dari "Ollama mati"**.

`scripts/localmodel-register.sh` menyetel URL-nya eksplisit, lalu **menolak
exit 0 sebelum ada completion sungguhan** kembali lewat `/v1/chat/completions`.
Kunci sementara yang dipakainya dihapus bahkan saat gagal.

## Pilihan yang layak diketahui

| Setelan | Nilai | Alasan |
|---|---|---|
| `OLLAMA_KEEP_ALIVE` | **`-1`** | Membalik `0` yang sempat dipakai sehari. Alasan `0` adalah RAM lebih langka daripada detik; pengukuran menunjukkan detik bukan biayanya juga, dan `0` justru membuat modelnya **tidak terpakai**: setiap panggilan dingin (29 detik) melawan batas 15 detik OmniRoute. Residen = 2,1 detik. Tetap bukan `5m`, yang terburuk dari ketiganya. Biaya: 1,126 GiB permanen selama profil ini menyala. |
| `OLLAMA_MAX_QUEUE` | **`2`** | Default 512. Pada ~12 detik per permintaan, antrean 512 berarti pemanggil ke-100 menunggu 20 menit alih-alih ditolak cepat — dan flow yang retry saat timeout persis yang mengisi antrean. |
| `OLLAMA_CONTEXT_LENGTH` | **`4096`** | KV cache tumbuh linear terhadap konteks. Tanpa dipin, `mem_limit` bukan angka yang dipilih siapa pun, melainkan apa pun yang diminta pemanggil, dibatasi OOM killer. |
| `cpus` | **`1.0`** | Bukan 1.5. Di 2 vCPU, 1.5 menyisakan 0,5 untuk gateway, Activepieces, Caddy, dan dockerd bersama-sama — sementara healthcheck OmniRoute timeout dalam 5 detik. |

## Kegagalan senyap yang dijaga

| Kegagalan | Kalau tidak dijaga | Yang menjaga |
|---|---|---|
| Ollama sehat, nol model | `/v1/models` balas 200 dengan `data: []`; koneksi tersimpan dan terlihat terhubung; setiap permintaan 404 | Healthcheck menguji **nama model** lewat `ollama list`, bukan port. Dan `ollama-pull` memastikan modelnya ada |
| Base URL tertinggal `localhost` | ECONNREFUSED, disalahkan ke Ollama | `localmodel-register.sh` menyetelnya eksplisit **dan** menuntut completion nyata sebelum exit 0 |
| Guard SSRF dimatikan | Error guard yang terbaca seperti model server mati — diagnosis yang salah, lebih buruk dari kegagalan yang jelas | Preflight menolak `OMNIROUTE_ALLOW_LOCAL_PROVIDER_URLS` bernilai false |
| Disk habis diam-diam | Image 8,45 GB + model 2 GB, di host bersisa 19 GB | Preflight menuntut 12 GB dan menyebut `docker builder prune -f` |
| Antrean menumpuk | Pemanggil ke-100 menunggu 20 menit | `OLLAMA_MAX_QUEUE=2` |
| Build code graph bertabrakan dengan model residen | Kernel memilih korban berdasarkan RSS — di host ini artinya Activepieces atau gateway, bukan proses build | `codegraph-refresh.sh` menurunkan model sebelum membangun |

## Yang sengaja diterima

Ollama berjalan **tanpa autentikasi** di bridge Docker yang sama dengan
`agent-sidecar`, yang mengeksekusi kode buatan model. Tidak ada port yang
di-publish, tapi itu tidak menghalangi sesama container. Menambah jaringan kedua
akan merusak tata letak proyek tunggal berbasis `include:` yang dipakai setiap
service lain. Ini disebutkan supaya jadi keputusan yang terlihat, bukan asumsi
yang tersembunyi.

## Status jujur

**Terbukti live di VPS, ujung ke ujung (2026-08-30):**

- Preflight lolos, Ollama menyala, model tertarik, **healthy dalam 15 detik**
  — dan healthcheck itu menguji nama model, jadi "sehat" berarti benar-benar
  siap menjawab.
- `localmodel-register.sh` mendaftarkan koneksi dengan Base URL eksplisit, lalu
  **membuktikannya**: `POST /v1/chat/completions` dengan `model:
  ollama/qwen2.5:3b-instruct-q4_K_M` mengembalikan `OK` dalam **12 detik**,
  lewat gateway, bukan lewat Ollama langsung.
- **`OLLAMA_KEEP_ALIVE=0` terbukti benar untuk host ini**: Ollama diam di
  **177,6 MiB** dari plafon 2,5 GiB setelah permintaan selesai. Itu yang
  membuatnya bisa berdampingan dengan `codegraph-serve` (394,8 MiB) tanpa
  menyentuh anggaran 4 GB milik `codegraph-build`.
- Sesudahnya: RAM 4,0 dari 7,8 GiB terpakai, 3,7 GiB tersedia; disk 18 GB sisa.

**Konsumennya, sejak 2026-08-30**: combo OmniRoute `free-then-local`
(`strategy: priority`) yang mencoba `opencode/big-pickle` lebih dulu dan jatuh ke
`ollama/qwen2.5:1.5b-instruct-q4_K_M` bila gratisannya tidak tersedia.
`ask_free_model` memakainya.

Fallback itu **konfigurasi gateway, bukan kode flow** — `POST /api/combos`
sudah menyediakannya, jadi tidak ada yang ditulis dari nol, dan ia berlaku untuk
setiap konsumen. Dibuktikan dengan combo probe yang entri pertamanya dijamin
gagal: jatuh ke model lokal dan menjawab dalam 1,1 detik. Probe-nya dihapus
setelah itu.

**Yang masih harus dibuktikan, dan tanggalnya sudah ditetapkan.** Profil ini
dipasang sebagai percobaan berbatas waktu dengan tinjauan **2026-09-13**.
Pertanyaannya bukan apakah ia masih jalan, melainkan apakah ia pernah **terpakai**
— yaitu adakah permintaan nyata yang dilayani `ollama/*` lewat combo, bukan lewat
pengujian. Kalau tidak pernah dalam dua minggu, yang tersisa adalah asuransi
seharga 9,5 GB disk dan 1,126 GiB RAM permanen, dan itu keputusan yang harus
diambil sadar. Lihat [`reliability-plan.md`](./reliability-plan.md).

**Bukan untuk menilai alert.** `gateway_monitor` sempat dirancang memakai model
ini untuk triage dan itu dibatalkan setelah diukur: 2 dari 4 benar, kedua
kegagalannya naik-kelas, dan aturannya sendiri sudah ditulis tangan ke dalam
prompt sebelum model mana pun melihatnya. Severity kini dihitung di kode dalam
70 ms. Aturan umumnya: model layak dipakai hanya kalau pemetaan input ke output
tidak bisa dituliskan lebih dulu.
