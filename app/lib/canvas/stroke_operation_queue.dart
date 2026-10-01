import 'dart:async';
import 'dart:collection';

typedef StrokeQueueOperation = Future<void> Function();
typedef StrokeQueueErrorHandler =
    Future<void> Function(Object error, StackTrace stack);

/// Runs stroke-related bridge work in arrival order and recovers after failures.
///
/// A failed operation is reported to [onError], then later queued operations
/// continue. This keeps one transient pointer or bridge failure from poisoning
/// every stroke that follows it.
class StrokeOperationQueue {
  StrokeOperationQueue({required this.onError});

  final StrokeQueueErrorHandler onError;
  final Queue<StrokeQueueOperation> _operations = Queue<StrokeQueueOperation>();
  Future<void> _work = Future<void>.value();
  bool _draining = false;

  int get pendingCount => _operations.length;
  Future<void> get idle => _work;

  void enqueue(StrokeQueueOperation operation) {
    _operations.add(operation);
    if (_draining) return;
    _draining = true;
    _work = _drain();
  }

  Future<void> _drain() async {
    while (_operations.isNotEmpty) {
      final operation = _operations.removeFirst();
      try {
        await operation();
      } catch (error, stack) {
        await onError(error, stack);
      }
    }
    _draining = false;
    if (_operations.isNotEmpty) {
      _draining = true;
      _work = _drain();
    }
  }
}
