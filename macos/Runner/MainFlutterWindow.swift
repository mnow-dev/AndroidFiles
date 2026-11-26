import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Held while a backup runs; see lib/src/keep_awake.dart.
  private var backupActivity: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Proposal A (3-pane Finder & Inspector) needs room for the sidebar, file
    // tree, and backup/queue inspector to breathe comfortably on first launch.
    // Versioned autosave key ensures an older narrower 2-pane frame isn't
    // restored over the wider 3-pane default.
    self.setContentSize(NSSize(width: 1080, height: 700))
    self.contentMinSize = NSSize(width: 840, height: 520)
    self.center()
    self.setFrameAutosaveName("AndroidFilesMainWindowV3")

    // Unified transparent titlebar so Flutter renders behind the traffic
    // lights (Finder / Disk Utility style). An empty unified toolbar centers
    // the traffic lights cleanly inside the 48pt top chrome.
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    let toolbar = NSToolbar(identifier: "AndroidFilesUnifiedToolbar")
    toolbar.showsBaselineSeparator = false
    self.toolbar = toolbar
    if #available(macOS 11.0, *) {
      self.toolbarStyle = .unified
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    let power = FlutterMethodChannel(
      name: "androidfiles/power",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    power.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "keepAwake":
        self.setKeepAwake((call.arguments as? Bool) ?? false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let windowChannel = FlutterMethodChannel(
      name: "androidfiles/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "startDrag":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "titlebarDoubleClick":
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" {
          self.miniaturize(nil)
        } else if action != "None" {
          self.zoom(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  /// .userInitiated holds off idle system sleep and App Nap (which would
  /// throttle the transfer once the window is in the background); the display
  /// is still free to sleep.
  private func setKeepAwake(_ on: Bool) {
    if on, backupActivity == nil {
      backupActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Backing up an Android phone")
    } else if !on, let activity = backupActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backupActivity = nil
    }
  }
}
