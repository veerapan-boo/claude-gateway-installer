# claude-gateway-installer (ภาษาไทย)

ตัวติดตั้งแบบ interactive **CLI ล้วน** ที่เปลี่ยนเครื่อง **Linux** หรือ **macOS**
เครื่องไหนก็ได้ ให้เป็น Claude Code Gateway — ใช้ Claude Code CLI บนเครื่องของเราเอง
ทุกเครื่อง ด้วย Claude subscription บัญชีเดียว ผ่าน public HTTPS

ตัวติดตั้งจะ**ตรวจเครื่องของเราก่อนดาวน์โหลดอะไรทั้งนั้น** ตรวจ OS และ CPU
ดาวน์โหลด CLIProxyAPI build ที่ถูกต้อง (ไม่ต้องใช้ Docker แล้ว) แล้วพาเรา
ทำขั้นตอนที่เหลือไม่กี่ขั้น: login Claude (paste-back ใช้ได้กับเครื่องไม่มีจอ),
ตั้ง Cloudflare Tunnel, และ start gateway ทุกอย่างรันผ่าน terminal
ไม่ต้องมี browser บนเครื่อง gateway

```bash
cd claude-gateway-installer
bash install.sh
```

repo นี้มี**จุดเข้าเดียวคือ `install.sh`** ไฟล์อื่นทั้งหมดอยู่ใน `lib/`
พอเลือก Install directory เสร็จ ตัวติดตั้งจะ**คัดลอกสคริปต์จัดการ**
(`gateway.sh`, `claude-login.sh`, `lib/common.sh`) ไปไว้ใน directory นั้น
ดังนั้น**งานจัดการประจำวันทั้งหมดทำจาก install directory** (ค่าเริ่มต้น
`~/claude-gateway`) ไม่ต้องกลับมาที่ repo นี้อีก

## สิ่งที่ต้องเตรียมก่อน

| ข้อกำหนด | รายละเอียด |
|---|---|
| เครื่องที่เปิดทิ้งไว้ได้ (VPS, โฮมเซิร์ฟเวอร์, Mac) | Linux ที่มี systemd หรือ macOS |
| domain บน Cloudflare | เช่น `example.com` — ใช้เป็น `claude-gateway.example.com` |
| Claude subscription | แผนใดก็ได้ที่ใช้ API ได้ (gateway เข้าถึง API ด้วยบัญชีของเราเอง) |
| สิทธิ์ `sudo` | ใช้ตอนติดตั้ง service / cloudflared เท่านั้น |

## Step 1 — ตรวจเครื่อง (ยังไม่ดาวน์โหลด)

ก่อนดาวน์โหลดอะไร ตัวติดตั้งเช็คให้ก่อน:

- OS / สถาปัตยกรรม CPU (รองรับ `linux_amd64`, `linux_aarch64`,
  `darwin_amd64`, `darwin_aarch64`)
- คำสั่งที่ต้องมี (`bash`, `curl`, `openssl`, `tar`)
- เน็ตไปถึง `github.com` ได้ไหม
- service manager (`systemd` บน Linux, `launchctl` บน macOS)
- พอร์ตของ gateway (ค่าเริ่มต้น `8317`) ว่างไหม — ถ้ามีโปรแกรมอื่นใช้อยู่
  ให้เลือก kill โปรแกรมนั้นแล้วลงต่อ หรือหยุดได้
- สิทธิ์ `sudo` มีไหม และ `cloudflared` ติดตั้งอยู่แล้วหรือยัง

ถ้ามีอะไรขาด ตัวติดตั้งจะบอก**ก่อนจะดาวน์โหลดแม้แต่ไบต์เดียว**

## Steps 2–6

2. **ดาวน์โหลด** CLIProxyAPI native build ที่ถูกต้องกับ OS/arch
3. **สร้าง key + config** — สุ่ม API key 256-bit ให้แต่ละเครื่องที่เราตั้งชื่อ
   (เช่น `laptop,work-desktop,macbook`) แล้วเขียน `config.yaml`
4. **Claude login** — แบบ paste-back (CLI):
   - ตัวติดตั้งพิมพ์ `https://claude.ai/oauth/authorize?...`
   - เปิดลิงก์นั้นใน browser **เครื่องไหนก็ได้** (แล็ปท็อป, มือถือ)
     login ด้วยบัญชี subscription แล้วกด Authorize
   - browser เด้งไปที่ `http://localhost:54545/callback?code=...&state=...`
     (หน้าโหลดไม่ขึ้น = ปกติ)
   - copy URL เต็ม ๆ กลับมา — ต้องมีทั้ง `code` และ `state` — แล้ววางตรงนี้
     ไม่ต้องใช้ tmux
5. **Cloudflare Tunnel** — ตรวจว่า `cloudflared` มีอยู่แล้วไหม และมี tunnel
   รันอยู่แล้วไหม แล้วให้เลือก:
   - **Use existing tunnel** — โชว์ tunnel id + hostnames ที่ serve อยู่ทันที;
     ถ้าเป็น config-file tunnel จะเสนอ add hostname ใหม่ → `localhost:<port>`
     เข้า config + restart ให้ (sudo — กรอกรหัสเอง) โดยถาม public URL
     **หลัง**เลือก tunnel เพื่อให้เข้ากับ tunnel ที่เลือก
   - **Create a new tunnel** — วาง token จาก dashboard ใช้ได้ทุกเครื่อง
     (รวมถึงเครื่องไม่มีจอ) และ **ไม่ต้อง login cloudflared บนเครื่อง**
     เพราะ token พก tunnel + credential ครบ; `cloudflared` ลง service ให้เอง
   - **Skip** — จัดการ tunnel / VPN เอง
6. **Start gateway** — ลงเป็น background service
   (Linux → systemd `cliproxyapi.service`; macOS → LaunchAgent)
   เช็ค `127.0.0.1:8317` และ URL สาธารณะ แล้วพิมพ์ env var ให้แต่ละเครื่อง

## หลังติดตั้ง — บนเครื่อง client แต่ละเครื่อง

```bash
npm install -g @anthropic-ai/claude-code

export ANTHROPIC_BASE_URL="https://claude-gateway.example.com"
export ANTHROPIC_AUTH_TOKEN="<key-เฉพาะเครื่องเรา>"
unset ANTHROPIC_API_KEY
```

key ถูกพิมพ์ตอนจบตัวติดตั้ง และเก็บไว้ที่ `~/claude-gateway/secrets/keys.txt`

## คำสั่งใช้งานประจำวัน

รัน **จาก install directory** (ค่าเริ่มต้น `~/claude-gateway`) ที่ตัวติดตั้ง
คัดลอกสคริปต์ไว้ให้:

```bash
~/claude-gateway/gateway.sh list          # รายชื่อ gateway ทั้งหมดที่ติดตั้ง (port, running, keys, oauth)
~/claude-gateway/gateway.sh status        # รันอยู่ไหม?
~/claude-gateway/gateway.sh logs tail     # ดู log แบบสด (journalctl บน Linux)
~/claude-gateway/gateway.sh restart
~/claude-gateway/gateway.sh uninstall     # ถอด service + ลบ directory ตัวนี้ (ถามก่อนลบ)
~/claude-gateway/gateway.sh uninstall <dir>   # uninstall instance ที่ระบุตาม path
~/claude-gateway/claude-login.sh          # re-login เมื่อ OAuth token หมดอายุ (~60–90 วัน)
```

(ถ้าติดตั้งไว้ที่อื่น ให้เปลี่ยน `~/claude-gateway` เป็น directory ที่ติดตั้ง)

## Re-login (เมื่อ OAuth token หมดอายุ)

OAuth token ที่ gateway ใช้จะหมดอายุประมาณทุก **60–90 วัน** สังเกตจาก:
เครื่อง client ตอบ `401` ทั้งที่ gateway รันปกติและ healthy

วิธี re-login — บน **เครื่อง gateway** รันสคริปต์จาก install directory:

```bash
~/claude-gateway/claude-login.sh
```

เป็น paste-back flow เดิม:
1. เปิด `https://claude.ai/oauth/authorize?...` ที่พิมพ์ออกมา ใน browser
   ไหนก็ได้ → login บัญชี subscription → Authorize
2. browser เด้งไปที่ URL `localhost` (หน้าโหลดไม่ขึ้น = ปกติ)
3. copy URL เต็ม ๆ กลับมา — ต้องมีทั้ง `code` และ `state`
   เช่น `http://localhost:54545/callback?code=xxxxx&state=yyyyy` — วางลง terminal
4. พอขึ้นว่า authentication successful ให้ restart gateway:

```bash
~/claude-gateway/gateway.sh restart
```

แล้วลองบนเครื่อง client: `claude` ควรกลับมาใช้ได้

## หมายเหตุ

- ตัวติดตั้ง **รันซ้ำได้**: รันใหม่จะ reuse binary, key และ `config.yaml`
  (และอ่านพอร์ตจาก config เดิมให้)
- **ติดตั้งหลาย gateway ได้**: แต่ละ install directory มี service identity
  ของตัวเอง (label macOS / ชื่อ unit systemd มาจากชื่อ directory เช่น
  `~/claude-gateway-second` → `com.claude-gateway.cliproxyapi.claude-gateway-second`)
  `gateway.sh` ที่รันจากใน install dir (หรือตั้ง `INSTALL_DIR=<dir>`)
  จะจัดการเฉพาะ instance นั้น และ `gateway.sh uninstall` ลบเฉพาะ
  instance + directory ของตัวเอง ส่วน `~/claude-gateway` ตัวแรกยังใช้ชื่อเดิม
  `com.claude-gateway.cliproxyapi` / `cliproxyapi.service`
- key อยู่ที่ `~/claude-gateway/secrets/keys.txt` และอยู่ใน
  `~/claude-gateway/cliproxyapi/config.yaml` ต้องการเพิกถอนเครื่องไหน
  ให้ลบ key นั้นออกจาก `api-keys:` ใน config (CLIProxyAPI reload ให้อัตโนมัติ)
- ถ้า `claude-gateway.example.com` ตอบ `401` แปลว่า OAuth token หมดอายุ
  ดูหัวข้อ [Re-login](#re-login-เมื่อ-oauth-token-หมดอายุ) ด้านบน

## โครงสร้างไฟล์

```
claude-gateway-installer/
├── install.sh              # ตัวติดตั้งแบบ interactive (ไฟล์เดียวที่ต้องรัน)
└── lib/
    ├── setup-tunnel.sh     # ตรวจ + ตั้ง Cloudflare Tunnel (รันโดย install.sh)
    ├── claude-login.sh     # Claude OAuth login (CLI paste-back) — คัดลอกไป install dir
    ├── gateway.sh          # status | start | stop | restart | logs | uninstall | list — คัดลอกไป install dir
    ├── common.sh           # helper ร่วม (ตรวจ OS/arch, prompt) — คัดลอกไป install dir
    └── install-service.sh  # ติดตั้ง service systemd / LaunchAgent
```

หลังติดตั้ง directory ที่เลือกจะมีไฟล์ที่ใช้งานจริง:

```
~/claude-gateway/
├── gateway.sh              # status | start | stop | restart | logs | uninstall | list
├── claude-login.sh         # re-login เมื่อ OAuth token หมดอายุ
├── lib/common.sh           # helper ร่วม (อย่าแก้)
├── cliproxyapi/            # binary gateway + config.yaml + auth/ (OAuth token)
└── secrets/keys.txt        # per-device API key ของเรา
```