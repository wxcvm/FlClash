import 'dart:io';

import 'package:flutter/material.dart';

class StatisticsRecordsScreen extends StatefulWidget {
  const StatisticsRecordsScreen({
    super.key,
    required this.dbPath,
    required this.currentDB,
  });

  final String dbPath;
  final bool currentDB;

  static RouteSettings routeSettings() {
    return const RouteSettings(name: 'StatisticsRecordsScreen');
  }

  @override
  State<StatisticsRecordsScreen> createState() =>
      _StatisticsRecordsScreenState();
}

class _StatisticsRecordsScreenState extends State<StatisticsRecordsScreen> {
  List<({String path, FileStat stat})> _stats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = Directory(widget.dbPath);
      final entities = dir.existsSync()
          ? dir.listSync(recursive: false).toList()
          : <FileSystemEntity>[];
      final stats = <({String path, FileStat stat})>[];
      for (final entity in entities) {
        if (entity is File) {
          stats.add((path: entity.path, stat: await entity.stat()));
        }
      }
      if (mounted) {
        setState(() {
          _stats = stats;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.dbPath)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stats.isEmpty
              ? const Center(child: Text('No statistics records'))
              : ListView.builder(
                  itemCount: _stats.length,
                  itemBuilder: (context, index) {
                    final stat = _stats[index];
                    return ListTile(
                      title: Text(stat.path),
                      subtitle: Text(
                        '${stat.stat.size} bytes, modified ${stat.stat.modified}',
                      ),
                      trailing: widget.currentDB
                          ? const Icon(Icons.check_circle)
                          : null,
                    );
                  },
                ),
    );
  }
}
