import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    (mainFlutterWindow as? MainFlutterWindow)?.receive(urls: urls)
  }

  // The app lives in the menu-bar tray and hides its window on close, so keep
  // running after the last window closes. Actual exit goes through exit(0) from
  // Dart when the tray "退出" item is chosen.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
