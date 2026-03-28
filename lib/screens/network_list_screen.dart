import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/network.dart';
import '../services/license_service.dart';
import '../services/network_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cyber_page_route.dart';
import '../widgets/network_card.dart';
import 'create_network_screen.dart';
import 'network_detail_screen.dart';

class NetworkListScreen extends StatefulWidget {
  final NetworkService networkService;
  final LicenseService licenseService;

  const NetworkListScreen({
    super.key,
    required this.networkService,
    required this.licenseService,
  });

  @override
  State<NetworkListScreen> createState() => _NetworkListScreenState();
}

class _NetworkListScreenState extends State<NetworkListScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadNetworks();
    widget.networkService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    widget.networkService.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _loadNetworks() async {
    await widget.networkService.listNetworks();
    if (mounted) {
      setState(() => _hasLoaded = true);
    }
  }

  List<VpnNetwork> get _filteredNetworks {
    if (_searchQuery.isEmpty) return widget.networkService.publicNetworks;
    final query = _searchQuery.toLowerCase();
    return widget.networkService.publicNetworks
        .where((n) =>
            n.name.toLowerCase().contains(query) ||
            (n.description?.toLowerCase().contains(query) ?? false))
        .toList();
  }

  Future<void> _joinNetwork(VpnNetwork network) async {
    if (!network.isPublic) {
      final password = await _showPasswordDialog();
      if (password == null) return;

      final success = await widget.networkService
          .joinNetwork(network.slug, password: password);
      if (!mounted) return;

      if (success) {
        SoundService().play(SfxType.success);
        HapticFeedback.heavyImpact();
        _navigateToDetail(network);
      } else {
        SoundService().play(SfxType.error);
        _showError(widget.networkService.error ?? 'ไม่สามารถเข้าร่วมได้');
        widget.networkService.clearError();
      }
    } else {
      final success =
          await widget.networkService.joinNetwork(network.slug);
      if (!mounted) return;

      if (success) {
        SoundService().play(SfxType.success);
        HapticFeedback.heavyImpact();
        _navigateToDetail(network);
      } else {
        SoundService().play(SfxType.error);
        _showError(widget.networkService.error ?? 'ไม่สามารถเข้าร่วมได้');
        widget.networkService.clearError();
      }
    }
  }

  Future<String?> _showPasswordDialog() async {
    SoundService().play(SfxType.notification);
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'เครือข่ายส่วนตัว',
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            obscureText: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'กรอกรหัสผ่าน',
              prefixIcon: Icon(Icons.lock, color: AppColors.primary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                SoundService().play(SfxType.tap);
                Navigator.pop(ctx);
              },
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton(
              onPressed: () {
                SoundService().play(SfxType.tapHeavy);
                final pwd = controller.text.trim();
                Navigator.pop(ctx, pwd.isNotEmpty ? pwd : null);
              },
              child: const Text('เข้าร่วม'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  void _navigateToDetail(VpnNetwork network) {
    final currentNetwork = widget.networkService.currentNetwork;
    if (currentNetwork != null) {
      Navigator.of(context).push(
        CyberPageRoute(
          builder: (_) => NetworkDetailScreen(
            networkService: widget.networkService,
            network: currentNetwork,
          ),
        ),
      ).then((_) => _loadNetworks());
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error.withValues(alpha: 0.9),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final networks = _filteredNetworks;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: const Text(
                    'เครือข่าย',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ).animate().fadeIn(duration: 300.ms),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: const Icon(
                      Icons.add,
                      color: AppColors.primary,
                    ),
                    onPressed: () {
                      SoundService().play(SfxType.tap);
                      Navigator.of(context).push(
                        CyberPageRoute(
                          builder: (_) => CreateNetworkScreen(
                            networkService: widget.networkService,
                            licenseService: widget.licenseService,
                          ),
                        ),
                      ).then((_) => _loadNetworks());
                    },
                  ),
                )
                    .animate()
                    .fadeIn(duration: 300.ms, delay: 100.ms)
                    .scale(
                      begin: const Offset(0.8, 0.8),
                      end: const Offset(1, 1),
                      duration: 300.ms,
                      delay: 100.ms,
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'ค้นหาเครือข่าย...',
                prefixIcon:
                    const Icon(Icons.search, color: AppColors.textMuted),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(
                          Icons.clear,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ).animate().fadeIn(duration: 300.ms, delay: 150.ms),
          const SizedBox(height: 16),
          Expanded(
            child: widget.networkService.isLoading && !_hasLoaded
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'กำลังโหลด...',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  )
                : networks.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        color: AppColors.primary,
                        backgroundColor: AppColors.surface,
                        onRefresh: _loadNetworks,
                        child: ListView.builder(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: networks.length,
                          itemBuilder: (context, index) {
                            final network = networks[index];
                            return NetworkCard(
                              network: network,
                              index: index,
                              onTap: () => _joinNetwork(network),
                              onJoin: () => _joinNetwork(network),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.wifi_tethering_off,
            size: 64,
            color: AppColors.textMuted.withValues(alpha: 0.5),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .moveY(begin: 0, end: -8, duration: 2500.ms)
              .fadeIn(duration: 400.ms),
          const SizedBox(height: 16),
          const Text(
            'ไม่พบเครือข่าย',
            style: TextStyle(
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'สร้างเครือข่ายใหม่หรือลองค้นหาอีกครั้ง',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () {
              SoundService().play(SfxType.tap);
              Navigator.of(context).push(
                CyberPageRoute(
                  builder: (_) => CreateNetworkScreen(
                    networkService: widget.networkService,
                    licenseService: widget.licenseService,
                  ),
                ),
              ).then((_) => _loadNetworks());
            },
            icon: const Icon(Icons.add),
            label: const Text('สร้างเครือข่าย'),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms);
  }
}
