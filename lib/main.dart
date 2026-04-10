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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String status = "Disconnected";
  List<String> logs = [];

  final TextEditingController pidController = TextEditingController();

  BluetoothDevice? device;
  BluetoothCharacteristic? writeChar;
  BluetoothCharacteristic? notifyChar;

  StreamSubscription<List<int>>? notificationSub;

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
              logs.add("RESP: $resp");
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
    if (writeChar == null) {
      logs.add("Not connected");
      setState(() {});
      return;
    }

    await writeChar!.write(utf8.encode("$cmd\r"));

    logs.add("CMD: $cmd");
    setState(() {});
  }

  // ---------------- EXPORT ----------------
  Future<void> exportLogs() async {
    final dir = await getExternalStorageDirectory();
    final file = File("${dir!.path}/scan_log.txt");

    await file.writeAsString(logs.join("\n"));

    logs.add("Saved to ${file.path}");
    setState(() {});
  }

  @override
  void dispose() {
    notificationSub?.cancel();
    device?.disconnect();
    super.dispose();
  }

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
            child: const Text("Connect OBD"),
          ),

          Text(status),

          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: pidController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Enter PID (e.g. 010C, 2201D2)",
              ),
            ),
          ),

          ElevatedButton(
            onPressed: () {
              sendCommand(pidController.text.trim());
            },
            child: const Text("Send Command"),
          ),

          Expanded(
            child: ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return Text(logs[index]);
              },
            ),
          )
        ],
      ),
    );
  }
}
