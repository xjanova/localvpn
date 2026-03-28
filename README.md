<p align="center">
  <img src="logo.png" alt="LocalVPN Logo" width="200" />
</p>

<h1 align="center">LocalVPN</h1>

<p align="center">
  <strong>Virtual LAN over the Internet</strong><br/>
  สร้างเครือข่ายเสมือน (Virtual LAN) ข้ามอินเทอร์เน็ตได้ทุกที่ทุกเวลา
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white" alt="Android" />
  <img src="https://img.shields.io/badge/framework-Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/backend-Laravel-FF2D20?logo=laravel&logoColor=white" alt="Laravel" />
  <img src="https://img.shields.io/badge/license-Proprietary-blue" alt="License" />
</p>

---

## Overview

LocalVPN turns your devices into a private virtual LAN — no matter where they are. Connect phones, tablets, and PCs into a single network over the internet with **P2P UDP hole punching**, **relay fallback**, and **BitTorrent-style file sharing**.

Think of it as **Hamachi + BitTorrent**, built for mobile.

---

## Features

### Networking
- **Virtual LAN** — Assign virtual IPs and communicate as if on the same local network
- **UDP Hole Punching** — Direct peer-to-peer connections through NAT with STUN discovery
- **Relay Fallback** — Automatic server relay when direct connection isn't possible
- **Room-based Networks** — Create or join networks with password protection

### File Sharing
- **Network-wide File Registry** — Share files visible to all members in the room
- **Multi-peer Swarm Download** — Download chunks from multiple seeders simultaneously (BitTorrent-style)
- **Auto-seeding** — Automatically seed files after downloading
- **Chunk Verification** — SHA-256 hash verification for data integrity

### VPN Proxy
- **Country Selection** — Choose which country to route through (JP, US, KR free — all countries for Premium)
- **VPN Gateway** — Premium host routes entire LAN through VPN — all members share the same exit IP
- **OpenVPN Integration** — Powered by VPN Gate public relay servers
- **Game Matchmaking** — LAN members exit from same IP for online game co-op (e.g., Arena Breakout)

### Security
- **License-based Authentication** — Device + license key validation
- **Encrypted Communication** — All signaling through HTTPS/WSS
- **Network Isolation** — Each room is a separate virtual network

### User Experience
- **Cyberpunk Glassmorphism UI** — Modern dark theme with neon accents
- **Real-time Status** — Live peer counts, transfer progress, and connection stats
- **Thai Language** — Full Thai language interface

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Flutter App                    │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ Network  │  │   P2P    │  │ File Transfer │  │
│  │ Service  │  │ Service  │  │   Service     │  │
│  └────┬─────┘  └────┬─────┘  └──────┬────────┘  │
│       │              │               │           │
│       └──────────────┼───────────────┘           │
│                      │                           │
│               ┌──────┴──────┐                    │
│               │  VPN Service │                   │
│               │  (TUN/UDP)   │                   │
│               └──────────────┘                   │
└──────────────────────┬──────────────────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   ┌────────────┐ ┌─────────┐ ┌─────────┐
   │   Server   │ │  STUN   │ │  Relay  │
   │  Registry  │ │ Endpoint│ │ Server  │
   │  (Laravel) │ │         │ │         │
   └────────────┘ └─────────┘ └─────────┘
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Mobile App** | Flutter (Dart) |
| **Backend** | Laravel (PHP) |
| **Database** | MySQL |
| **Networking** | UDP hole punching, STUN, Signaling server |
| **File Transfer** | BitTorrent-style chunked P2P swarm |
| **CI/CD** | GitHub Actions |
| **Hosting** | xmanstudio server |

---

## Project Structure

```
lib/
├── database/          # Local SQLite database
├── models/            # Data models (Network, Member, License, etc.)
├── screens/           # UI screens
│   ├── home_screen.dart
│   ├── network_list_screen.dart
│   ├── network_detail_screen.dart
│   ├── create_network_screen.dart
│   ├── file_transfer_screen.dart
│   ├── vpn_proxy_screen.dart      # VPN country selection UI
│   ├── settings_screen.dart
│   └── license_gate_screen.dart
├── services/          # Business logic
│   ├── network_service.dart       # Network join/leave/heartbeat
│   ├── p2p_service.dart           # UDP hole punching & STUN
│   ├── vpn_service.dart           # TUN interface & packet routing
│   ├── vpn_proxy_service.dart     # VPN Proxy (OpenVPN country bypass)
│   ├── file_transfer_service.dart # BitTorrent-style swarm transfer
│   ├── license_service.dart       # License validation
│   └── update_service.dart        # OTA updates
├── theme/             # Cyberpunk glassmorphism theme
└── widgets/           # Reusable UI components
```

---

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/v1/localvpn/networks` | Create a network |
| `POST` | `/api/v1/localvpn/networks/{slug}/join` | Join a network |
| `POST` | `/api/v1/localvpn/networks/{slug}/heartbeat` | Heartbeat (keep alive) |
| `GET` | `/api/v1/localvpn/stun` | STUN — discover public IP |
| `POST` | `/api/v1/localvpn/signal` | Send hole-punch signal |
| `POST` | `/api/v1/localvpn/signal/poll` | Poll pending signals |
| `POST` | `/api/v1/localvpn/files/share` | Share file to network |
| `GET` | `/api/v1/localvpn/files/{slug}` | List shared files |
| `DELETE` | `/api/v1/localvpn/files/{fileId}` | Remove shared file |
| `POST` | `/api/v1/localvpn/files/seed` | Register as seeder |
| `GET` | `/api/v1/localvpn/files/{fileId}/seeders` | Get file seeders |
| `GET` | `/api/v1/localvpn/proxy-servers` | VPN proxy server list (by country) |

---

## How It Works

### Network Creation
1. Host creates a room with a name and password
2. Server assigns a unique slug and subnet
3. Other devices join using the slug + password
4. Each member gets a virtual IP (e.g., `10.10.0.x`)

### P2P Connection
1. Device discovers its public IP via **STUN**
2. Signals are exchanged through the **signaling server**
3. **UDP hole punching** establishes direct P2P tunnels
4. If hole punch fails, traffic routes through the **relay server**

### File Sharing (BitTorrent-style)
1. Sender registers file metadata on the **server registry**
2. All network members see the file in their file list
3. Downloader requests **seeders list** from server
4. Chunks are requested from **multiple seeders** simultaneously
5. After download, the device **auto-registers as a new seeder**
6. File integrity verified via **SHA-256 hash**

---

## Freemium Model

| Feature | Free | Premium |
|---------|------|---------|
| Virtual LAN | Unlimited rooms | Unlimited rooms |
| Members per room | 5 | 50 |
| VPN Proxy countries | JP, US, KR | All countries |
| VPN Gateway (host routes LAN) | No | Yes |
| File sharing | Yes | Yes |
| WireGuard encryption | Yes | Yes |

---

## Getting Started

### Prerequisites
- Flutter SDK 3.10+
- Android Studio / VS Code
- Active license key

### Build & Run
```bash
# Clone the repository
git clone https://github.com/xjanova/localvpn.git
cd localvpn

# Install dependencies
flutter pub get

# Run on device
flutter run

# Build release APK
flutter build apk --release
```

---

## Screenshots

> Coming soon

---

<p align="center">
  Built with Flutter & Laravel<br/>
  <sub>Developed by <a href="https://github.com/xjanova">xjanova</a></sub>
</p>
