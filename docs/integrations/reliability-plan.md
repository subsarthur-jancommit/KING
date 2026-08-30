# Rencana keandalan — masalah yang terverifikasi, dan urutan penyelesaiannya

Ditulis 2026-08-30, setelah dua hari yang menghasilkan satu outage 14 jam dan
sejumlah klaim saya sendiri yang ternyata salah. Setiap masalah di bawah punya
bukti yang bisa Anda periksa ulang; yang tidak terverifikasi ditaruh terpisah di
bagian terakhir dan **tidak** dijadikan dasar keputusan.

---

## Masalah

Diurutkan dari yang paling merusak.

### M1 — Guard yang tidak pernah dieksekusi

`scripts/codegraph-refresh.sh:73` menulis:

```sh
if docker ps --format '{{.Names}}' | grep -qx ollama; then
```

Nama container yang sebenarnya adalah **`king-ollama-1`**. `grep -qx` menuntut
kecocokan seluruh baris, jadi kondisi itu **tidak pernah benar**. Seluruh blok
penurunan model di dalamnya belum pernah berjalan sekali pun.

Yang membuatnya buruk bukan bug-nya, melainkan bahwa saya mendokumentasikannya
di **dua tempat** sebagai sifat keamanan yang menopang keputusan lain:
`localmodel.md` menyebutnya sebagai penjaga tabrakan build 4 GB dengan model
2,1 GB, dan `codegraph.md` mengulanginya. Dua dokumen mengklaim perlindungan
dari kode mati.

### M2 — Instrumen yang mengubah "tidak bisa diukur" menjadi "terukur nol"

Tiga kejadian, satu kelas:

| tempat | perilaku |
|---|---|
| `codegraph-refresh.sh:74` | `... \| wc -l \|\| echo 0` — `docker exec` gagal menghasilkan `"0\n0"`, lalu `[ "$loaded" -gt 0 ]` error "integer expected". Karena itu kondisi `if`, `set -e` tidak berlaku; skrip lanjut ke build |
| `stax-preflight.sh` `check_disk_gb` | dua `return 0` telanjang saat `df` tidak ada atau tidak terbaca — **tanpa output apa pun**. Operator membaca preflight bersih sebagai "disk sudah dicek" |
| probe OOM saya kemarin | `graphify ... \| tail -25` melaporkan exit code `tail`, yaitu 0, padahal prosesnya di-OOM-kill dan tidak menulis grafik |

Ketiganya menghasilkan angka yang terlihat sah dari pengukuran yang gagal.

### M3 — Diagnosis 504 saya salah, dan yang benar membuat pemakaian model mustahil

Saya melaporkan penyebabnya `OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS` (default 30
detik). Yang sebenarnya membunuh panggilan itu
`omniroute/src/lib/resilience/settings.ts:43-46`:

```ts
const parsed = Number(process.env.RATE_LIMIT_MAX_WAIT_MS || "15000");
```

**15 detik**, setengah dari yang saya sebut, dan mekanisme yang berbeda. Dengan
`OLLAMA_KEEP_ALIVE=0`, model diturunkan begitu satu permintaan selesai, sehingga
pada jadwal 15 menit **setiap panggilan triage dingin secara konstruksi**.
Dingin = 29 detik. Melawan batas 15 detik itu bukan panggilan yang rapuh — itu
panggilan yang tidak mungkin berhasil.

### M4 — Model lokal menyebabkan satu-satunya breach yang pernah dialami gateway

Run produksi `3dZwOYhKLDEl6tGYNIunp` (2026-08-30T00:57:30Z) adalah satu-satunya
`breach:true` dalam seluruh riwayat `gateway_monitor`. Isinya:
`byProvider {"ollama":{"total":17,"failed":9}}`, rasio 0,529, dan ketiga sampel
kegagalannya `ollama/qwen2.5` **504**.

Seluruh trafik di jendela itu adalah pengujian saya sendiri. Saya melihat run itu
`SUCCEEDED`, melaporkan monitor sehat, dan **tidak membaca keluarannya**.

Konsekuensi desainnya lebih penting dari kesalahan saya: dengan
`OLLAMA_NUM_PARALLEL=1` dan `OLLAMA_MAX_QUEUE=2`, panggilan triage yang dikirim
saat breach akan mengantre di belakang permintaan yang sedang timeout, lalu
muncul di jendela 15 menit berikutnya sebagai kegagalan ollama baru — **memicu
breach lagi**. Itu lingkaran diagnostik yang memberi makan kesalahan yang sedang
didiagnosisnya.

### M5 — Model lokal gagal pada tugas yang menjadi alasan ia dibangun

| prompt | hasil |
|---|---|
| gaya definisi | kedua model menjawab `CRITICAL` untuk **semua** skenario, termasuk 503 transient yang jelas. "WHY"-nya membeo definisi CRITICAL kata per kata |
| few-shot, satu kata, 1.5b | **2 dari 4**, dan **kedua kegagalannya naik-kelas** |

Monitor yang over-eskalasi menghasilkan alert fatigue, yang lebih buruk daripada
ambang batas yang kadang kasar.

Dan aturan klasifikasinya **saya tulis tangan ke dalam prompt sebelum model mana
pun melihatnya**: CRITICAL kalau 401/403 atau semua provider gagal, IGNORE kalau
hanya 503 transient. Setiap klausa adalah predikat atas `byProvider` dan
`sample` — dua struktur yang kodenya **sudah menghitung**. Tidak ada ambiguitas
yang bisa diselesaikan model; satu-satunya kontribusi yang tersedia baginya
adalah menjawab salah pada pertanyaan yang sudah bisa diputuskan.

### M6 — Tidak ada yang memantau si pemantau

`gateway_monitor` diam **14 jam 19 menit** (2026-08-29T10:38 → 2026-08-30T00:57)
dan tidak ada yang tahu. Container Activepieces melaporkan `healthy` sepanjang
itu, karena healthcheck-nya menjawab dari API dan API tidak membutuhkan antrean.

Ini kegagalan senyap **keempat** di deployment ini, dan satu-satunya yang tidak
punya penjaga sama sekali — tiga sebelumnya kini diblokir preflight.

### M7 — Healthcheck ollama tidak bisa mendeteksi kegagalan yang menjadi alasannya ditulis

`docker-compose.yml`: `ollama list | grep -q "$${OLLAMA_MODEL%%:*}"`. Pemotongan
`%%:*` mengubah `qwen2.5:3b-instruct-q4_K_M` menjadi literal `qwen2.5`, yang
cocok dengan **tag qwen2.5 apa pun**. Di VPS saat ini ada dua tag terpasang.
Mengganti `OLLAMA_MODEL` ke tag yang belum pernah ditarik menghasilkan container
sehat yang 404 pada setiap permintaan — persis bentuk yang komentar di atasnya
klaim dicegah.

### M8 — Angka terukur sudah ter-drift

Satu build codegraph yang sama tercatat sebagai **58.390 node / 163.274 edge** di
`codegraph.md`, dan **58.382 / 163.257** di `scalability-system.md` serta di
komentar CI. Yang salah justru tabel "diukur, bukan ditebak" — artefak yang
seluruh tugasnya adalah menjadi angka rujukan.

### M9 — Draft triage tidak terkonfigurasi

Input `step_1` di flow asli berisi tepat empat kunci: `token`, `secret`,
`logsUrl`, `alertUrl`. Tidak ada `triageUrl` maupun `triageKey` — pembaruan itu
diblokir. Mem-publish draft apa adanya berarti `fetch(undefined)` → TypeError →
`UNKNOWN`, terdegradasi karena alasan yang tidak ada hubungannya dengan model.

Sifat keamanannya sendiri **memang terbukti**, tapi pada flow salinan yang
inputnya lengkap dan benar-benar menerima 504 dari gateway. Itu perbedaan yang
harus dicatat, bukan diratakan.

---

## Solusi

Berurutan. Yang di atas memblokir yang di bawah.

### S1 — Hentikan pemakaian model lokal di `gateway_monitor`, hitung severity di kode

**SELESAI 2026-08-30.** 12 asersi lolos dalam 70 ms, flow ter-publish, salinan uji dihapus. Buang `triage()` dan pemanggilnya dari `step_1`. Ganti dengan tiga
predikat atas data yang sudah ada di tangan:

- `CRITICAL` — ada status 401/403, **atau** setiap provider punya `failed === total`
- `IGNORE` — setiap sampel kegagalan 503 atau cocok `/service_unavailable/`
- `WARNING` — sisanya

Tambahan yang wajib: **kecualikan `provider === 'ollama'` dari rasio monitor**,
atau kegagalan model lokal akan terus memicu alert gateway seperti pada M4.

Biaya: nol runtime — ini justru **menghapus** satu panggilan jaringan dari jalur
alert. Sekitar 40 baris dibuang. Tidak ada yang hilang: jalur triage belum pernah
berjalan di produksi.

Risikonya jujur: severity hasil kode itu kaku, dan bentuk kegagalan baru akan
dapat label yang kurang pas. Tapi severity hanyalah metadata pada alert yang
tetap terkirim — kontrak degradasi yang sama dengan draft. Risiko pilihan
sebaliknya tidak terbatas: jalur alert yang latensi dan keberhasilannya
bergantung pada komponen yang paling mungkin sedang rusak.

### S2 — Perbaiki tiga instrumen yang berbohong

**SELESAI 2026-08-30**, terbukti live di VPS dengan model yang sengaja dibuat residen:
deteksi bekerja, `unloaded; nothing resident.`, `residen SESUDAH = 0`.

Butuh dua percobaan. Percobaan pertama **mendeteksi** model residen dengan benar
lalu tidak menghentikan apa pun: ia memanggil `ollama ps --format`, yang sintaks
Docker — `ollama ps` tidak menerima flag selain `-h` dan menjawab
`unknown flag: --format`, sehingga loop-nya mengiterasi nol item sambil mencetak
"unloading before the build". Terukur: `sebelum=1, sesudah=1`. Kelas yang sama
dengan bug nama container yang baru diperbaiki di blok yang sama — perintah yang
terlihat masuk akal dan tidak pernah dijalankan siapa pun, dua kali dalam satu
file dalam satu hari.

Karena itu perbaikannya kini **memverifikasi** hasilnya, bukan mengumumkannya.

Ditambah lapisan kedua yang tidak berbagi mekanisme dengan yang pertama:
`MemAvailable` dibaca langsung sebelum build, tolak di bawah 3584 MB terukur.
Selama percobaan yang gagal itu, lapisan inilah yang menjaga build tetap aman
(`4249 MB available`) — argumen untuk keberadaannya terbukti pada hari yang sama
ia ditulis. Dan enam self-test baru menutup mode kegagalan instrumen. Jangan pernah biarkan "tidak bisa diukur" runtuh menjadi "terukur
nol":

- `codegraph-refresh.sh`: perbaiki nama container (`king-ollama-1`, atau lebih
  baik cocokkan dengan `--filter name=`), tangkap keluaran mentah lebih dulu,
  dan **gagal** kalau `docker exec` gagal atau hasilnya bukan angka.
- `check_disk_gb`: ganti kedua `return 0` telanjang dengan `fail`, tambahkan
  fallback `df -k` untuk host non-GNU **di perubahan yang sama** — tanpa itu,
  pass senyap hari ini berubah jadi blokir keras di Alpine/macOS.
- Aturan umum yang berlaku ke depan: perintah yang mengukur tidak boleh berada di
  hulu pipe yang menelan exit code-nya.

### S3 — Buat model lokal benar-benar terpakai: residen, dan 1,5B

**SELESAI 2026-08-30, dan lebih murah dari kedua opsi yang saya tawarkan.**

Rencana ini menawarkan dua pilihan: naikkan `RATE_LIMIT_MAX_WAIT_MS` ke 60000,
atau akui `ollama/*` tidak terpakai. Pengukuran menunjukkan **tidak satu pun
diperlukan.**

Dengan model **residen** (`OLLAMA_KEEP_ALIVE=-1`), 12 panggilan lewat OmniRoute
dengan prompt yang berbeda-beda menghasilkan **median 2,1 detik, maksimum 2,2
detik** — margin tujuh kali lipat terhadap batas 15 detik. Tidak ada satu pun
yang gagal.

Itu sekaligus **membatalkan klaim saya sendiri** bahwa OmniRoute menambah ~9
detik. Selisih antara "langsung ke Ollama" dan "lewat gateway" yang saya
laporkan bukan overhead gateway sama sekali — itu model yang dimuat ulang dari
disk pada setiap panggilan, karena `KEEP_ALIVE=0`. Gateway-nya nyaris tidak
menambah apa pun, dan memintasnya tidak akan membeli apa-apa.

Perubahannya: model **1,5B** (bukan 3B, yang 504 dua kali lewat gateway dan
tidak lebih akurat), `KEEP_ALIVE=-1`, `mem_limit` turun dari 2560m ke **1536m**
karena residennya terukur **1,126 GiB**, bukan 2,1 GB.

Satu instrumen hampir menipu saya lagi di sini. Pengukuran pertama memakai
prompt identik dua belas kali dan melaporkan median **0,0 detik** — itu cache
OmniRoute menjawab, bukan model. Angka di atas dari prompt yang seluruhnya unik.

Yang **tidak** berubah: keduabelas jawabannya tetap `CRITICAL`. Kecepatan
beres; akurasi tidak, dan itu independen. Lihat S5.

### S4 — Dead-man's switch untuk monitor

**SELESAI 2026-08-30.** Membaca Postgres, bukan Activepieces. `gateway_monitor` menulis heartbeat setiap run, dan sesuatu **di
luar Activepieces** — cron host — memberi tahu kalau heartbeat lebih tua dari
~35 menit.

Yang membuatnya bekerja adalah justru bahwa ia tidak berbagi nasib: menaruhnya di
flow Activepieces ketiga akan memberinya takdir yang sama dengan yang diawasinya.
Biayanya satu entri cron, dengan konsekuensi satu bagian bergerak di luar proyek
compose — melanggar tata letak proyek tunggal yang selama ini dipegang repo, dan
itu memang harga yang dibayar sengaja.

### S5 — Satu percobaan berbatas waktu untuk profil `localmodel`, atau hapus

**Berikutnya.** Setelah S1, profil ini tidak punya konsumen terbukti. Biayanya
nyata: image **8,45 GB** (dugaan awal 3–4 GB) yang membawa CUDA dan ROCm di host
tanpa GPU, di disk 18 GB, dengan preflight yang harus menuntut 12 GB bebas.

Satu pemakaian yang argumennya jujur: **fallback untuk `ask_free_model` ketika
semua provider gratis membalas `service_unavailable`** — celah yang CI memang
sudah amati dan toleransi secara eksplisit. Pemakaian itu tahan latensi (panggilan
tool MCP dengan Claude di dalam loop, sehingga jawaban salah langsung terlihat)
dan tidak punya amplifikasi alert fatigue.

Kalau dalam jangka waktu yang Anda tetapkan itu tidak dipasang dan dijalankan,
hapus profilnya dan reklamasi ~10 GB. Bukti yang akan mengubah kesimpulan ini:
tingkat keberhasilan di atas 95% lewat OmniRoute setelah S3 dibereskan, atau satu
insiden tercatat di mana semua provider gratis tumbang bersamaan.

### S6 — Kecilkan yang tersisa

**Nanti.** `ollama list | grep -q "$${OLLAMA_MODEL}"` tanpa pemotongan tag, atau
`ollama show "$${OLLAMA_MODEL}"` yang menegaskan model persis — verifikasi dulu
terhadap keluaran `ollama list` sungguhan, karena grep eksak bisa mengubah
false-healthy jadi false-unhealthy. Dan satukan angka node yang ter-drift ke satu
sumber.

---

## Keputusan: triage `gateway_monitor`

**Ganti model dengan aturan deterministik.** Bukan "tunda", bukan "perbaiki
prompt-nya".

Alasannya bukan bahwa model lokalnya buruk, melainkan bahwa pertanyaannya sudah
terputuskan sebelum model dilibatkan. Saya menulis aturannya di prompt; setiap
klausa adalah predikat atas data yang kodenya sudah punya. Menaruh aturan yang
sudah diketahui ke dalam model 1,5B menukar jawaban instan dan deterministik
dengan jawaban 12–29 detik yang benar 2 dari 4 kali — dan salah ke arah yang
merusak monitor.

Uji umumnya, yang layak dipegang ke depan: **model layak dipakai hanya kalau
pemetaan dari input ke output tidak bisa dituliskan lebih dulu.** Ujinya adalah
apakah aturannya sudah tertulis, bukan apakah tugasnya terasa sederhana.

Profil `localmodel` tetap hidup untuk sementara, tapi bukan atas dasar ini —
lihat S5.

---

## Tidak dipakai sebagai dasar

Tercatat supaya tidak diam-diam masuk lewat pintu belakang nanti.

- **"Jadwal monitor tidak ter-registrasi ulang di Redis baru."** Terbantah:
  empat run berturut-turut di interval 15 menit tepat (04:42, 04:57, 05:12,
  05:27 UTC). Jadwalnya selamat.
- **"`search_web` terblokir karena tidak ada model lokal."** Salah, dan itu
  premis saya sendiri. Ia gagal dengan `Provider custom is not supported for web
  search` dari piece `@activepieces/piece-ai` — sisi klien, sebelum ada
  permintaan jaringan. Model lokal tidak pernah menjadi penghalangnya, dan model
  1,5B tidak bisa menelusuri web dalam konfigurasi apa pun. Perbaikannya berdiri
  sendiri dan tidak masuk rencana ini.
- **Delapan belas usulan lain** dari analisis multi-agen. Tahap penyerangan
  adversarialnya **tidak pernah berjalan** — 21 dari 23 agen menabrak batas
  sesi. Angka "18 refuted" yang dilaporkan workflow itu **artefak bug skrip
  saya**: filternya menghitung verdict `null` dari agen yang gagal sebagai
  "terbantah". Tidak ada satu pun yang benar-benar dibantah. Yang masuk dokumen
  ini hanyalah usulan yang **saya verifikasi sendiri** terhadap kode dan host.
