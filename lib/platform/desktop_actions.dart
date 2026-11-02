/// Desktop-only integrations that need a native shell command: revealing a
/// finished download in the file manager and powering the machine off after
/// every transfer has been saved.
///
/// Implementations live in `windows_actions.dart` and `linux_actions.dart`;
/// both validate the path themselves before spawning any process.
abstract class DesktopActions {
  /// Whether this platform implements the actions at all.
  bool get supported;

  Future<void> revealFile(String path);
  Future<void> shutdown();

  /// Suspends the machine to disk once every transfer has been saved.
  Future<void> hibernate();
}
