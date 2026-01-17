import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';


class UsageChartPage extends StatefulWidget {
  @override
  _UsageChartPageState createState() => _UsageChartPageState();
}

class _UsageChartPageState extends State<UsageChartPage> {
  Timer? _refreshTimer;
  final _dbRef = FirebaseDatabase.instanceFor(
  app: Firebase.app(),
  databaseURL: "https://water-leak-detection-24aed-default-rtdb.asia-southeast1.firebasedatabase.app/",
).ref("flow_sensor_data");

  Map<DateTime, double> _monthlyTotals = {};
  Map<String, double> _dailyTotals = {};
  List<Map<String, dynamic>> _leakEvents = [];

  bool _loading = true;
  String? _lastUpdated;
  String _viewMode = 'Monthly';
  final double _usageThreshold = 15.0;
  final Set<String> _seenInvalidKeys = {};

  @override
  void initState() {
    super.initState();
    _loadFlowData();
    _refreshTimer = Timer.periodic(Duration(seconds: 30), (_) => _loadFlowData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFlowData() async {
    final snapshot = await _dbRef.get();
    final tempMonthly = <DateTime, double>{};
    final tempDaily = <String, double>{};
    final tempLeaks = <Map<String, dynamic>>[];

    if (snapshot.exists) {
      final data = snapshot.value as Map;
      for (var e in data.entries) {
        final key = e.key as String;
        final val = e.value;

        if (key == 'unknown_time') continue;

        final dt = DateTime.tryParse(key)?.toLocal();
        if (dt == null) {
          if (_seenInvalidKeys.add(key)) print("Skipping invalid timestamp: $key");
          continue;
        }

        if (val is Map && val.containsKey('flow')) {
          final flow = (val['flow'] as num).toDouble();

          final monthStart = DateTime(dt.year, dt.month);
          tempMonthly[monthStart] = (tempMonthly[monthStart] ?? 0) + flow / 1000;

          final dayKey = DateFormat('yyyy-MM-dd').format(dt);
          tempDaily[dayKey] = (tempDaily[dayKey] ?? 0) + flow / 1000;

          if (val['leak_status'] == 1) {
            tempLeaks.add({
              'timestamp': dt,
              'type': 'leak',
              'flow': flow / 1000,
            });
          }
          if (val['prediction'] == 1) {
            tempLeaks.add({
              'timestamp': dt,
              'type': 'prediction',
              'flow': flow / 1000,
            });
          }
        }
      }
    }

    tempLeaks.sort((a, b) => (b['timestamp'] as DateTime).compareTo(a['timestamp'] as DateTime));

    final sortedMonthly = tempMonthly.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (sortedMonthly.isNotEmpty) {
      final latestMonth = sortedMonthly.last.key;
      final threeMonthsAgo = DateTime(latestMonth.year, latestMonth.month - 2);
      _monthlyTotals = Map.fromEntries(
        sortedMonthly.where((entry) =>
            entry.key.isAfter(threeMonthsAgo.subtract(Duration(days: 1))))
      );
    } else {
      _monthlyTotals = {};
    }

    final parsedDates = tempDaily.keys
        .map((k) => DateTime.tryParse(k))
        .where((d) => d != null)
        .cast<DateTime>()
        .toList();

    if (parsedDates.isNotEmpty) {
      parsedDates.sort((a, b) => b.compareTo(a));
      final latestDate = parsedDates.first;
      final latestMonthStart = DateTime(latestDate.year, latestDate.month);

      _dailyTotals = Map.fromEntries(
        tempDaily.entries
            .where((entry) {
              final date = DateTime.tryParse(entry.key as String);
              return date != null &&
                  date.year == latestMonthStart.year &&
                  date.month == latestMonthStart.month;
            })
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key)),
      );
    } else {
      _dailyTotals = {};
    }

    setState(() {
      _leakEvents = tempLeaks;
      _lastUpdated = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final usageData = _viewMode == 'Monthly' ? _monthlyTotals : _dailyTotals;
    final keys = usageData.keys.toList();

    return Scaffold(
      appBar: AppBar(title: Text("Water Usage Chart")),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButton<String>(
                    value: _viewMode,
                    items: ['Monthly', 'Daily']
                        .map((v) => DropdownMenuItem(value: v, child: Text('View: $v')))
                        .toList(),
                    onChanged: (v) => setState(() => _viewMode = v!),
                  ),
                  SizedBox(height: 16),
                  Expanded(
                    flex: 2,
                    child: usageData.isEmpty
                        ? Center(child: Text("No data available"))
                        : LineChart(
                            LineChartData(
                              lineBarsData: [
                                LineChartBarData(
                                  spots: usageData.entries.mapIndexed((i, entry) {
                                    final y = entry.value;
                                    return FlSpot(i.toDouble(), y);
                                  }).toList(),
                                  isCurved: true,
                                  color: Colors.blue,
                                  barWidth: 3,
                                  dotData: FlDotData(show: true),
                                  belowBarData: BarAreaData(
                                    show: true,
                                    color: Colors.blue.withOpacity(0.3),
                                  ),
                                ),
                                for (final type in ['leak', 'prediction'])
                                  LineChartBarData(
                                    spots: _leakEvents.map((event) {
                                      if (event['type'] != type) return null;
                                      final timestamp = event['timestamp'] as DateTime;
                                      final flow = event['flow'] as double;

                                      final index = keys.indexWhere((k) {
                                        if (_viewMode == 'Monthly' && k is DateTime) {
                                          return timestamp.year == k.year && timestamp.month == k.month;
                                        } else if (_viewMode == 'Daily' && k is String) {
                                          final d = DateTime.tryParse(k);
                                          return d != null &&
                                              d.year == timestamp.year &&
                                              d.month == timestamp.month &&
                                              d.day == timestamp.day;
                                        }
                                        return false;
                                      });

                                      if (index != -1) {
                                        return FlSpot(index.toDouble(), flow);
                                      }
                                      return null;
                                    }).whereType<FlSpot>().toList(),
                                    isCurved: false,
                                    color: type == 'leak' ? Colors.red : Colors.amber,
                                    barWidth: 0,
                                    dotData: FlDotData(
                                      show: true,
                                      getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                                        radius: 4,
                                        color: type == 'leak' ? Colors.red : Colors.amber,
                                        strokeWidth: 0,
                                      ),
                                    ),
                                    belowBarData: BarAreaData(show: false),
                                  ),
                              ],
                              extraLinesData: ExtraLinesData(
                                horizontalLines: [
                                  HorizontalLine(
                                    y: _usageThreshold,
                                    color: Colors.red,
                                    strokeWidth: 2,
                                    dashArray: [5, 5],
                                    label: HorizontalLineLabel(
                                      show: true,
                                      labelResolver: (_) => 'Threshold: $_usageThreshold m³',
                                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                                      alignment: Alignment.topRight,
                                    ),
                                  ),
                                ],
                              ),
                              titlesData: FlTitlesData(
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    getTitlesWidget: (value, meta) {
                                      final idx = value.toInt();
                                      if (idx < 0 || idx >= keys.length) return SizedBox.shrink();
                                      final key = keys[idx];
                                      return RotatedBox(
                                        quarterTurns: 1,
                                        child: Text(
                                          _viewMode == 'Monthly'
                                              ? DateFormat('MMM').format(key as DateTime)
                                              : (key as String).substring(5),
                                          style: TextStyle(fontSize: 10),
                                        ),
                                      );
                                    },
                                    reservedSize: 40,
                                  ),
                                ),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    getTitlesWidget: (value, _) =>
                                        Text('${value.toStringAsFixed(1)} m³', style: TextStyle(fontSize: 10)),
                                    reservedSize: 40,
                                  ),
                                ),
                                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              ),
                              gridData: FlGridData(show: true),
                              borderData: FlBorderData(show: true),
                              lineTouchData: LineTouchData(
                                touchTooltipData: LineTouchTooltipData(
                                  tooltipBgColor: Colors.blueAccent,
                                  getTooltipItems: (spots) => spots.map((spot) {
                                    final key = keys[spot.x.toInt()];
                                    final label = _viewMode == 'Monthly'
                                        ? DateFormat('MMM yyyy').format(key as DateTime)
                                        : key as String;
                                    return LineTooltipItem(
                                      '$label\n${spot.y.toStringAsFixed(3)} m³',
                                      TextStyle(color: Colors.white),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
                  ),
                  if (_lastUpdated != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text("Last updated: $_lastUpdated"),
                    ),
                  SizedBox(height: 16),
                  Text("Leak History", style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: _leakEvents.isEmpty
                        ? Text("No leak occurrences recorded.")
                        : ListView.builder(
                            itemCount: _leakEvents.length,
                            itemBuilder: (_, i) {
                              final event = _leakEvents[i];
                              return ListTile(
                                leading: Icon(
                                  Icons.warning,
                                  color: event['type'] == 'leak' ? Colors.red : Colors.amber,
                                ),
                                title: Text(
                                  '${event['type'] == 'leak' ? 'Leak Detected' : 'Leak Prediction'} - ' +
                                  DateFormat('yyyy-MM-dd – HH:mm:ss').format(event['timestamp'])
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

// Extension to use mapIndexed
extension MapIndexedExtension<E> on Iterable<E> {
  Iterable<T> mapIndexed<T>(T Function(int, E) f) sync* {
    int index = 0;
    for (var element in this) {
      yield f(index++, element);
    }
  }
}
