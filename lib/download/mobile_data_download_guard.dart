import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../platform/download_network.dart';

class DownloadConfirmationCancelled implements Exception {
  const DownloadConfirmationCancelled();
}

enum MobileDataDownloadChoice { cancel, download, alwaysDownload }

class MobileDataDownloadRequest {
  MobileDataDownloadRequest(this.network);
  final DownloadNetwork network;
  final _answer = Completer<MobileDataDownloadChoice>();
  bool get answered => _answer.isCompleted;
}

class MobileDataDownloadGuard extends ChangeNotifier {
  MobileDataDownloadGuard({
    required this.supported,
    required this.readNetwork,
    required this.reminderEnabled,
    required this.disableReminder,
  });

  final bool supported;
  final Future<DownloadNetwork> Function() readNetwork;
  final bool Function() reminderEnabled;
  final Future<void> Function() disableReminder;
  final _gate = AsyncGate();
  MobileDataDownloadRequest? _request;
  MobileDataDownloadRequest? get request => _closed ? null : _request;
  bool _closed = false, _presenterAttached = false;

  void attachPresenter() => _presenterAttached = true;

  void detachPresenter() {
    _presenterAttached = false;
    final request = _request;
    if (request != null) answer(request, MobileDataDownloadChoice.cancel);
  }

  // One check per user action/batch. This gate is independent of the download
  // scheduler, so saving preferences and stopping transfers remain possible.
  Future<void> confirm() => _gate.run(() async {
    RequestScope.checkpoint();
    if (_closed) throw const DownloadConfirmationCancelled();
    if (!supported || !reminderEnabled()) return;
    final network = await RequestScope.cancellable(readNetwork());
    if (_closed) throw const DownloadConfirmationCancelled();
    if (network == DownloadNetwork.other || !reminderEnabled()) return;
    if (!_presenterAttached) throw const DownloadConfirmationCancelled();
    final request = _request = MobileDataDownloadRequest(network);
    notifyListeners();
    try {
      final choice = await RequestScope.cancellable(request._answer.future);
      if (_closed || choice == MobileDataDownloadChoice.cancel) {
        throw const DownloadConfirmationCancelled();
      }
      if (choice == MobileDataDownloadChoice.alwaysDownload) {
        await disableReminder();
      }
      RequestScope.checkpoint();
      if (_closed) throw const DownloadConfirmationCancelled();
    } finally {
      _request = null;
      if (!_closed) notifyListeners();
    }
  });

  void answer(
    MobileDataDownloadRequest request,
    MobileDataDownloadChoice choice,
  ) {
    if (identical(_request, request) && !request._answer.isCompleted) {
      request._answer.complete(choice);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    detachPresenter();
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
