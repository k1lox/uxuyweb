import 'dart:async';

/// A shared wall-clock budget for read-only checks. Never wrap a signed submission
/// in a timeout: a transport timeout does not cancel an accepted transaction.
class PreviewDeadline {
  final Stopwatch _clock = Stopwatch()..start();
  Future<T> read<T>(Future<T> Function() operation) {
    final remaining = const Duration(seconds: 2) - _clock.elapsed;
    StateError timeout() => StateError('检查超过 2 秒，请稍后重试。本次未提交交易。');
    if (remaining <= Duration.zero) throw timeout();
    return operation().timeout(remaining, onTimeout: () => throw timeout());
  }
}

class PreviewCancelled extends StateError {
  PreviewCancelled() : super('已取消准备');
}

/// Quotes may be queued upstream. Show progress once, keep the original request,
/// and abandon its result immediately if the user leaves or cancels.
class QuoteProgress {
  QuoteProgress(void Function() onSlow) {
    _timer = Timer(const Duration(seconds: 2), () {
      slow = true;
      onSlow();
    });
  }
  late final Timer _timer;
  final _cancelled = Completer<void>();
  bool slow = false;
  bool get cancelled => _cancelled.isCompleted;
  Future<T> read<T>(Future<T> Function() operation) {
    if (_cancelled.isCompleted) throw PreviewCancelled();
    return Future.any([
      operation(),
      _cancelled.future.then<T>((_) => throw PreviewCancelled()),
    ]);
  }

  void cancel() {
    _timer.cancel();
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void finish() => _timer.cancel();
}
