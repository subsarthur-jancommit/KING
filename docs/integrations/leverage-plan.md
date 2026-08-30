# Rencana leverage — dari infrastruktur yang jalan menjadi aset yang berlipat

Ditulis 2026-08-30, setelah seluruh rencana keandalan selesai. Semua angka di
sini diukur di VPS hari ini.

Leverage di proyek ini punya arti yang bisa dihitung: **berapa banyak pekerjaan
selesai per satuan dari dua hal yang benar-benar langka** — token Claude, dan
perhatian Anda. Setiap tahap di bawah dinilai dengan ukuran itu, bukan dengan
jumlah fitur.

---

## Ukuran leverage hari ini: mendekati nol

Bukan karena ada yang rusak. Infrastrukturnya jalan, terbukti, dan terpantau.
Tapi:

| | |
|---|---|
| Permintaan lewat gerbang, 7 hari | **170** — dan hampir semuanya pengujian saya sendiri |
| Token Claude yang dihemat gerbang | **praktis nol** |
| Provider ber-API-key terhubung | **0 dari 60** yang didukung katalog |
| Provider bertier gratis yang tersedia | **32**, belum satu pun dipakai |
| Kolam yang benar-benar bekerja | **2** — `opencode` (96%) dan model lokal (100%) |

Gerbangnya dibangun untuk mengumpulkan banyak API gratis. Saat ini ia
mengumpulkan satu.

Dan delapan provider lain gagal **100%** — `felo-web`, `cloudflare-playground`,
`theoldllm`, `duckduckgo-web`, `devin-cli-agentic`, `auggie`, `aihorde`, serta
`auto` yang merupakan kebijakan routing-nya sendiri (4 dari 4 gagal, karena ia
mencoba provider yang mati).

Itu berarti tuas terbesar bukan menambah fitur. Fiturnya sudah ada.

---

## L1 — Isi kolamnya

**Rasio nilai terhadap usaha tertinggi di seluruh proyek ini.** Anda sudah
menyatakan punya sejumlah API key; katalog sudah mendukung 60 provider, 32 di
antaranya bertier gratis. Tidak ada kode yang perlu ditulis — ini pengisian
kredensial.

Yang sudah didukung dan layak dicoba lebih dulu, karena tier gratisnya nyata dan
kuotanya besar: **Groq**, **Cerebras**, **Mistral**, **Cohere**, **Together**,
**OpenRouter**, **Cloudflare Workers AI**, **NVIDIA**, **SambaNova**,
**Hyperbolic**, **Nous Research**, **Jina AI**.

Sekalian buang yang mati. Delapan provider yang gagal 100% bukan sekadar tidak
berguna — mereka **merusak `auto`**, karena kebijakan routing mencoba mereka
lebih dulu dan habis di situ. Membersihkannya membuat `auto` berguna kembali
tanpa menambah apa pun.

| ukuran | sekarang | target |
|---|---|---|
| provider terhubung | 0 | ≥ 8 |
| kolam yang bekerja | 2 | ≥ 8 |
| success rate 7 hari | 60% | ≥ 90% |
| `auto` berhasil | 0% | berfungsi |

Setelah ini, combo `free-then-local` berubah sifat: dari "satu provider gratis
lalu model lokal" menjadi rantai delapan provider dengan model lokal sebagai
dasar yang tidak bisa habis. Itu baru namanya kolam.

---

## L2 — Alihkan pekerjaan nyata ke kolam

**Jembatannya sudah terbukti dan belum dipakai.** Gerbang menyajikan Anthropic
Messages API di `/v1/messages`, dan diuji hari ini dari internet publik: balasan
dalam **1,3 detik**, `stop_reason: end_turn`, untuk provider gratis maupun combo.
Claude Code bisa memakainya lewat `ANTHROPIC_BASE_URL` tanpa lapisan penerjemah.

Yang hilang bukan plumbing, melainkan **pembagian kerja yang disengaja**. Tanpa
itu, semua tetap lewat Claude dan gerbang menganggur.

Pembagian yang masuk akal, berdasarkan apa yang terbukti bisa dilakukan kolam:

- **Ke kolam**: meringkas, mengklasifikasi, mengekstrak jadi JSON, menamai,
  menerjemahkan, boilerplate, draf pertama, pencarian pola.
- **Ke Claude**: penalaran berlapis, keputusan arsitektur, review yang
  konsekuensinya mahal, apa pun yang salahnya sulit terlihat.

| ukuran | sekarang | target |
|---|---|---|
| permintaan nyata lewat gerbang / minggu | ~0 | ratusan |
| pekerjaan receh yang masih memakai Claude | hampir semua | sedikit |

Ini tahap yang paling mengubah biaya, dan satu-satunya yang menuntut kebiasaan
baru dari Anda, bukan konfigurasi baru dari mesin.

---

## L3 — Satu infrastruktur, banyak proyek

Anda menyatakan proyek utama akan berada di direktori lain. Kalau KING hanya
melayani dirinya sendiri, biayanya ditanggung satu proyek. Kalau ia melayani
semua proyek Anda, biaya yang sama terbagi — dan itu definisi aset.

Tiga hal sudah siap dibagi dan satu belum:

- **Gerbang** — sudah publik dan ber-autentikasi. Proyek lain tinggal memakai
  kunci `/v1` sendiri, dan `call_logs.api_key_name` otomatis memisahkan
  trafiknya. Tidak ada pekerjaan.
- **Alur kerja** — Activepieces sudah melayani via MCP. Flow baru untuk proyek
  lain tidak menambah container.
- **Peta kode** — **belum**. Sekarang hanya mengindeks repo ini. graphify punya
  `global add` untuk grafik lintas-repo, jadi satu server MCP bisa menjawab
  pertanyaan tentang semua proyek Anda sekaligus. Ini pekerjaan nyata dan
  hasilnya langsung terasa.
- **Model lokal** — sudah otomatis terbagi lewat gerbang.

| ukuran | sekarang | target |
|---|---|---|
| proyek yang memakai gerbang | 1 | ≥ 2 |
| repo di peta kode | 1 | semua repo aktif |

---

## L4 — Bisa dipasang ulang dalam satu perintah

Aset yang hanya bisa dibangkitkan oleh orang yang membangunnya bukan aset,
melainkan ketergantungan. Saat ini memasang KING dari nol menuntut sejumlah
langkah manual yang tidak tertulis di satu tempat: mendaftarkan provider lewat
dashboard, membuat combo, memasang dua timer systemd, membuat kunci ber-scope,
menyalakan profil dalam urutan tertentu.

Beberapa di antaranya punya jebakan yang sudah menggigit — Base URL yang
tertinggal `localhost` menghasilkan koneksi yang tersimpan bersih dan gagal
dengan gejala identik "model mati".

`scripts/localmodel-register.sh` sudah membuktikan polanya: **skrip yang
menyetel, lalu menolak sukses tanpa bukti nyata.** Yang dibutuhkan adalah
saudaranya untuk seluruh stack.

| ukuran | sekarang | target |
|---|---|---|
| langkah manual dari VPS kosong ke stack jalan | belasan, sebagian tak tertulis | satu perintah |
| bisa dipulihkan orang lain tanpa sesi ini | tidak | ya |

---

## L5 — Skills bisa dipanggil dari alur kerja

Permintaan yang sudah dua kali Anda sampaikan dan belum terpenuhi.
`skills-lock.json` ada di repo dan **tidak dibaca oleh apa pun**; isi yang
dikuncinya justru gitignored.

OmniRoute sudah punya dua mekanismenya sendiri — **Omni Skills** sebagai mesin
eksekusi dan **Agent Skills** sebagai katalog — lengkap dengan
`POST /api/skills/collect` yang sumbernya persis format yang sudah tercatat di
lockfile itu. Sesuai prinsip Anda, jangan bangun yang sudah diselesaikan
OmniRoute; verifikasi semantik endpoint itu dulu, lalu pakai.

---

## Yang sengaja BUKAN prioritas

Ditulis supaya tidak diam-diam masuk lewat pintu belakang.

- **Model lokal yang lebih besar.** Diukur: menaikkan jatah CPU dari 1,0 ke 2,0
  vCPU tidak mengubah apa pun (9,7 → 9,9 token/detik). Hambatannya bandwidth
  memori, bukan inti. Model lebih besar hanya akan lebih lambat, dan 3B sudah
  terbukti 504 lewat gerbang. Jalan menuju jawaban lebih baik adalah **kolam
  yang lebih penuh**, bukan silikon yang sama dipaksa lebih keras.
- **Langfuse self-host.** Enam container tanpa satu pun batas sumber daya, di
  mesin dengan sisa 4,3 GB. Jejak sudah mengalir ke Langfuse Cloud.
- **Fitur baru apa pun sebelum L1 selesai.** Menambah kemampuan di atas kolam
  yang berisi dua provider adalah menambah permukaan tanpa menambah leverage.

---

## Urutan, dan alasannya

**L1 lebih dulu, dan jaraknya jauh.** Ia tidak butuh kode, memperbaiki success
rate dari 60%, menghidupkan kembali `auto`, dan mengubah setiap tahap
sesudahnya. Tanpa kolam yang penuh, L2 mengalihkan pekerjaan ke tempat yang
tidak sanggup menerimanya.

**L2 berikutnya**, karena di situlah penghematan token benar-benar terjadi, dan
plumbing-nya sudah terbukti hari ini.

**L3 dan L4 menyusul** — keduanya mengubah KING dari deployment menjadi aset,
tapi keduanya percuma kalau yang dibagikan dan direproduksi adalah kolam berisi
dua.

**L5 kapan saja**, karena ia berdiri sendiri.

Satu ukuran tunggal untuk menilai apakah rencana ini berhasil, dan sengaja bukan
jumlah fitur: **berapa persen pekerjaan receh Anda yang tidak lagi menyentuh
token Claude.** Hari ini angkanya mendekati nol.
