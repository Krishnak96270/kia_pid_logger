import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class ScanLog {
  final String pid;
  final String response;
  final DateTime time;

  ScanLog(this.pid, this.response, this.time);

  @override
  String toString() {
    return "${time.toIso8601String()} | CMD:$pid | RESP:$response";
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String status = "Disconnected";
  String scanStatus = "Idle";

  List<ScanLog> logs = [];

  final TextEditingController pidController = TextEditingController();

  BluetoothDevice? device;
  BluetoothCharacteristic? writeChar;
  BluetoothCharacteristic? notifyChar;

  StreamSubscription<List<int>>? notificationSub;

  bool isScanning = false;

  int countdown = 0;
  bool readyNext = false;

  // ---------------- CONNECT ----------------
  Future<void> connectToOBD() async {
    status = "Scanning...";
    setState(() {});

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.name.contains("OBD") ||
            r.device.name.contains("ELM")) {
          device = r.device;

          await FlutterBluePlus.stopScan();
          await device!.connect();

          status = "Connected: ${r.device.name}";
          setState(() {});

          var services = await device!.discoverServices();

          for (var s in services) {
            for (var c in s.characteristics) {
              if (c.properties.write) writeChar = c;
              if (c.properties.notify) notifyChar = c;
            }
          }

          if (notifyChar != null) {
            await notifyChar!.setNotifyValue(true);

            notificationSub =
                notifyChar!.onValueReceived.listen((value) {
              String resp = utf8.decode(value);
              logs.add(ScanLog("RESP", resp, DateTime.now()));
              setState(() {});
            });
          }

          break;
        }
      }
    });
  }

  // ---------------- SEND COMMAND ----------------
  Future<void> sendCommand(String cmd) async {
    if (writeChar == null) return;

    await writeChar!.write(utf8.encode("$cmd\r"));
    logs.add(ScanLog(cmd, "Sent", DateTime.now()));

    await Future.delayed(const Duration(milliseconds: 500));
    setState(() {});
  }

  // ---------------- PHASE RUN ----------------
  Future<void> runPhase(List<String> pids, int delayMs) async {
    isScanning = true;
    scanStatus = "Scanning...";
    setState(() {});

    for (String pid in pids) {
      if (!isScanning) break;

      await sendCommand(pid);
      await Future.delayed(Duration(milliseconds: delayMs));
    }

    scanStatus = "Completed";
    isScanning = false;
    setState(() {});

    startCountdown();
  }

  // ---------------- COUNTDOWN ----------------
  void startCountdown() {
    countdown = 10;
    readyNext = false;

    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (countdown == 0) {
        timer.cancel();
        readyNext = true;
      } else {
        countdown--;
      }
      setState(() {});
    });
  }

  // ---------------- EXPORT ----------------
  Future<void> exportLogs() async {
    final dir = await getExternalStorageDirectory();
    final file = File("${dir!.path}/scan_log.txt");

    String data = logs.map((e) => e.toString()).join("\n");

    await file.writeAsString(data);

    logs.add(ScanLog("EXPORT", "Saved to ${file.path}", DateTime.now()));
    setState(() {});
  }

  // ---------------- PHASE DATA ----------------

  final phase1 = [
    "0100","0120","0140","0160","0180",
    "0104","0105","010C","010D","015E",
    "0111","010F","0110",
    "0178","017A"
  ];

  List<String> phase2 = List.generate(256, (i) {
    return "01${i.toRadixString(16).padLeft(2, '0').toUpperCase()}";
  });

  final phase3 = [
    "220000","220010","220020","220030",
    "220040","220050","220060","220070",
    "220080","220090","2200A0","2200B0",
    "2200C0","2200D0","2200E0","2200F0",
    "220100","220110","220120","220130",
    "220140","220150","220160","220170",
    "220180","220190","2201A0","2201B0",
    "2201C0","2201D0","2201E0","2201F0"
  ];

  final phase4 = [
    "2201A0","2201A1","2201A2",
    "2201B0","2201B1",
    "2201C0","2201C1",
    "2201D0","2201D1","2201D2",
    "2210A0","2210A1",
    "2210B0",
    "221100"
  ];

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Kia PID Scanner"),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: exportLogs,
          )
        ],
      ),
      body: Column(
        children: [
          ElevatedButton(
              onPressed: connectToOBD,
              child: const Text("Connect OBD")),

          Text(status),
          Text(scanStatus),

          ElevatedButton(
              onPressed: () => runPhase(phase1, 800),
              child: const Text("Run Phase 1")),

          ElevatedButton(
              onPressed: () => runPhase(phase2, 1000),
              child: const Text("Run Phase 2")),

          ElevatedButton(
              onPressed: () => runPhase(phase3, 1300),
              child: const Text("Run Phase 3")),

          ElevatedButton(
              onPressed: () => runPhase(phase4, 1300),
              child: const Text("Run Phase 4")),

          if (countdown > 0) Text("Next Phase in: $countdown sec"),
          if (readyNext)
            const Text("Start next phase",
                style: TextStyle(color: Colors.green)),

          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: pidController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Enter PID",
              ),
            ),
          ),

          ElevatedButton(
              onPressed: () {
                sendCommand(pidController.text.trim());
              },
              child: const Text("Send Manual PID")),

          Expanded(
            child: ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return Text(logs[index].toString());
              },
            ),
          )
        ],
      ),
    );
  }
}
