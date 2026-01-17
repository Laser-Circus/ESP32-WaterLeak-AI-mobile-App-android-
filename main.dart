import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:water_leak_detector/usage_chart_page.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

late FirebaseDatabase database;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  database = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
        'https://water-leak-detection-24aed-default-rtdb.asia-southeast1.firebasedatabase.app/',
  );

  const AndroidInitializationSettings androidInitSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initSettings =
      InitializationSettings(android: androidInitSettings);

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  runApp(const WaterLeakApp());
}

class WaterLeakApp extends StatelessWidget {
  const WaterLeakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Leak Detector',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const SensorDashboard(),
    );
  }
}

class SensorDashboard extends StatefulWidget {
  const SensorDashboard({super.key});

  @override
  State<SensorDashboard> createState() => _SensorDashboardState();
}

class _SensorDashboardState extends State<SensorDashboard> {
  final DatabaseReference _sensorRef = database.ref('sensors');
  final DatabaseReference _valveRef = database.ref('valve_status');

  double _flowRate = 0.0;
  bool _valveOn = false;
  bool _leakDetected = false;

  @override
  void initState() {
    super.initState();

    _sensorRef.onValue.listen((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>;
      final leak = data['leak_status'] == 1;
      final flow = data['flow_rate']?.toDouble() ?? 0.0;

      setState(() {
        _flowRate = flow;

        if (leak && !_leakDetected) {
          _showLeakNotification();
        }

        _leakDetected = leak;
      });

      if (leak && _valveOn) {
        _valveOn = false;
        _valveRef.set({'status': "OFF"});
      }
    });

    _valveRef.child('status').onValue.listen((event) {
      final status = event.snapshot.value;
      setState(() {
        _valveOn = status == "ON";
      });
    });

    database.ref('sensors/prediction').onValue.listen((event) async {
      if (event.snapshot.exists && _valveOn) {
        await _handleUnusualActivityDetected();
      }
    });
  }

  void _toggleValve(bool value) {
    if (_leakDetected && value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Cannot open valve while leak is detected.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _valveOn = value;
    });

    _valveRef.set({'status': value ? "ON" : "OFF"});
  }

  Future<void> _showLeakNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'leak_channel',
      'Leak Alerts',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Leak Detected',
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      0,
      '🚨 Leak Detected!',
      'A water leak has been detected. Valve has been shut off.',
      notificationDetails,
    );
  }

  Future<void> _showUnusualActivityNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'unusual_channel',
      'Unusual Activity',
      importance: Importance.max,
      priority: Priority.high,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      2,
      '💧 Unusual Water Activity',
      'Unusual water activity was detected. Valve closed.',
      notificationDetails,
    );
  }

  Future<void> _handleUnusualActivityDetected() async {
    await _showUnusualActivityNotification();

    await _valveRef.set({'status': "OFF"});

    setState(() {
      _valveOn = false;
    });

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Unusual Water Activity"),
        content: const Text("Unusual water usage was detected. The valve has been closed. Do you want to reopen it?"),
        actions: [
          TextButton(
            child: const Text("No"),
            onPressed: () async {
              Navigator.pop(context);
              await database.ref('sensors/prediction').remove();
            },
          ),
          TextButton(
            child: const Text("Yes"),
            onPressed: () async {
              Navigator.pop(context);
              await _valveRef.set({'status': "ON"});
              await database.ref('sensors/prediction').remove();
              setState(() {
                _valveOn = true;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Valve reopened.'),
                  backgroundColor: Colors.green,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showLeakResolvedDialog() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Leak Resolved?"),
        content: const Text("Have you fixed the leak and want to reopen the valve?"),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: const Text("Yes"),
            onPressed: () async {
              Navigator.pop(context);

              await database.ref('/sensors/leak_status').set(0);
              await database.ref('/valve_status/status').set("ON");

              setState(() {
                _leakDetected = false;
                _valveOn = true;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Leak status reset. Valve reopened.'),
                  backgroundColor: Colors.green,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Water Leak Monitor')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Flow Rate: ${_flowRate.toStringAsFixed(2)} L/min',
                style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 30),
            _leakDetected
                ? const Text('⚠️ LEAK DETECTED!',
                    style: TextStyle(color: Colors.red, fontSize: 28))
                : const Text('System Normal',
                    style: TextStyle(color: Colors.green, fontSize: 24)),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Valve: ", style: TextStyle(fontSize: 20)),
                Switch(
                  value: _valveOn,
                  onChanged: _toggleValve,
                  activeColor: Colors.blue,
                ),
                Text(_valveOn ? "OPEN" : "CLOSED",
                    style: const TextStyle(fontSize: 20)),
              ],
            ),
            const SizedBox(height: 20),
            if (_leakDetected)
              ElevatedButton(
                onPressed: _showLeakResolvedDialog,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                child: const Text("Mark Leak as Resolved"),
              ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => UsageChartPage()),
                );
              },
              child: const Text("View Monthly Usage"),
            ),
          ],
        ),
      ),
    );
  }
}
