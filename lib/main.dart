import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothConnection? connection;
  String status = "Disconnected";
  String scanStatus = "Idle";
  List<String> logs = [];
  TextEditingController pidController = TextEditingController();

  int countdown = 0;
  bool showNextButton = false;

  // ---------------- CONNECT ----------------
  Future<void> connectToDevice(BluetoothDevice device) async {
    connection = await BluetoothConnection.toAddress(device.address);
    setState(() {
      status = "Connected to ${device.name}";
    });
  }

  // ---------------- SEND COMMAND ----------------
  Future<String> sendCommand(String cmd) async {
    connection!.output.add(Uint8List.fromList(utf8.encode("$cmd\r")));
    await connection!.output.allSent;

    await Future.delayed(Duration(milliseconds: 500));

    String response = "";

    await for (Uint8List data in connection!.input!) {
      response += utf8.decode(data);
      if (response.contains(">")) break;
    }

    return response.replaceAll(">", "").trim();
  }

  // ---------------- PHASE RUN ----------------
  Future<void> runPhase(List<String> pids, int delayMs) async {
    scanStatus = "Scanning...";
    setState(() {});

    for (String pid in pids) {
      String resp = await sendCommand(pid);
      logs.add("CMD:$pid\nRESP:$resp\n---");

      await Future.delayed(Duration(milliseconds: delayMs));
      setState(() {});
    }

    scanStatus = "Completed";
    setState(() {});

    startCountdown();
  }

  // ---------------- COUNTDOWN ----------------
  void startCountdown() {
    countdown = 10;
    showNextButton = false;

    Timer.periodic(Duration(seconds: 1), (timer) {
      if (countdown == 0) {
        timer.cancel();
        showNextButton = true;
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
    await file.writeAsString(logs.join("\n"));
    print("Saved at ${file.path}");
  }

  // ---------------- PHASE DATA ----------------

  final phase1 = [
    "0100","0120","0140","0160","0180",
    "0104","0105","010C","010D","015E",
    "0111","010F","0110",
    "0178","0179","017A","017B"
  ];

  List<String> phase2 = List.generate(256, (i) {
    String hex = i.toRadixString(16).padLeft(2, '0').toUpperCase();
    return "01$hex";
  });

  final phase3 = [
    "220000","220010","220020","220030",
    "220040","220050","220060","220070",
    "220080","220090","2200A0","2200B0",
    "2200C0","2200D0","2200E0","2200F0",

    "220100","220110","220120","220130",
    "220140","220150","220160","220170",
    "220180","220190","2201A0","2201B0",
    "2201C0","2201D0","2201E0","2201F0",

    "221000","221010","221020",
    "221100","221110",

    "222000","222010","223000"
  ];

  final phase4 = [
    "2201A0","2201A1","2201A2","2201A3",
    "2201B0","2201B1","2201B2",
    "2201C0","2201C1",
    "2201D0","2201D1","2201D2",

    "2210A0","2210A1",
    "2210B0",
    "221100","221101"
  ];

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Kia PID Scanner"),
        actions: [
          IconButton(
            icon: Icon(Icons.share),
            onPressed: exportLogs,
          )
        ],
      ),
      body: Column(
        children: [
          Text(status),
          Text(scanStatus,
              style: TextStyle(
                  color: scanStatus == "Scanning..."
                      ? Colors.orange
                      : Colors.green)),

          // PHASE BUTTONS
          ElevatedButton(
              onPressed: () => runPhase(phase1, 800),
              child: Text("Run Phase 1")),

          ElevatedButton(
              onPressed: () => runPhase(phase2, 1000),
              child: Text("Run Phase 2")),

          ElevatedButton(
              onPressed: () => runPhase(phase3, 1300),
              child: Text("Run Phase 3")),

          ElevatedButton(
              onPressed: () => runPhase(phase4, 1300),
              child: Text("Run Phase 4")),

          // TIMER
          if (countdown > 0) Text("Next Phase in: $countdown sec"),

          if (showNextButton)
            Text("You can start next phase now", style: TextStyle(color: Colors.green)),

          // MANUAL INPUT
          Padding(
            padding: EdgeInsets.all(8),
            child: TextField(
              controller: pidController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Enter PID (e.g. 2201D2)",
              ),
            ),
          ),

          ElevatedButton(
              onPressed: () async {
                String cmd = pidController.text.trim();
                String resp = await sendCommand(cmd);
                logs.add("CMD:$cmd\nRESP:$resp\n---");
                setState(() {});
              },
              child: Text("Send Manual PID")),

          // LOG VIEW
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
