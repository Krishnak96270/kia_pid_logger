// Flutter app: ELM327 Auto Scan + Manual PID + Export
// Uses: flutter_bluetooth_serial_plus, sqflite, share_plus

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ELM327 Scanner',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DeviceScreen(),
    );
  }
}

// ---------------- DB ----------------
class DB {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'logs.db');
    _db = await openDatabase(path, version: 1, onCreate: (d, v) async {
      await d.execute('''
      CREATE TABLE logs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cmd TEXT,
        resp TEXT,
        time TEXT
      )
      ''');
    });
    return _db!;
  }

  static Future<void> insert(String c, String r) async {
    final d = await db;
    await d.insert('logs', {
      'cmd': c,
      'resp': r,
      'time': DateTime.now().toIso8601String()
    });
  }

  static Future<List<Map<String, dynamic>>> all() async {
    final d = await db;
    return d.query('logs', orderBy: 'id DESC');
  }
}

// ---------------- DEVICE ----------------
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  List<BluetoothDevice> devices = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    await Permission.bluetooth.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();

    if (!(await FlutterBluetoothSerial.instance.isEnabled ?? false)) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }

    devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select ELM327')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: devices.length,
              itemBuilder: (_, i) {
                final d = devices[i];
                return ListTile(
                  title: Text(d.name ?? 'Unknown'),
                  subtitle: Text(d.address),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ScannerScreen(device: d)),
                  ),
                );
              }),
    );
  }
}

// ---------------- SCANNER ----------------
class ScannerScreen extends StatefulWidget {
  final BluetoothDevice device;
  const ScannerScreen({super.key, required this.device});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  BluetoothConnection? conn;
  String buffer = '';
  List<Map<String, dynamic>> logs = [];
  final TextEditingController ctrl = TextEditingController();
  bool connecting = true;

  final List<String> scanList = [
    '0100','0120','0140','0160','0180',
    '0104','0105','010C','010D','015E',
    '0178','0179','017A','017B'
  ];

  @override
  void initState() {
    super.initState();
    connect();
    refresh();
  }

  Future<void> connect() async {
    conn = await BluetoothConnection.toAddress(widget.device.address);
    conn!.input!.listen((d) => buffer += ascii.decode(d));
    connecting = false;
    setState(() {});
    await initELM();
  }

  Future<void> initELM() async {
    await send('ATZ');
    await send('ATE0');
    await send('ATL0');
    await send('ATS0');
    await send('ATH0');
    await send('ATSP0');
  }

  Future<void> send(String cmd) async {
    conn?.output.add(ascii.encode('$cmd\r'));
    await conn?.output.allSent;
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<String> request(String cmd) async {
    buffer = '';
    await send(cmd);
    await Future.delayed(const Duration(seconds: 1));
    return buffer.trim();
  }

  Future<void> manualSend() async {
    final c = ctrl.text.trim();
    if (c.isEmpty) return;
    final r = await request(c);
    await DB.insert(c, r);
    ctrl.clear();
    refresh();
  }

  Future<void> runScan() async {
    for (var c in scanList) {
      final r = await request(c);
      await DB.insert(c, r);
    }
    refresh();
  }

  Future<void> refresh() async {
    logs = await DB.all();
    setState(() {});
  }

  Future<void> export() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/elm_log.txt');

    String txt = '';
    for (var l in logs) {
      txt += 'CMD:${l['cmd']}\nRESP:${l['resp']}\nTIME:${l['time']}\n---\n';
    }

    await file.writeAsString(txt);
    Share.shareXFiles([XFile(file.path)], text: 'ELM Logs');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name ?? ''),
        actions: [
          IconButton(onPressed: export, icon: const Icon(Icons.share))
        ],
      ),
      body: connecting
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          decoration: const InputDecoration(
                            hintText: 'Enter PID (010C)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(onPressed: manualSend, child: const Text('Send'))
                    ],
                  ),
                ),

                ElevatedButton(
                  onPressed: runScan,
                  child: const Text('Run Full Scan'),
                ),

                const Divider(),

                Expanded(
                  child: ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (_, i) {
                      final l = logs[i];
                      return ListTile(
                        title: Text('CMD: ${l['cmd']}'),
                        subtitle: Text(l['resp']),
                      );
                    },
                  ),
                )
              ],
            ),
    );
  }
}
