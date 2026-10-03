import 'dart:async';

/// Blocks new canvas input while an ordered document replacement is prepared.
///
/// The caller supplies the operations that drain and retire its current input
/// session, so this class owns sequencing without owning canvas or Rust state.
class DocumentReplacementBarrier {
  DocumentReplacementBarrier({
    required Future<void> Function() drainAcceptedInput,
    required Future<void> Function() cancelActiveStroke,
    required Future<void> Function() flushRecovery,
    required void Function(bool active) onChanged,
  }) : _drainAcceptedInput = drainAcceptedInput,
       _cancelActiveStroke = cancelActiveStroke,
       _flushRecovery = flushRecovery,
       _onChanged = onChanged;

  final Future<void> Function() _drainAcceptedInput;
  final Future<void> Function() _cancelActiveStroke;
  final Future<void> Function() _flushRecovery;
  final void Function(bool active) _onChanged;
  bool _active = false;

  bool get isActive => _active;

  Future<void> run(Future<void> Function() replaceDocument) async {
    if (_active) return;
    _active = true;
    _onChanged(true);
    try {
      await _drainAcceptedInput();
      await _cancelActiveStroke();
      await _flushRecovery();
      await replaceDocument();
    } finally {
      _active = false;
      _onChanged(false);
    }
  }
}
