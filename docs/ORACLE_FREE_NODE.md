# ตั้งเซิร์ฟเวอร์ฟรี Oracle (สิงคโปร์) เป็นโหนดลดปิง/รีเลย์ของ LocalVPN

Oracle Cloud "Always Free" ให้ส่งข้อมูลออกได้ราว 10 TB/เดือน พอสำหรับทราฟฟิกเกม
(เกมใช้ประมาณ 30–80 MB ต่อชั่วโมงต่อคน) โดยไม่เสียเงิน ระบบหลังบ้านจะหยุดรับผู้ใช้
ก่อนถึงโควตาเอง

> เงื่อนไข free tier เปลี่ยนได้ — ตรวจหน้า https://www.oracle.com/cloud/free/ ก่อนสมัคร
> มีรายงานว่าเครื่อง ARM ของบัญชีฟรีอาจถูกลดเหลือ 2 OCPU / 12 GB — โหนดของเราใช้แค่ 1 OCPU ก็พอ

## 1. สมัคร (เจ้าของทำเอง)
1. สมัครที่ https://www.oracle.com/cloud/free/ (ต้องใช้บัตรยืนยันตัวตน ไม่ตัดเงินถ้าใช้แต่ของฟรี)
2. **Home Region: Singapore (ap-singapore-1)** — เลือกครั้งเดียว เปลี่ยนทีหลังไม่ได้
   และเครื่องฟรีสร้างได้เฉพาะใน home region

## 2. สร้างเครื่อง
Compute → Instances → Create instance
- Image: **Canonical Ubuntu 24.04** (หรือ 22.04)
- Shape: **VM.Standard.A1.Flex (Ampere)** 1 OCPU / 6 GB
  - ถ้าขึ้น "Out of capacity" ให้ลอง availability domain อื่น
    หรือใช้ **VM.Standard.E2.1.Micro** (AMD, ฟรีเหมือนกัน)
- SSH keys: สร้างใหม่แล้วดาวน์โหลด private key เก็บไว้
- Networking → ใช้ public IPv4 → หลังสร้างเสร็จให้เปลี่ยนเป็น **Reserved public IP**
  (ฟรี 1 IP) เพื่อไม่ให้ IP เปลี่ยนเวลารีสตาร์ท

## 3. เปิดพอร์ต UDP ในหน้า Oracle
Networking → Virtual Cloud Networks → (VCN ของเครื่อง) → Security Lists → Default →
Add Ingress Rules (Source CIDR `0.0.0.0/0`, IP Protocol **UDP**):
- Destination port **51821** — รีเลย์ LAN
- Destination port **51820** — WireGuard (ลดปิง)

(ไฟร์วอลล์ในตัวเครื่องของ Ubuntu บน Oracle ไม่ต้องแก้ — `lvnode` เปิดพอร์ตของมันเอง)

## 4. เพิ่มโหนดในหลังบ้าน
xman4289.com → Admin → LocalVPN → Fleet → Nodes → เพิ่มโหนด
- รหัสโหนด: `sg-oci-1` · ประเทศ: `SG` · เมือง: Singapore · ผู้ให้บริการ: Oracle
- Host: Reserved public IP จากข้อ 2
- บทบาท: **relay** และ **game**
- ปริมาณที่รวมในแพ็กเกจ (GB): `10000` · ค่าเช่ารายเดือน: `0` · ค่าส่วนเกิน: `0`
  · **ไม่ติ๊ก** อนุญาตส่วนเกิน · นับปริมาณแบบ: **out** (Oracle นับเฉพาะขาออก)
- ที่อยู่ exit / ซับเน็ต: `10.66.1.1/24` (โหนดต่อไปใช้ `10.66.2.1/24`, `10.66.3.1/24` …)
- บันทึก → **คัดลอกคำสั่งติดตั้ง (secret แสดงครั้งเดียว)**

และใน Fleet → Policy เพิ่มโปรไฟล์เกมอย่างน้อย 1 เกม (ช่วง IP ของเซิร์ฟเวอร์เกม +
จุดวัดปิง) ก่อนเปิดใช้โหนดลดปิง

## 5. ติดตั้งบนเครื่อง
ไฟล์อยู่ที่ `tools/lvnode/build/` ในเครื่องพัฒนา:
- เครื่อง ARM (A1.Flex): `lvnode-linux-arm64`
- เครื่อง AMD (E2.1.Micro): `lvnode-linux-x64`

```bash
scp -i <private-key> lvnode-linux-arm64 install.sh ubuntu@<IP>:~
ssh -i <private-key> ubuntu@<IP>
sudo bash install.sh --id <id> --secret <secret> --roles relay,game
```

ภายใน ~10 วินาที หน้า Nodes ต้องขึ้น "last seen" — ถ้าไม่ขึ้น ดู `journalctl -u lvnode -f`

## ให้ Claude ติดตั้งแทน
เพิ่ม SSH profile ของเครื่องนี้ในสมุดบันทึก (BrainX → ssh-profiles, user `ubuntu`, key ที่ดาวน์โหลดไว้)
แล้วบอก Claude — ทำข้อ 5 และตรวจผลให้ได้ทั้งหมด (ข้อ 1–4 ต้องเป็นบัญชีของเจ้าของ)
