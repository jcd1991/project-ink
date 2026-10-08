import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/native_pencil_packet_metrics.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

void main() {
  test('tracks confirmed pressure and returns the first edge crossing', () {
    final metrics = NativePencilPacketMetrics()..beginStroke();
    final inside = metrics.observePacket(
      _packet(InkPointerPhase.down, x: 10, pressure: 0.4),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    expect(inside.crossingSampleCount, isNull);

    final move = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 20, pressure: 0.7),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    expect(move.crossingSampleCount, isNull);

    final crossing = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 120, pressure: 0.9),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    expect(crossing.crossingSampleCount, 1);
    expect(crossing.crossingPosition, const Offset(120, 20));
    expect(metrics.packetCount, 3);
    expect(metrics.sampleCount, 3);
    expect(metrics.minPressure, closeTo(0.4, 0.000001));
    expect(metrics.maxPressure, closeTo(0.9, 0.000001));
    expect(metrics.lastConfirmedSampleInside, isFalse);
  });

  test('predicted samples do not change confirmed page-edge state', () {
    final metrics = NativePencilPacketMetrics()..beginStroke();
    metrics.observePacket(
      _packet(InkPointerPhase.down, x: 10),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    final predicted = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 120, flags: inkPointerPredicted),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    expect(predicted.crossingSampleCount, isNull);
    expect(metrics.lastConfirmedSampleInside, isTrue);

    final confirmed = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 120),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    expect(confirmed.crossingSampleCount, 1);
  });

  test('identifies confirmed re-entry after boundary capture ended', () {
    final metrics = NativePencilPacketMetrics()..beginStroke();
    metrics.observePacket(
      _packet(InkPointerPhase.down, x: 10),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    metrics.observePacket(
      _packet(InkPointerPhase.move, x: 120),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );

    final outside = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 140),
      captureAlreadyEnded: true,
      isInsideDocument: _isInside,
    );
    expect(outside.reentrySampleIndex, isNull);

    final reentry = metrics.observePacket(
      _packet(InkPointerPhase.move, x: 40),
      captureAlreadyEnded: true,
      isInsideDocument: _isInside,
    );
    expect(reentry.reentrySampleIndex, 0);
    expect(reentry.crossingSampleCount, isNull);
    expect(metrics.lastConfirmedSampleInside, isTrue);
  });

  test('reports exit and re-entry within one coalesced packet', () {
    final metrics = NativePencilPacketMetrics()..beginStroke();
    metrics.observePacket(
      _packet(InkPointerPhase.down, x: 10),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );
    final crossingAndReentry = metrics.observePacket(
      _batch(<Uint8List>[
        _packet(InkPointerPhase.move, x: 120),
        _packet(InkPointerPhase.move, x: 40),
      ]),
      captureAlreadyEnded: false,
      isInsideDocument: _isInside,
    );

    expect(crossingAndReentry.crossingSampleCount, 1);
    expect(crossingAndReentry.reentrySampleIndex, 1);
    expect(metrics.lastConfirmedSampleInside, isTrue);
  });
}

Uint8List _batch(List<Uint8List> samples) {
  final packet = Uint8List(4 + samples.length * 48);
  final data = ByteData.sublistView(packet);
  data.setUint16(0, 1, Endian.little);
  data.setUint16(2, samples.length, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    packet.setRange(4 + index * 48, 4 + (index + 1) * 48, samples[index], 4);
  }
  return packet;
}

bool _isInside(Offset position) => position.dx >= 0 && position.dx < 100;

Uint8List _packet(
  InkPointerPhase phase, {
  required double x,
  double pressure = 1,
  int flags = inkPointerActual,
}) => encodePointerPacket(
  pointerId: 3,
  device: InkPointerDevice.stylus,
  phase: phase,
  x: x,
  y: 20,
  pressure: pressure,
  timestampNs: 1,
  sequence: 1,
  flags: flags,
);
