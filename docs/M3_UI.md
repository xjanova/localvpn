# LocalVPN UI — "Millennium 3D" (same look as Anti X)

Glass panels, chrome and gold trim, Aero gloss buttons, glowing numbers, a
3D icon for every feature, two palettes (night = deep navy, sky = bright
Aero glass) switchable at runtime. Reference screens: `lib/screens/home_screen.dart`
and `lib/screens/devices_screen.dart`. Read both before building a screen.

## Rebuild, don't recolour

A redesigned screen must have a **new layout built from the kit**, not the old
Material layout with new colours (that mistake was made once on SmsChecker and
the owner rejected it). Old widgets are deleted at the end — never import:
`theme/app_theme.dart` (`AppColors`, `AppTheme`), `widgets/glass_card.dart`,
`neon_button.dart`, `cyber_page_route.dart`, `status_indicator.dart`,
`network_card.dart`, `member_tile.dart`, `latency_gauge.dart`,
`vpn_mascot.dart`, `animated_background.dart`, `google_fonts`.

## Import

```dart
import '../widgets/m3/m3.dart';          // whole kit + theme
import 'shell/app_services.dart';         // AppServices
import 'shell/app_shell.dart';            // AppShellScope, ShellTab, ShellBadges
```

## Colours and text

- Colours come only from `context.m3` (an `M3Palette`): `text`, `text2`,
  `text3`, `numText`, `cyan`, `gold`, `green`, `amber`, `red`, `violet`,
  `line`, `inset`, `hover`, `select`, `track`, `input`, `popup`… Soft status
  fills: `p.toneSoft(M3Tone.x)`, `p.toneSoftLine(..)`, `p.toneText(..)`,
  `p.toneColor(..)`. Never hard-code a colour that must differ between night
  and sky. Gradients that are the same in both: `M3Fx.aquaGloss`, `goldGloss`,
  `redGloss`, `greenGloss`, `btnGloss`, `goldRing`, `goldLine`, `chrome`,
  `barAqua`…
- Text: `M3Text.h1(context)` page title (Kanit 26), `h2` card title (Kanit 16),
  `h3` row title, `body`, `sub` (muted 12.5), `label` (field labels),
  `num(context, size:, color:)` glowing numbers, `mono(context)` for IPs,
  keys, ports (JetBrains Mono + Thai fallback), `eyebrow` (Latin only).
- **Never set `letterSpacing` on Thai text** (vowels and tone marks detach).
- Fonts: `M3Fonts.head` (Kanit), `M3Fonts.ui` (Anuphan), `M3Fonts.mono`.

## Kit (lib/widgets/m3)

| Widget | Use |
|---|---|
| `M3PageBody(children:, onRefresh:)` | Scrollable page with standard padding and max width 1180. Use for every tab root and pushed page. |
| `M3PageHeader(icon3d:, title:, subtitle:, trailing:, onBack:)` | Top of every page. Tab roots: `trailing: const ShellBadges()`. Pushed pages: `onBack: () => Navigator.of(context).pop()`. |
| `GlassPanel(child:, onTap:, highlight:, gloss:, accent:, radius:, padding:)` | The card. `highlight: true, gloss: false` for the one hero card per page. `accent:` tints the edge (green connected, red error). |
| `M3CardHeader(icon3d:, title:, subtitle:, trailing:)` | Title row inside a card. |
| `M3SectionTitle('…', trailing:)` | Heading between cards. |
| `GlossButton(label:, onPressed:, variant:, size:, icon:, icon3d:, loading:, expand:)` | Buttons. `aqua` = primary (gold ring), `gold` = buy/upgrade, `red` = destructive (gold ring), `green` = confirm/accept, `glass` = secondary. Rounded rectangles only — **no pill/oval buttons, chips or badges** (owner rule). |
| `GlossIconButton(icon:, onPressed:, tooltip:)` | Small square glass icon button (refresh, copy, more). |
| `Icon3D(M3Icons.x, size:, glow:, opacity:)` | 3D icons. Use for every feature/section/state/empty state. Material `Icon` only for tiny inline glyphs (copy, arrow, close, inside buttons). |
| `M3StatTile(label:, value:, icon3d:, sub:, tone:)` | Number tiles. |
| `M3Row(leading:, title:, subtitle:/subtitleWidget:, trailing:, onTap:, selected:)` | List rows inside cards (hover highlight). |
| `M3KeyValue('label', 'value', mono:)` | Key/value lines. |
| `M3Inset(child:)` | Recessed box inside a card (readouts, code, keys). |
| `M3Tag('text', tone:, dot:, icon:)` | Small status tags (radius 7). |
| `M3Count(n)` | Aqua count badge. |
| `M3Chip(label:, selected:, onTap:)` | Filter chips (glass → aqua when selected). |
| `M3Switch` / `M3SwitchRow(title:, subtitle:, value:, onChanged:, icon3d:)` | Toggles (glass track, chrome knob). |
| `M3Field(controller:, label:, hint:, obscure:, prefixIcon:, mono:, validator:)` | Text inputs (themed `TextFormField`). |
| `M3Banner(tone:, title:, message:, icon3d:, action:)` | In-page notice. |
| `M3ProgressBar(value:, tone:)` | Glass tube progress (null = indeterminate). |
| `StatusOrb(color:, size:, pulse:)` | Online/connected dot (round is allowed here). |
| `M3EmptyState(icon3d:, title:, message:, action:)` | Empty/error/loading states with floating icon. |
| `ProBadge(kind:, main:, sub:, onTap:)` | Licence badge (gold PRO / silver FREE / red). |
| `showM3Dialog(...)`, `m3Confirm(...)`, `m3Toast(...)`, `showM3Sheet(...)` | Dialogs, yes/no (**every delete/overwrite/leave/reset needs `m3Confirm`**), snackbars, bottom sheets. Don't use raw `AlertDialog`/`SnackBar`. |
| `M3PageRoute(builder:)` | Every `Navigator.push`. |
| `M3GoldLine()` | Gold hairline divider. |

3D icons (`M3Icons.*`): `networks, createNetwork, scan, members, fileTransfer,
torrent, vpnProxy, gameBoost, ping, smartRoute, p2pDirect, relay, upload,
download, leaderboard, trophy, folder, file, profile, kyc, crown, update,
lock, qr, settings, power, invite, adapter, devicePc, devicePhone, logo`.

## Layout rules

- The shell paints the wallpaper and (on Windows) the title bar and sidebar.
  Screens are transparent: no `Scaffold` background colour, no gradients behind
  the page, no `SafeArea` at the top of tab roots (the shell handles it). A
  pushed page may use `Scaffold(backgroundColor: Colors.transparent, body: …)`
  when it needs a `ScaffoldMessenger`/FAB; otherwise return `M3PageBody`.
- Must work from 360 px wide (phone) to 1900 px (desktop). Use `LayoutBuilder`/
  `MediaQuery.sizeOf(context).width`: one column under ~700 px, 2–3 columns
  or a side-by-side layout on wide screens (see home `_StatGrid`, devices grid).
- Page structure: header → (banners) → one hero `GlassPanel(highlight)` →
  content cards. Card padding 16–22, gaps 14–16, radius 20 (hero 24).
- Desktop: hover states come from the kit; give clickable custom things a
  `MouseRegion(cursor: SystemMouseCursors.click)`.
- Animations: light `flutter_animate` fade/slide on entry (≤ 350 ms), no
  endless animations except status orbs and empty-state icons.

## Behaviour rules (non-negotiable)

- Keep every feature and service call the screen has today. Only the
  presentation changes. Read the old screen fully before rewriting it.
- `if (!mounted) return;` before any `setState`/`context` use after an `await`.
- Dispose controllers, listeners, timers, subscriptions.
- Errors shown to users are Thai and friendly — never a raw `Exception:` or
  stack text; services' `error` strings may be shown as-is.
- Loading: full-page spinner only on the first load; refreshes keep content
  on screen (use a small inline indicator).
- Double taps: disable buttons while their action runs (`loading:` / null
  `onPressed`).
- Platform: import `platform/platform_info.dart` → `isWindows`, `isMobile`,
  `canScanQr`. QR scanning (`mobile_scanner`) exists only on phones — on
  Windows hide the scan button and offer typing/pasting instead. File
  pickers and `open_file` work on Windows.
- User text copy is Thai. Keep the old screen's wording unless it's clearly
  wrong; English only for product names and technical terms (IP, P2P, VPN).

## Constructors (the shell already calls these)

Tab roots take `({super.key, required AppServices services})`:
`NetworkListScreen`, `VpnProxyScreen`, `FileTransferScreen`,
`GlobalTorrentScreen`, `SettingsScreen` (`HomeScreen`, `DevicesScreen`,
`GameBoostScreen` are done). `AppServices` fields: `license`, `network`,
`vpn`, `p2p`, `files`, `torrent`, `proxy`, `update`, `boost`.
`NetworkDetailScreen({required AppServices services, required VpnNetwork network})`.
Other pushed screens: pass `services` (or the specific services) — update the
call sites inside your own files.

Tab switching from anywhere: `AppShellScope.of(context).goTo(ShellTab.x)`.
Windows elevation: `AppShellScope.of(context).isElevated`,
`.relaunchAsAdmin()`. Theme: `M3ThemeController.instance` (`isNight`,
`setNight(bool)`).

## Check your work

`flutter analyze <your files>` must report no errors or warnings (infos are
OK). Do not run `flutter pub get/upgrade`, do not edit files outside your
assignment, do not touch the kit; put any extra widget you need as a private
class in your screen file.
