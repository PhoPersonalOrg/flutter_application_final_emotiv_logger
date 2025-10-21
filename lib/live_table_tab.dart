import 'package:flutter/material.dart';

class LiveTableTab extends StatelessWidget {
  final List<Map<String, dynamic>> eegRecords;
  final bool isConnected;
  const LiveTableTab({super.key, required this.eegRecords, required this.isConnected});

  @override
  Widget build(BuildContext context) {
    if (!isConnected) {
      return const Center(
        child: Text('Not connected... Connect a headset to view table previews'),
      );
    }
    if (eegRecords.isEmpty) {
      return const Center(
        child: Text('No EEG data recorded yet...'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('EEG Data History (Last ${eegRecords.length} Records)',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: DataTable(
                      dataRowHeight: 30.0,
                      columnSpacing: 8.0,
                      horizontalMargin: 12.0,
                      columns: const [
                        DataColumn(label: Text('Time', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('AF3', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('F7', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('F3', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('FC5', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('T7', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('P7', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('O1', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('O2', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('P8', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('T8', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('FC6', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('F4', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('F8', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('AF4', style: TextStyle(fontWeight: FontWeight.bold))),
                      ],
                      rows: eegRecords.reversed.map((record) {
                        return DataRow(
                          cells: [
                            DataCell(
                              Text(
                                DateTime.fromMillisecondsSinceEpoch(record['timestamp']).toString().substring(11, 23),
                                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                              ),
                            ),
                            DataCell(Text(record['AF3'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['F7'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['F3'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['FC5'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['T7'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['P7'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['O1'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['O2'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['P8'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['T8'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['FC6'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['F4'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['F8'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                            DataCell(Text(record['AF4'].toStringAsFixed(3), style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


