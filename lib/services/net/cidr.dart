/// IPv4 CIDR helpers for building WireGuard AllowedIPs lists.
class Cidr {
  final int network; // host byte order, masked
  final int prefix;

  Cidr(int address, this.prefix)
      : network = prefix == 0 ? 0 : address & _mask(prefix);

  static int _mask(int prefix) =>
      prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

  static Cidr? parse(String text) {
    final parts = text.trim().split('/');
    final ip = ipToInt(parts[0]);
    if (ip == null) return null;
    final prefix = parts.length > 1 ? int.tryParse(parts[1]) : 32;
    if (prefix == null || prefix < 0 || prefix > 32) return null;
    return Cidr(ip, prefix);
  }

  static int? ipToInt(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    var v = 0;
    for (final p in parts) {
      final o = int.tryParse(p);
      if (o == null || o < 0 || o > 255) return null;
      v = (v << 8) | o;
    }
    return v;
  }

  static String intToIp(int v) =>
      '${(v >> 24) & 255}.${(v >> 16) & 255}.${(v >> 8) & 255}.${v & 255}';

  int get last => network | (~_mask(prefix) & 0xFFFFFFFF);

  bool contains(Cidr other) =>
      other.prefix >= prefix && (other.network & _mask(prefix)) == network;

  bool overlaps(Cidr other) => contains(other) || other.contains(this);

  @override
  String toString() => '${intToIp(network)}/$prefix';

  /// Every IPv4 address except [excluded], as the smallest set of CIDRs.
  /// Never returns a /0, so WireGuard for Windows does not switch on its
  /// "block untunneled traffic" firewall (which would cut the LAN and the
  /// virtual LAN off).
  static List<Cidr> allExcept(Iterable<Cidr> excluded) {
    var ranges = <Cidr>[Cidr(0, 0)];
    for (final ex in excluded) {
      final next = <Cidr>[];
      for (final r in ranges) {
        next.addAll(_subtract(r, ex));
      }
      ranges = next;
    }
    // Split a lone /0 (nothing excluded) into two halves for the same reason.
    if (ranges.length == 1 && ranges.first.prefix == 0) {
      return [Cidr(0, 1), Cidr(0x80000000, 1)];
    }
    ranges.sort((a, b) => a.network.compareTo(b.network));
    return ranges;
  }

  static List<Cidr> _subtract(Cidr range, Cidr ex) {
    if (!range.overlaps(ex)) return [range];
    if (ex.contains(range)) return const [];
    // range strictly contains ex: split range in halves, keep subtracting.
    final half = range.prefix + 1;
    final lo = Cidr(range.network, half);
    final hi = Cidr(range.network | (1 << (32 - half)), half);
    return [..._subtract(lo, ex), ..._subtract(hi, ex)];
  }

  /// Private, link-local, loopback, CGNAT and multicast space: traffic that
  /// must stay on the local network (home LAN, the LocalVPN virtual LAN).
  static final List<Cidr> localRanges = [
    for (final c in const [
      '0.0.0.0/8',
      '10.0.0.0/8',
      '100.64.0.0/10',
      '127.0.0.0/8',
      '169.254.0.0/16',
      '172.16.0.0/12',
      '192.168.0.0/16',
      '224.0.0.0/4',
      '240.0.0.0/4',
    ])
      Cidr.parse(c)!,
  ];

  /// AllowedIPs that send all internet traffic through the tunnel but keep
  /// local traffic local. [bypass] adds hosts that must stay outside the
  /// tunnel (e.g. the WireGuard endpoint itself).
  static String internetOnlyAllowedIps({Iterable<String> bypass = const []}) {
    final ex = [
      ...localRanges,
      for (final b in bypass)
        if (Cidr.parse(b) case final c?) c,
    ];
    return allExcept(ex).map((c) => c.toString()).join(', ');
  }
}
