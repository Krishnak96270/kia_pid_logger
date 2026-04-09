// Updated Flutter app with:
// 1. Bluetooth enable request
// 2. Refresh/search paired devices
// 3. Select ELM327 device
// 4. PID input box
// 5. Send command
// 6. Save response logs

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

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ELM327 PID Logger',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const BluetoothDeviceScreen(),
    );
  }
}

class DBHelper {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await initDB();
    return _db!;
  }

  static Future<Database> initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'elm_logs.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE logs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            command TEXT,
            response TEXT,
            timestamp TEXT
          )
        ''');
      },
    );
  }

  static Future<void> insertLog(String command, String response) async {
    final db = await database;
    await db.insert('logs', {
      'command': command,
      'response': response,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getLogs() async {
    final db = await database;
    return await db.query('logs', orderBy: 'id DESC');
  }
}

class BluetoothDeviceScreen extends StatefulWidget {
  const BluetoothDeviceScreen({super.key});

  @override
  State<BluetoothDeviceScreen> createState() =>
      _BluetoothDeviceScreenState();
}

class _BluetoothDeviceScreenState extends State<BluetoothDeviceScreen> {
  List<BluetoothDevice> devices = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    initializeBluetooth();
  }

  Future<void> initializeBluetooth() async {
    await Permission.bluetooth.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();

    bool? enabled = await FlutterBluetoothSerial.instance.isEnabled;

    if (enabled == false) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }

    await loadDevices();
  }

  Future<void> loadDevices() async {
    setState(() => loading = true);

    final bondedDevices =
        await FlutterBluetoothSerial.instance.getBondedDevices();

    setState(() {
      devices = bondedDevices;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select ELM327 Device'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: loadDevices,
          )
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : devices.isEmpty
              ? const Center(
                  child: Text('No paired Bluetooth devices found'),
                )
              : ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(device.name ?? 'Unknown Device'),
                      subtitle: Text(device.address),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PIDTesterScreen(device: device),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class PIDTesterScreen extends StatefulWidget {
  final BluetoothDevice device;

  const PIDTesterScreen({super.key, required this.device});

  @override
  State<PIDTesterScreen> createState() => _PIDTesterScreenState();
}

class _PIDTesterScreenState extends State<PIDTesterScreen> {
  BluetoothConnection? connection;
  bool isConnected = false;
  bool isConnecting = true;

  String incomingBuffer = '';
  final TextEditingController commandController = TextEditingController();

  List<Map<String, dynamic>> logs = [];
  StreamSubscription? inputSubscription;

  @override
  void initState() {
    super.initState();
    connectELM();
    refreshLogs();
  }

  Future<void> connectELM() async {
    try {
      connection = await BluetoothConnection.toAddress(widget.device.address);
      isConnected = true;
      isConnecting = false;
      setState(() {});

      inputSubscription = connection!.input!.listen((data) {
        incomingBuffer += ascii.decode(data);
      });

      await initializeELM327();
    } catch (e) {
      debugPrint('Connection Error: $e');
      isConnecting = false;
      setState(() {});
    }
  }

  Future<void> initializeELM327() async {
    await sendRaw('ATZ');
    await sendRaw('ATE0');
    await sendRaw('ATL0');
    await sendRaw('ATS0');
    await sendRaw('ATH0');
    await sendRaw('ATSP0');
  }

  Future<void> sendRaw(String cmd) async {
    connection?.output.add(ascii.encode('$cmd\r'));
    await connection?.output.allSent;
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> sendCommand() async {
    final cmd = commandController.text.trim();
    if (cmd.isEmpty) return;

    incomingBuffer = '';

    await sendRaw(cmd);
    await Future.delayed(const Duration(seconds: 1));

    String response = incomingBuffer.trim();

    await DBHelper.insertLog(cmd, response);
    await refreshLogs();

    commandController.clear();
  }

  Future<void> refreshLogs() async {
    logs = await DBHelper.getLogs();
    setState(() {});
  }

  Future<void> exportLogs() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/elm_logs.txt');

    String content = '';
    for (var log in logs) {
      content +=
          'CMD: ${log['command']}\nRESP: ${log['response']}\nTIME: ${log['timestamp']}\n-------------------\n';
    }

    await file.writeAsString(content);
    Share.shareXFiles([XFile(file.path)], text: 'ELM327 Logs');
  }

  @override
  void dispose() {
    inputSubscription?.cancel();
    connection?.dispose();
    commandController.dispose();
    super.dispose();
  }

  Widget buildLogCard(Map<String, dynamic> log) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CMD: ${log['command']}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('RESP: ${log['response']}'),
            const SizedBox(height: 6),
            Text(log['timestamp'],
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name ?? 'PID Tester'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: exportLogs,
          )
        ],
      ),
      body: isConnecting
          ? const Center(child: CircularProgressIndicator())
          : !isConnected
              ? const Center(child: Text('Connection Failed'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: commandController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: 'Enter PID / AT Command',
                                hintText: 'Example: 010C',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: sendCommand,
                            child: const Text('Send'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: logs.isEmpty
                          ? const Center(child: Text('No logs saved yet'))
                          : ListView.builder(
                              itemCount: logs.length,
                              itemBuilder: (context, index) {
                                return buildLogCard(logs[index]);
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}
