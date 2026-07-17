/// Data models shared across the app.
library;

class AdbDevice {
  final String serial;
  final String state; // device | unauthorized | offline
  final String model;

  const AdbDevice({required this.serial, required this.state, required this.model});

  bool get isReady => state == 'device';

  bool get isWireless =>
      serial.contains(':') || serial.contains('_adb-tls-connect');

  String get label => model.isEmpty ? serial : '$model ($serial)';

  @override
  bool operator ==(Object other) =>
      other is AdbDevice && other.serial == serial && other.state == state;

  @override
  int get hashCode => Object.hash(serial, state);
}

class RemoteEntry {
  final String name;
  final String path; // absolute path on device
  final bool isDir;
  final bool isLink;
  final int size;
  final String modified;

  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.isLink = false,
    this.size = 0,
    this.modified = '',
  });
}

enum BackupLayout { mirror, snapshot }

enum JobStatus { queued, measuring, running, verifying, done, doneWithWarnings, failed, cancelled }

extension JobStatusLabel on JobStatus {
  String get label => switch (this) {
        JobStatus.queued => 'queued',
        JobStatus.measuring => 'measuring…',
        JobStatus.running => 'copying',
        JobStatus.verifying => 'verifying',
        JobStatus.done => 'done',
        JobStatus.doneWithWarnings => 'done (warnings)',
        JobStatus.failed => 'failed',
        JobStatus.cancelled => 'cancelled',
      };

  bool get isTerminal =>
      this == JobStatus.done ||
      this == JobStatus.doneWithWarnings ||
      this == JobStatus.failed ||
      this == JobStatus.cancelled;
}
