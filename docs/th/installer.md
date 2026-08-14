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

1. **ดาวน์โหลด** CLIProxyAPI native build ที่ถูกต้องกับ OS/arch
2. **สร้าง key + config** — สุ่ม API key 256-bit ให้แต่ละเครื่องที่เราตั้งชื่อ
   (เช่น `laptop,work-desktop,macbook`) แล้วเขียน `config.yaml`
3. **Claude login** — แบบ paste-back (CLI):
   - ตัวติดตั้งพิมพ์ `https://claude.ai/oauth/authorize?...`
   - เปิดลิงก์นั้นใน browser **เครื่องไหนก็ได้** (แล็ปท็อป, มือถือ)
     login ด้วยบัญชี subscription แล้วกด Authorize
   - browser เด้งไปที่ `http://localhost:54545/callback?code=...`
     (หน้าโหลดไม่ขึ้น = ปกติ)
   - copy URL เต็ม ๆ นั้นกลับมาวางตรงนี้ ไม่ต้องใช้ tmux
4. **Cloudflare Tunnel** — ตรวจว่า `cloudflared` มีอยู่แล้วไหม และมี tunnel
   รันอยู่แล้วไหม แล้วให้เลือก:
   - **1 · tunnel เดิม** — แค่เพิ่ม public hostname ใน dashboard
   - **B · สร้าง tunnel ใหม่จาก token ใน dashboard** — แนะนำ ใช้ได้ทุกเครื่อง
     (รวมถึงเครื่องไม่มีจอ); `cloudflared` ลงเป็น background service ให้เอง
   - **s · ข้าม** — จัดการ tunnel เอง
5. **Start gateway** — ลงเป็น background service
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

```bash
./gateway.sh status       # รันอยู่ไหม?
./gateway.sh logs tail    # ดู log แบบสด (journalctl บน Linux)
./gateway.sh restart
./claude-login.sh         # re-login เมื่อ OAuth token หมดอายุ (~60–90 วัน)
```

## หมายเหตุ

- ตัวติดตั้ง **รันซ้ำได้**: รันใหม่จะ reuse binary, key และ `config.yaml`
  (และอ่านพอร์ตจาก config เดิมให้)
- key อยู่ที่ `~/claude-gateway/secrets/keys.txt` และอยู่ใน
  `~/claude-gateway/cliproxyapi/config.yaml` ต้องการเพิกถอนเครื่องไหน
  ให้ลบ key นั้นออกจาก `api-keys:` ใน config (CLIProxyAPI reload ให้อัตโนมัติ)
- ถ้า `claude-gateway.example.com` ตอบ `401` แปลว่า OAuth token หมดอายุ
  วิ่ง `./claude-login.sh` แล้ว restart service

## โครงสร้างไฟล์

```
claude-gateway-installer/
├── install.sh              # ตัวติดตั้งแบบ interactive
├── claude-login.sh         # Claude OAuth login (CLI paste-back)
├── setup-tunnel.sh         # ตรวจ + ตั้ง Cloudflare Tunnel
├── gateway.sh              # status | start | stop | restart | logs
└── lib/
    ├── common.sh           # helper ร่วม (ตรวจ OS/arch, prompt)
    └── install-service.sh  # ติดตั้ง service systemd / LaunchAgent
```