import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const targetsMs = <String, double>{
  'ipad-m1': 40,
  'ipad-m4': 25,
  'android-s23': 40,
};

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'usage: dart tools/phase1_trace_report.dart TRACE.jsonl [device]',
    );
    exitCode = 64;
    return;
  }

  final path = args.first;
  final device = args.length == 2 ? args[1] : 'unbounded';
  final target = targetsMs[device];
  final file = File(path);
  if (!await file.exists()) {
    stderr.writeln('trace file does not exist: $path');
    exitCode = 66;
    return;
  }

  final records = <Map<String, dynamic>>[];
  for (final line in await file.readAsLines()) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) records.add(decoded);
    } on FormatException {
      // A terminated write may leave a partial final line; ignore it.
    }
  }
  if (records.isEmpty) {
    stderr.writeln('trace contains no complete JSON records: $path');
    exitCode = 65;
    return;
  }

  final p95 = records
      .map((record) => record['p95_pointer_to_visible_ms'])
      .whereType<num>()
      .map((value) => value.toDouble())
      .fold<double?>(null, (maximum, value) {
        if (maximum == null || value > maximum) return value;
        return maximum;
      });
  final latest = records.last;
  final maxRejectedPackets = records
      .map((record) => record['rejected_packet_count'])
      .whereType<num>()
      .fold<int>(0, (maximum, value) => math.max(maximum, value.toInt()));
  final maxRejectedConfirmedSamples = records
      .map((record) => record['rejected_confirmed_sample_count'])
      .whereType<num>()
      .fold<int>(0, (maximum, value) => math.max(maximum, value.toInt()));
  final maxInputSequenceGaps = records
      .map((record) => record['input_sequence_gap_count'])
      .whereType<num>()
      .fold<int>(0, (maximum, value) => math.max(maximum, value.toInt()));
  const deliveryFields = <String>[
    'confirmed_sample_count',
    'predicted_sample_count',
    'input_sequence_gap_count',
    'rejected_packet_count',
    'rejected_confirmed_sample_count',
  ];
  final deliverySchemaPresent = records.every(
    (record) => deliveryFields.every(record.containsKey),
  );
  final confirmedDeliveryPass =
      deliverySchemaPresent &&
      maxRejectedConfirmedSamples == 0 &&
      maxInputSequenceGaps == 0;
  final latencyPass = target == null || (p95 != null && p95 <= target);
  final report = <String, Object?>{
    'device': device,
    'records': records.length,
    'latest_packet_count': latest['packet_count'],
    'latest_sample_count': latest['sample_count'],
    'latest_confirmed_sample_count': latest['confirmed_sample_count'],
    'latest_predicted_sample_count': latest['predicted_sample_count'],
    'latest_input_sequence_gap_count': latest['input_sequence_gap_count'],
    'latest_rejected_packet_count': latest['rejected_packet_count'],
    'latest_rejected_confirmed_sample_count':
        latest['rejected_confirmed_sample_count'],
    'latest_visible_update_count': latest['visible_update_count'],
    'latest_dirty_tile_count': latest['dirty_tile_count'],
    'latest_trace_rss_bytes': latest['rss_bytes'],
    'worst_recorded_p95_pointer_to_visible_ms': p95,
    'target_ms': target,
    'target_pass': latencyPass,
    'worst_rejected_packet_count': maxRejectedPackets,
    'worst_rejected_confirmed_sample_count': maxRejectedConfirmedSamples,
    'worst_input_sequence_gap_count': maxInputSequenceGaps,
    'confirmed_delivery_schema_present': deliverySchemaPresent,
    'confirmed_sample_delivery_pass': confirmedDeliveryPass,
    'acceptance_pass': latencyPass && confirmedDeliveryPass,
    'rss_source':
        'optional native trace sample; capture platform tooling for authority',
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if (!latencyPass || !confirmedDeliveryPass) exitCode = 1;
}
