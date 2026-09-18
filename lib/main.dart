import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeterApp());
}

class MeterApp extends StatelessWidget {
  const MeterApp({super.key});
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
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const Gate(),
    );
  }
}

class PitcError implements Exception {
  final int code;
  final String message;
  PitcError(this.code, this.message);
}

class PitcApi {
  static const String base = 'https://api-powersmart.pitc.com.pk';

  Future<dynamic> post(String path, Map<String, dynamic> body, {String? token}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.postUrl(Uri.parse(base + path));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.userAgentHeader, 'IESCO-Meter-Live/0.2');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, token);
      }
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final raw = await utf8.decoder.bind(response).join();
      dynamic data;
      try {
        data = raw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(raw);
      } catch (_) {
        data = <String, dynamic>{'raw': raw};
      }
      if (response.statusCode == 401) {
        throw PitcError(401, 'Session expired. Please sign in again.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PitcError(response.statusCode, errorMessage(data) ?? 'PITC request failed.');
      }
      if (data is Map) {
        final status = data['status'];
        if (status != null && status.toString() != '200' && status.toString() != '1' && status.toString().toLowerCase() != 'true') {
          throw PitcError(int.tryParse(status.toString()) ?? 400, errorMessage(data) ?? 'PITC request failed.');
        }
      }
      return data;
    } on TimeoutException {
      throw PitcError(408, 'IESCO/PITC server timed out.');
    } on SocketException {
      throw PitcError(503, 'Internet or IESCO/PITC server unavailable.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Session> signIn(String id, String password) async {
    final clean = id.trim();
    final digits = clean.replaceAll(RegExp(r'[^0-9]'), '');
    final body = <String, dynamic>{
      'cnic': '',
      'contactNo': '',
      'emailUserId': '',
      'password': password,
    };
    if (clean.contains('@') || digits.isEmpty) {
      body['emailUserId'] = clean;
    } else if (digits.length == 13) {
      body['cnic'] = digits;
    } else {
      body['contactNo'] = digits;
    }
    final data = await post('/appUser/signIn', body);
    final token = findText(data, const ['token']);
    if (token == null || token.isEmpty) {
      throw PitcError(401, errorMessage(data) ?? 'Sign in failed.');
    }
    final meters = collectMeters(data);
    return Session(
      token: token,
      name: findText(data, const ['appUserName', 'name']) ?? '',
      cnic: findText(data, const ['cnic']) ?? '',
      meters: meters,
    );
  }

  Future<dynamic> monthly(String token, String ref) {
    return post('/getHistory/monthlyConsumption', {'refNo': ref}, token: token);
  }

  Future<dynamic> payments(String token, String ref) {
    return post('/getHistory/paymentHistory', {'refNo': ref}, token: token);
  }
}

class Session {
  final String token;
  final String name;
  final String cnic;
  final List<Map<String, dynamic>> meters;
  const Session({required this.token, required this.name, required this.cnic, required this.meters});

  Map<String, dynamic> toJson() => {
        'token': token,
        'name': name,
        'cnic': cnic,
        'meters': meters,
      };

  factory Session.fromJson(Map<String, dynamic> j) {
    final meters = <Map<String, dynamic>>[];
    final raw = j['meters'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) meters.add(Map<String, dynamic>.from(e));
      }
    }
    return Session(
      token: (j['token'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      cnic: (j['cnic'] ?? '').toString(),
      meters: meters,
    );
  }
}

class CacheBundle {
  final dynamic monthly;
  final dynamic payments;
  final String syncedAt;
  const CacheBundle({this.monthly, this.payments, required this.syncedAt});

  Map<String, dynamic> toJson() => {
        'monthly': monthly,
        'payments': payments,
        'syncedAt': syncedAt,
      };

  factory CacheBundle.fromJson(Map<String, dynamic> j) {
    return CacheBundle(
      monthly: j['monthly'],
      payments: j['payments'],
      syncedAt: (j['syncedAt'] ?? '').toString(),
    );
  }
}

class Store {
  static const FlutterSecureStorage s = FlutterSecureStorage();
  static const String sessionKey = 'iesco_session_v02';
  static const String refKey = 'iesco_selected_ref_v02';

  Future<Session?> loadSession() async {
    final raw = await s.read(key: sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        final x = Session.fromJson(Map<String, dynamic>.from(j));
        if (x.token.isNotEmpty) return x;
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveSession(Session x) {
    return s.write(key: sessionKey, value: jsonEncode(x.toJson()));
  }

  Future<void> clear() async {
    await s.delete(key: sessionKey);
    await s.delete(key: refKey);
  }

  Future<String?> loadRef() => s.read(key: refKey);
  Future<void> saveRef(String ref) => s.write(key: refKey, value: ref);

  Future<void> saveCache(String ref, CacheBundle c) {
    return s.write(key: 'iesco_cache_' + ref, value: jsonEncode(c.toJson()));
  }

  Future<CacheBundle?> loadCache(String ref) async {
    final raw = await s.read(key: 'iesco_cache_' + ref);
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map) return CacheBundle.fromJson(Map<String, dynamic>.from(j));
    } catch (_) {}
    return null;
  }
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  final Store store = Store();
  Session? session;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    boot();
  }

  Future<void> boot() async {
    final x = await store.loadSession();
    if (!mounted) return;
    setState(() {
      session = x;
      loading = false;
    });
  }

  Future<void> loggedIn(Session x) async {
    await store.saveSession(x);
    if (mounted) setState(() => session = x);
  }

  Future<void> logout() async {
    await store.clear();
    if (mounted) setState(() => session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (session == null) return LoginPage(onDone: loggedIn);
    return HomeShell(session: session!, onLogout: logout);
  }
}

class LoginPage extends StatefulWidget {
  final Future<void> Function(Session) onDone;
  const LoginPage({super.key, required this.onDone});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController id = TextEditingController();
  final TextEditingController pass = TextEditingController();
  final PitcApi api = PitcApi();
  bool busy = false;
  bool hide = true;
  String? error;

  @override
  void dispose() {
    id.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> go() async {
    if (id.text.trim().isEmpty || pass.text.isEmpty) {
      setState(() => error = 'Enter your Power Smart email, phone or CNIC and password.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final x = await api.signIn(id.text, pass.text);
      pass.clear();
      await widget.onDone(x);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is PitcError ? e.message : 'Could not sign in.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 38, 22, 30),
          children: [
            Container(
              height: 76,
              width: 76,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.electric_meter_rounded, color: Colors.white, size: 40),
            ),
            const SizedBox(height: 26),
            Text(
              'Connect your IESCO meter',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            const Text(
              'One-time Power Smart sign-in. After this, usage and bill data sync automatically. No meter reading is entered manually.',
              style: TextStyle(height: 1.45),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: id,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Power Smart email / phone / CNIC',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: pass,
              enabled: !busy,
              obscureText: hide,
              onSubmitted: (_) => go(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => hide = !hide),
                  icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: busy ? null : go,
              icon: busy
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link_rounded),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Connect my meter'),
              ),
            ),
            const SizedBox(height: 16),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Your password is not saved. Only the authenticated session token is stored securely on this phone.',
                  style: TextStyle(height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  final Session session;
  final Future<void> Function() onLogout;
  const HomeShell({super.key, required this.session, required this.onLogout});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final PitcApi api = PitcApi();
  final Store store = Store();
  int tab = 0;
  String? ref;
  CacheBundle? cache;
  bool syncing = false;
  String? error;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setup();
    timer = Timer.periodic(const Duration(minutes: 5), (_) => sync());
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

  List<String> get refs {
    final out = <String>[];
    for (final m in widget.session.meters) {
      final v = findText(m, const ['refNo', 'referenceNo', 'referenceNumber', 'refNumber']);
      if (v != null && v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }

  Future<void> setup() async {
    final saved = await store.loadRef();
    final r = refs;
    String? chosen;
    if (saved != null && r.contains(saved)) chosen = saved;
    chosen ??= r.isNotEmpty ? r.first : null;
    if (!mounted) return;
    setState(() => ref = chosen);
    if (chosen != null) {
      final c = await store.loadCache(chosen);
      if (mounted && c != null) setState(() => cache = c);
      await sync();
    }
  }

  Future<void> choose(String? x) async {
    if (x == null || x.isEmpty) return;
    await store.saveRef(x);
    final c = await store.loadCache(x);
    if (!mounted) return;
    setState(() {
      ref = x;
      cache = c;
      error = null;
    });
    await sync();
  }

  Future<void> sync() async {
    if (ref == null || syncing) return;
    setState(() {
      syncing = true;
      error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        api.monthly(widget.session.token, ref!),
        api.payments(widget.session.token, ref!),
      ]);
      final c = CacheBundle(
        monthly: results[0],
        payments: results[1],
        syncedAt: DateTime.now().toIso8601String(),
      );
      await store.saveCache(ref!, c);
      if (mounted) setState(() => cache = c);
    } on PitcError catch (e) {
      if (e.code == 401) {
        await widget.onLogout();
        return;
      }
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not refresh. Showing last synced data.');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      Dashboard(
        session: widget.session,
        ref: ref,
        refs: refs,
        cache: cache,
        syncing: syncing,
        error: error,
        onSync: sync,
        onChoose: choose,
        onLogout: widget.onLogout,
      ),
      HistoryPage(cache: cache, onSync: sync),
      BillPage(cache: cache, onSync: sync),
    ];
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (x) => setState(() => tab = x),
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
  final Session session;
  final String? ref;
  final List<String> refs;
  final CacheBundle? cache;
  final bool syncing;
  final String? error;
  final Future<void> Function() onSync;
  final Future<void> Function(String?) onChoose;
  final Future<void> Function() onLogout;

  const Dashboard({
    super.key,
    required this.session,
    required this.ref,
    required this.refs,
    required this.cache,
    required this.syncing,
    required this.error,
    required this.onSync,
    required this.onChoose,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final monthlyRows = rows(cache?.monthly);
    final paymentRows = rows(cache?.payments);
    final latestMonth = monthlyRows.isEmpty ? null : monthlyRows.first;
    final latestPay = paymentRows.isEmpty ? null : paymentRows.first;

    final units = findText(latestMonth ?? cache?.monthly, const [
      'units', 'consumption', 'monthlyConsumption', 'consumedUnits', 'kwh', 'totalUnits'
    ]);
    final reading = findText(latestMonth ?? cache?.monthly, const [
      'presentReading', 'currentReading', 'meterReading', 'reading', 'presentRead'
    ]);
    final readDate = findText(latestMonth ?? cache?.monthly, const [
      'readingDate', 'billMonth', 'monthName', 'month', 'date'
    ]);
    final amount = findText(latestPay ?? cache?.payments, const [
      'billAmount', 'currentBillAmount', 'amount', 'amountPayable', 'payableAmount', 'dueAmount'
    ]);
    final due = findText(latestPay ?? cache?.payments, const ['dueDate', 'billDueDate', 'currentBillDueDate']);

    return RefreshIndicator(
      onRefresh: onSync,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('IESCO Meter Live', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(session.name.isEmpty ? 'PITC Power Smart connected' : session.name),
                  ],
                ),
              ),
              syncing
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
                    )
                  : IconButton(onPressed: onSync, icon: const Icon(Icons.sync_rounded)),
              PopupMenuButton<String>(
                onSelected: (x) {
                  if (x == 'logout') onLogout();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'logout', child: Text('Disconnect account')),
                ],
              ),
            ],
          ),
          if (refs.length > 1) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: ref,
              decoration: const InputDecoration(labelText: 'Meter'),
              items: refs.map((x) => DropdownMenuItem(value: x, child: Text(mask(x)))).toList(),
              onChanged: onChoose,
            ),
          ],
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF0F4C91), Color(0xFF1E6CB8)]),
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LATEST ONLINE USAGE', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(
                  units == null ? '— units' : clean(units) + ' units',
                  style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 7),
                Text(
                  readDate == null ? 'Synced automatically from PITC' : 'Period / reading date: ' + readDate,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: Metric('Meter reading', reading == null ? '—' : clean(reading), Icons.electric_meter_outlined)),
              const SizedBox(width: 12),
              Expanded(child: Metric('Latest bill', amount == null ? 'Rs —' : 'Rs ' + clean(amount), Icons.payments_outlined)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Metric('Reference', ref == null ? '—' : mask(ref!), Icons.numbers_rounded)),
              const SizedBox(width: 12),
              Expanded(child: Metric('Due date', due ?? '—', Icons.event_outlined)),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(error!),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(17),
              child: Text(
                'Automatic only: this app has no manual meter-reading form. It refreshes your linked Power Smart data when opened and every few minutes.',
                style: TextStyle(height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  final CacheBundle? cache;
  final Future<void> Function() onSync;
  const HistoryPage({super.key, required this.cache, required this.onSync});

  @override
  Widget build(BuildContext context) {
    final data = rows(cache?.monthly);
    return RefreshIndicator(
      onRefresh: onSync,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('Usage History', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          const Text('Monthly consumption from your linked PITC account.'),
          const SizedBox(height: 18),
          if (data.isEmpty)
            const EmptyState('No consumption history returned yet.', Icons.query_stats_rounded)
          else
            ...data.take(24).map((x) {
              final period = findText(x, const ['monthName', 'billMonth', 'month', 'readingDate', 'date']) ?? 'Consumption record';
              final units = findText(x, const ['units', 'consumption', 'monthlyConsumption', 'consumedUnits', 'kwh', 'totalUnits']);
              return Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.bolt_rounded)),
                    title: Text(period, style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: const Text('Official PITC history'),
                    trailing: Text(units == null ? '—' : clean(units) + ' units', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class BillPage extends StatelessWidget {
  final CacheBundle? cache;
  final Future<void> Function() onSync;
  const BillPage({super.key, required this.cache, required this.onSync});

  @override
  Widget build(BuildContext context) {
    final data = rows(cache?.payments);
    final latest = data.isEmpty ? null : data.first;
    final amount = findText(latest ?? cache?.payments, const ['billAmount', 'currentBillAmount', 'amount', 'amountPayable', 'payableAmount']);
    final due = findText(latest ?? cache?.payments, const ['dueDate', 'billDueDate', 'currentBillDueDate']);
    final status = findText(latest ?? cache?.payments, const ['paymentStatus', 'paidStatus', 'statusDescription', 'status']);

    return RefreshIndicator(
      onRefresh: onSync,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('IESCO Bill', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          const Text('Latest payment and bill information from PITC.'),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LATEST BILL / PAYMENT', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(amount == null ? 'Rs —' : 'Rs ' + clean(amount), style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text((due == null ? 'Due date —' : 'Due ' + due) + '   •   ' + (status ?? 'Status —')),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (data.isEmpty)
            const EmptyState('No payment history returned yet.', Icons.receipt_long_outlined)
          else
            ...data.take(16).map((x) {
              final period = findText(x, const ['monthName', 'billMonth', 'month', 'paymentDate', 'date']) ?? 'Payment record';
              final value = findText(x, const ['paidAmount', 'amountPaid', 'amount', 'billAmount']);
              final s = findText(x, const ['paymentStatus', 'paidStatus', 'status']) ?? 'Record';
              return Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long_rounded),
                    title: Text(period, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(s),
                    trailing: Text(value == null ? '—' : 'Rs ' + clean(value)),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class Metric extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  const Metric(this.title, this.value, this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 21),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyState(this.text, this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        height: 210,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? errorMessage(dynamic data) {
  if (data is Map) {
    for (final k in const ['message', 'Message', 'error', 'Error', 'detail']) {
      final v = data[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
  }
  return null;
}

String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

String? findText(dynamic source, List<String> keys) {
  final wanted = keys.map(norm).toSet();
  dynamic walk(dynamic node, int depth) {
    if (node == null || depth > 7) return null;
    if (node is Map) {
      for (final e in node.entries) {
        if (wanted.contains(norm(e.key.toString()))) {
          final v = e.value;
          if (v != null && v.toString().trim().isNotEmpty && v.toString().toLowerCase() != 'null') return v.toString();
        }
      }
      for (final v in node.values) {
        final hit = walk(v, depth + 1);
        if (hit != null) return hit;
      }
    } else if (node is List) {
      for (final v in node) {
        final hit = walk(v, depth + 1);
        if (hit != null) return hit;
      }
    }
    return null;
  }
  return walk(source, 0)?.toString();
}

List<Map<String, dynamic>> collectMeters(dynamic source) {
  final out = <Map<String, dynamic>>[];
  void walk(dynamic node, int depth) {
    if (node == null || depth > 8) return;
    if (node is Map) {
      final map = Map<String, dynamic>.from(node);
      final ref = findText(map, const ['refNo', 'referenceNo', 'referenceNumber', 'refNumber']);
      if (ref != null && ref.length >= 8) {
        if (!out.any((x) => findText(x, const ['refNo', 'referenceNo', 'referenceNumber', 'refNumber']) == ref)) {
          out.add(map);
        }
      }
      for (final v in node.values) {
        if (v is Map || v is List) walk(v, depth + 1);
      }
    } else if (node is List) {
      for (final v in node) walk(v, depth + 1);
    }
  }
  walk(source, 0);
  return out;
}

List<Map<String, dynamic>> rows(dynamic source) {
  final lists = <List<Map<String, dynamic>>>[];
  void walk(dynamic node, int depth) {
    if (node == null || depth > 7) return;
    if (node is List) {
      final current = <Map<String, dynamic>>[];
      for (final x in node) {
        if (x is Map) current.add(Map<String, dynamic>.from(x));
      }
      if (current.isNotEmpty) lists.add(current);
      for (final x in node) {
        if (x is Map || x is List) walk(x, depth + 1);
      }
    } else if (node is Map) {
      for (final v in node.values) {
        if (v is Map || v is List) walk(v, depth + 1);
      }
    }
  }
  walk(source, 0);
  if (lists.isEmpty) return const [];
  lists.sort((a, b) => b.length.compareTo(a.length));
  return lists.first;
}

String clean(String x) {
  var v = x.trim();
  if (v.endsWith('.0')) v = v.substring(0, v.length - 2);
  return v;
}

String mask(String x) {
  final v = x.trim();
  if (v.length <= 8) return v;
  return v.substring(0, 4) + '••••' + v.substring(v.length - 4);
}
