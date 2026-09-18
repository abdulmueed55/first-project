import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IescoMeterApp());
}

class IescoMeterApp extends StatelessWidget {
  const IescoMeterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IESCO Meter Live',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1456A0)),
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      ),
      home: const RootScreen(),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with WidgetsBindingObserver {
  int index = 0;
  bool syncing = true;
  bool iescoOnline = false;
  bool powerSmartOnline = false;
  DateTime? lastSync;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sync();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => sync());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }

  Future<bool> ping(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'IESCO-Meter-Live/0.1');
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> sync() async {
    if (!mounted) return;
    setState(() => syncing = true);
    final values = await Future.wait([
      ping('https://www.iesco.com.pk/'),
      ping('https://api-powersmart.pitc.com.pk/'),
    ]);
    if (!mounted) return;
    setState(() {
      iescoOnline = values[0];
      powerSmartOnline = values[1];
      lastSync = DateTime.now();
      syncing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      Dashboard(
        syncing: syncing,
        iescoOnline: iescoOnline,
        powerSmartOnline: powerSmartOnline,
        lastSync: lastSync,
        onRefresh: sync,
      ),
      const HistoryPage(),
      const BillPage(),
    ];
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) => setState(() => index = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.query_stats_outlined), selectedIcon: Icon(Icons.query_stats), label: 'History'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Bill'),
        ],
      ),
    );
  }
}

class Dashboard extends StatelessWidget {
  final bool syncing;
  final bool iescoOnline;
  final bool powerSmartOnline;
  final DateTime? lastSync;
  final Future<void> Function() onRefresh;
  const Dashboard({
    super.key,
    required this.syncing,
    required this.iescoOnline,
    required this.powerSmartOnline,
    required this.lastSync,
    required this.onRefresh,
  });

  String syncText() {
    final d = lastSync;
    if (d == null) return 'Not synced yet';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return 'Last sync ' + d.day.toString() + '/' + d.month.toString() + '/' + d.year.toString() + ' ' + h + ':' + m;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('IESCO Meter Live', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 3),
              const Text('Automatic smart-meter dashboard'),
            ])),
            syncing
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : IconButton(onPressed: onRefresh, icon: const Icon(Icons.sync_rounded)),
          ]),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF0F4C91), Color(0xFF1E6CB8)]),
              borderRadius: BorderRadius.circular(26),
            ),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CURRENT BILLING CYCLE', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, letterSpacing: .7)),
              SizedBox(height: 14),
              Text('— units', style: TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900)),
              SizedBox(height: 7),
              Text('No manual reading entry. Live AMI data will populate automatically from the linked provider.', style: TextStyle(color: Colors.white70, height: 1.35)),
            ]),
          ),
          const SizedBox(height: 16),
          const Row(children: [
            Expanded(child: Metric(icon: Icons.electric_meter_outlined, title: 'Latest Reading', value: '— kWh', sub: 'Automatic')),
            SizedBox(width: 12),
            Expanded(child: Metric(icon: Icons.bolt_outlined, title: 'Today', value: '— units', sub: 'Live usage')),
          ]),
          const SizedBox(height: 12),
          const Row(children: [
            Expanded(child: Metric(icon: Icons.calendar_month_outlined, title: 'Projection', value: '— units', sub: 'Month end')),
            SizedBox(width: 12),
            Expanded(child: Metric(icon: Icons.payments_outlined, title: 'Latest Bill', value: 'Rs —', sub: 'IESCO')),
          ]),
          const SizedBox(height: 22),
          Text('Live sources', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          SourceTile(name: 'IESCO', subtitle: 'Official consumer portal', online: iescoOnline),
          const SizedBox(height: 9),
          SourceTile(name: 'PITC Power Smart', subtitle: 'Smart meter service', online: powerSmartOnline),
          const SizedBox(height: 10),
          Text(syncText(), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 22),
          const Card(child: Padding(
            padding: EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Automatic data only', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              SizedBox(height: 8),
              Text('This build contains no manual meter-reading form. Readings, units, bill history and statistics are reserved for online IESCO/PITC smart-meter data only.'),
            ]),
          )),
        ],
      ),
    );
  }
}

class Metric extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String sub;
  const Metric({super.key, required this.icon, required this.title, required this.value, required this.sub});
  @override
  Widget build(BuildContext context) {
    return Card(child: Padding(
      padding: const EdgeInsets.all(15),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 21),
        const SizedBox(height: 13),
        Text(title, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
        Text(sub, style: Theme.of(context).textTheme.bodySmall),
      ]),
    ));
  }
}

class SourceTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final bool online;
  const SourceTile({super.key, required this.name, required this.subtitle, required this.online});
  @override
  Widget build(BuildContext context) {
    return Card(child: ListTile(
      leading: CircleAvatar(child: Icon(online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined)),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: Text(
        online ? 'ONLINE' : 'UNAVAILABLE',
        style: TextStyle(fontWeight: FontWeight.w800, color: online ? Colors.green.shade700 : Colors.orange.shade800),
      ),
    ));
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text('Usage History', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      const Text('Daily and monthly smart-meter history will sync automatically.'),
      const SizedBox(height: 18),
      Card(child: SizedBox(height: 220, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.show_chart_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        const Text('Waiting for live AMI history', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        const Text('No manual records will be created.'),
      ])))),
    ]);
  }
}

class BillPage extends StatelessWidget {
  const BillPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text('IESCO Bill', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      const Text('Latest official bill and status will appear automatically.'),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(26)),
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('LATEST BILL', style: TextStyle(fontWeight: FontWeight.w800)),
          SizedBox(height: 12),
          Text('Rs —', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900)),
          SizedBox(height: 8),
          Text('Due date —   •   Status —'),
        ]),
      ),
      const SizedBox(height: 14),
      const Card(child: Padding(
        padding: EdgeInsets.all(18),
        child: Column(children: [
          BillRow('Official reading date', '—'),
          BillRow('Previous reading', '—'),
          BillRow('Present reading', '—'),
          BillRow('Billed units', '—'),
        ]),
      )),
    ]);
  }
}

class BillRow extends StatelessWidget {
  final String a;
  final String b;
  const BillRow(this.a, this.b, {super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [Expanded(child: Text(a)), Text(b, style: const TextStyle(fontWeight: FontWeight.w800))]),
    );
  }
}
