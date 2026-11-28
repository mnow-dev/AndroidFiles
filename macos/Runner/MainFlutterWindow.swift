import Cocoa
import FlutterMacOS
import QuickLookUI
import UserNotifications

class MainFlutterWindow: NSWindow {
  /// Held while a backup runs; see lib/src/keep_awake.dart.
  private var backupActivity: NSObjectProtocol?
  private var quickLookController: NativeQuickLookWindowController?
  private var notificationHelper: MacNotificationHelper?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Proposal A (3-pane Finder & Inspector) needs room for the sidebar, file
    // tree, and backup/queue inspector to breathe comfortably on first launch.
    // Versioned autosave key ensures an older narrower 2-pane frame isn't
    // restored over the wider 3-pane default.
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let defaultH = min(680, max(580, screenFrame.height * 0.72))
    self.setContentSize(NSSize(width: 1080, height: defaultH))
    self.contentMinSize = NSSize(width: 840, height: 520)
    self.center()
    self.setFrameAutosaveName("AndroidFilesMainWindowV7")

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

    let qlChannel = FlutterMethodChannel(
      name: "androidfiles/quicklook",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let ql = NativeQuickLookWindowController(channel: qlChannel)
    self.quickLookController = ql
    qlChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "show":
        if let args = call.arguments as? [String: Any] {
          ql.showOrUpdate(args: args)
        }
        result(true)
      case "close":
        ql.closeWindow()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let notifChannel = FlutterMethodChannel(
      name: "androidfiles/notifications",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let notifHelper = MacNotificationHelper()
    self.notificationHelper = notifHelper
    notifChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "show":
        if let args = call.arguments as? [String: Any] {
          let title = (args["title"] as? String) ?? "AndroidFiles"
          let body = (args["body"] as? String) ?? ""
          notifHelper.show(title: title, body: body)
          result(true)
        } else {
          result(false)
        }
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

/// Separate, freely resizable (and fullscreen-capable) native macOS Quick Look
/// window powered by Apple's `QLPreviewView`. Can grow larger than the main
/// window, move to a second display, play videos with native AVKit controls,
/// scroll multi-page PDFs, and render HEIC/RAW/HTML/Markdown/Office docs.
private final class NativeQuickLookWindowController: NSObject, NSWindowDelegate {
  private let channel: FlutterMethodChannel
  private var window: NSWindow?
  private var keyMonitor: Any?

  // Header controls
  private let prevButton = NSButton()
  private let countLabel = NSTextField(labelWithString: "")
  private let nextButton = NSButton()
  private let metaLabel = NSTextField(labelWithString: "")
  private let saveButton = NSButton()
  private let openButton = NSButton()

  // Main stage
  private var previewView: QLPreviewView?
  private let overlayContainer = NSView()
  private let spinner = NSProgressIndicator()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let promptButton = NSButton()

  // Footer controls
  private let checkButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let hintLabel = NSTextField(labelWithString: "")

  private var currentFilePath: String?
  private var currentIsMedia: Bool = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  deinit {
    removeKeyMonitor()
  }

  private func ensureWindow() -> NSWindow {
    if let existing = window { return existing }

    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let initW = min(1160, max(900, visible.width * 0.76))
    let initH = min(800, max(640, visible.height * 0.80))

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: initW, height: initH),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    win.minSize = NSSize(width: 560, height: 420)
    win.collectionBehavior = [.fullScreenPrimary, .managed]
    win.isReleasedWhenClosed = false
    win.delegate = self
    win.center()
    win.setFrameAutosaveName("AndroidFilesQuickLookWindowV3")

    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    win.contentView = root

    // --- Header bar ---
    let header = NSVisualEffectView()
    header.material = .titlebar
    header.blendingMode = .withinWindow
    header.state = .followsWindowActiveState
    header.translatesAutoresizingMaskIntoConstraints = false

    let headerBorder = NSBox()
    headerBorder.boxType = .separator
    headerBorder.translatesAutoresizingMaskIntoConstraints = false

    prevButton.bezelStyle = .texturedRounded
    prevButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")
    prevButton.toolTip = "Previous file (←)"
    prevButton.target = self
    prevButton.action = #selector(onPrev)
    prevButton.translatesAutoresizingMaskIntoConstraints = false

    nextButton.bezelStyle = .texturedRounded
    nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")
    nextButton.toolTip = "Next file (→)"
    nextButton.target = self
    nextButton.action = #selector(onNext)
    nextButton.translatesAutoresizingMaskIntoConstraints = false

    countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    countLabel.textColor = .secondaryLabelColor
    countLabel.translatesAutoresizingMaskIntoConstraints = false

    metaLabel.font = NSFont.systemFont(ofSize: 12)
    metaLabel.textColor = .secondaryLabelColor
    metaLabel.lineBreakMode = .byTruncatingTail
    metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    metaLabel.translatesAutoresizingMaskIntoConstraints = false

    saveButton.title = "Save Copy…"
    saveButton.bezelStyle = .rounded
    saveButton.controlSize = .small
    saveButton.target = self
    saveButton.action = #selector(onSaveCopy)
    saveButton.translatesAutoresizingMaskIntoConstraints = false

    openButton.title = "Open"
    openButton.bezelStyle = .rounded
    openButton.controlSize = .small
    openButton.target = self
    openButton.action = #selector(onOpenExternal)
    openButton.translatesAutoresizingMaskIntoConstraints = false

    header.addSubview(prevButton)
    header.addSubview(countLabel)
    header.addSubview(nextButton)
    header.addSubview(metaLabel)
    header.addSubview(saveButton)
    header.addSubview(openButton)

    // --- Main QLPreviewView stage ---
    let stage = NSView()
    stage.translatesAutoresizingMaskIntoConstraints = false

    let qlView = QLPreviewView(frame: .zero, style: .normal)
    qlView?.autostarts = true
    qlView?.translatesAutoresizingMaskIntoConstraints = false
    if let qlView = qlView {
      stage.addSubview(qlView)
      NSLayoutConstraint.activate([
        qlView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
        qlView.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
        qlView.topAnchor.constraint(equalTo: stage.topAnchor),
        qlView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
      ])
    }
    self.previewView = qlView

    // Overlay for loading spinner / large-file download confirmation / errors
    overlayContainer.wantsLayer = true
    overlayContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    overlayContainer.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    spinner.style = .spinning
    spinner.controlSize = .regular
    spinner.isDisplayedWhenStopped = false

    statusLabel.font = NSFont.systemFont(ofSize: 13)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.maximumNumberOfLines = 4
    statusLabel.preferredMaxLayoutWidth = 420

    promptButton.bezelStyle = .rounded
    promptButton.controlSize = .regular
    promptButton.keyEquivalent = "\r"
    promptButton.target = self
    promptButton.action = #selector(onForceDownload)

    stack.addArrangedSubview(spinner)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(promptButton)
    overlayContainer.addSubview(stack)
    stage.addSubview(overlayContainer)

    NSLayoutConstraint.activate([
      overlayContainer.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
      overlayContainer.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
      overlayContainer.topAnchor.constraint(equalTo: stage.topAnchor),
      overlayContainer.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
      stack.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
    ])

    // --- Footer bar ---
    let footerBorder = NSBox()
    footerBorder.boxType = .separator
    footerBorder.translatesAutoresizingMaskIntoConstraints = false

    let footer = NSVisualEffectView()
    footer.material = .titlebar
    footer.blendingMode = .withinWindow
    footer.state = .followsWindowActiveState
    footer.translatesAutoresizingMaskIntoConstraints = false

    checkButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    checkButton.target = self
    checkButton.action = #selector(onToggleCheck)
    checkButton.translatesAutoresizingMaskIntoConstraints = false

    hintLabel.font = NSFont.systemFont(ofSize: 11)
    hintLabel.textColor = .tertiaryLabelColor
    hintLabel.translatesAutoresizingMaskIntoConstraints = false

    footer.addSubview(checkButton)
    footer.addSubview(hintLabel)

    root.addSubview(header)
    root.addSubview(headerBorder)
    root.addSubview(stage)
    root.addSubview(footerBorder)
    root.addSubview(footer)

    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      header.topAnchor.constraint(equalTo: root.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 40),

      prevButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
      prevButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      prevButton.widthAnchor.constraint(equalToConstant: 26),

      countLabel.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 6),
      countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

      nextButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 6),
      nextButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      nextButton.widthAnchor.constraint(equalToConstant: 26),

      metaLabel.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 14),
      metaLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -12),

      openButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
      openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

      saveButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
      saveButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

      headerBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      headerBorder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      headerBorder.topAnchor.constraint(equalTo: header.bottomAnchor),

      stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stage.topAnchor.constraint(equalTo: headerBorder.bottomAnchor),
      stage.bottomAnchor.constraint(equalTo: footerBorder.topAnchor),

      footerBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      footerBorder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      footerBorder.bottomAnchor.constraint(equalTo: footer.topAnchor),

      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      footer.heightAnchor.constraint(equalToConstant: 34),

      checkButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
      checkButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

      hintLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
      hintLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])

    self.window = win
    installKeyMonitor()
    return win
  }

  func showOrUpdate(args: [String: Any]) {
    let win = ensureWindow()
    let title = (args["title"] as? String) ?? "Quick Look"
    let subtitle = (args["subtitle"] as? String) ?? ""
    let index = (args["index"] as? Int) ?? 0
    let total = (args["total"] as? Int) ?? 1
    let filePath = args["filePath"] as? String
    let loading = (args["loading"] as? Bool) ?? false
    let message = args["message"] as? String
    let actionLabel = args["actionLabel"] as? String
    let canCheck = (args["canCheck"] as? Bool) ?? false
    let checked = (args["checked"] as? Bool) ?? false
    let checkLabel = (args["checkLabel"] as? String) ?? "Selected"
    let isMedia = (args["isMedia"] as? Bool) ?? false

    currentFilePath = filePath
    currentIsMedia = isMedia
    win.title = title

    let hasMultiple = total > 1
    prevButton.isHidden = !hasMultiple
    nextButton.isHidden = !hasMultiple
    countLabel.isHidden = !hasMultiple
    prevButton.isEnabled = index > 0
    nextButton.isEnabled = index + 1 < total
    countLabel.stringValue = "\(index + 1) / \(total)"
    metaLabel.stringValue = subtitle

    checkButton.isHidden = !canCheck
    checkButton.title = checkLabel
    checkButton.state = checked ? .on : .off

    if hasMultiple {
      hintLabel.stringValue = isMedia
          ? "← → navigate  ·  Esc close"
          : "← → navigate  ·  Space / Esc close"
    } else {
      hintLabel.stringValue = isMedia ? "Esc close" : "Space / Esc close"
    }

    if loading {
      previewView?.previewItem = nil
      overlayContainer.isHidden = false
      overlayContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      spinner.startAnimation(nil)
      statusLabel.stringValue = message ?? "Loading preview…"
      promptButton.isHidden = true
    } else if let path = filePath, FileManager.default.fileExists(atPath: path) {
      spinner.stopAnimation(nil)
      overlayContainer.isHidden = true
      previewView?.previewItem = URL(fileURLWithPath: path) as NSURL
    } else {
      previewView?.previewItem = nil
      spinner.stopAnimation(nil)
      overlayContainer.isHidden = false
      overlayContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      statusLabel.stringValue = message ?? "Preview unavailable."
      if let label = actionLabel, !label.isEmpty {
        promptButton.title = label
        promptButton.isHidden = false
      } else {
        promptButton.isHidden = true
      }
    }

    if !win.isVisible {
      win.makeKeyAndOrderFront(nil)
    } else {
      win.orderFront(nil)
    }
  }

  func closeWindow() {
    previewView?.previewItem = nil
    window?.orderOut(nil)
  }

  func windowWillClose(_ notification: Notification) {
    previewView?.previewItem = nil
    channel.invokeMethod("onClosed", arguments: nil)
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self, let win = self.window, win.isKeyWindow else {
        return event
      }
      switch event.keyCode {
      case 53: // Escape
        win.close()
        return nil
      case 49: // Space (let videos/audio use Space for play/pause!)
        if !self.currentIsMedia {
          win.close()
          return nil
        }
        return event
      case 123: // Left arrow
        self.onPrev()
        return nil
      case 124: // Right arrow
        self.onNext()
        return nil
      default:
        return event
      }
    }
  }

  private func removeKeyMonitor() {
    if let m = keyMonitor {
      NSEvent.removeMonitor(m)
      keyMonitor = nil
    }
  }

  @objc private func onPrev() {
    channel.invokeMethod("onNavigate", arguments: -1)
  }

  @objc private func onNext() {
    channel.invokeMethod("onNavigate", arguments: 1)
  }

  @objc private func onToggleCheck() {
    channel.invokeMethod("onToggleChecked", arguments: nil)
  }

  @objc private func onForceDownload() {
    channel.invokeMethod("onForceDownload", arguments: nil)
  }

  @objc private func onSaveCopy() {
    channel.invokeMethod("onSaveCopy", arguments: nil)
  }

  @objc private func onOpenExternal() {
    if let path = currentFilePath {
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
    } else {
      channel.invokeMethod("onOpenExternal", arguments: nil)
    }
  }
}

/// Native macOS notification delivery via `UNUserNotificationCenter` (replaces
/// the deprecated `NSUserNotification` API used by `local_notifier`).
private final class MacNotificationHelper: NSObject, UNUserNotificationCenterDelegate {
  private var delegateInstalled = false

  func show(title: String, body: String) {
    // UNUserNotificationCenter.current() throws an NSInternalInconsistencyException
    // if invoked from an unbundled process without a bundle identifier.
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    if !delegateInstalled {
      center.delegate = self
      delegateInstalled = true
    }
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil)
      center.add(request, withCompletionHandler: nil)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }
}
