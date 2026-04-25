import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let selectionTextLogger = HexLog.pasteboard

@DependencyClient
struct SelectionTextClient: Sendable {
  struct FrontmostApp: Equatable, Sendable {
    var bundleIdentifier: String?
    var localizedName: String?
  }

  var frontmostApp: @Sendable () async -> FrontmostApp? = { nil }
  var captureSelectedText: @Sendable () async -> String? = { nil }
  var replaceSelectedText: @Sendable (String) async -> Bool = { _ in false }
  var copySelectionToClipboard: @Sendable () async -> Bool = { false }
  var pasteClipboardToSelection: @Sendable () async -> Bool = { false }
  var selectAll: @Sendable () async -> Bool = { false }
  var selectLeftCharacters: @Sendable (Int) async -> Bool = { _ in false }
  var insertTextViaAccessibility: @Sendable (String) async -> Bool = { _ in false }
  var maxSelectedTextLength: @Sendable () -> Int = { Self.defaultMaxSelectedTextLength }
  var isWithinMaxSelectedTextLength: @Sendable (String) -> Bool = {
    $0.count <= Self.defaultMaxSelectedTextLength
  }

  static let defaultMaxSelectedTextLength = 20_000
}

extension SelectionTextClient: DependencyKey {
  static var liveValue: Self {
    let live = SelectionTextClientLive()
    return Self(
      frontmostApp: {
        await live.frontmostApp()
      },
      captureSelectedText: {
        await live.captureSelectedText()
      },
      replaceSelectedText: { replacement in
        await live.replaceSelectedText(with: replacement)
      },
      copySelectionToClipboard: {
        await live.copySelectionToClipboard()
      },
      pasteClipboardToSelection: {
        await live.pasteClipboardToSelection()
      },
      selectAll: {
        await live.selectAll()
      },
      selectLeftCharacters: { count in
        await live.selectLeftCharacters(count)
      },
      insertTextViaAccessibility: { text in
        await live.insertTextViaAccessibility(text)
      },
      maxSelectedTextLength: {
        SelectionTextClient.defaultMaxSelectedTextLength
      },
      isWithinMaxSelectedTextLength: { text in
        text.count <= SelectionTextClient.defaultMaxSelectedTextLength
      }
    )
  }

  static var testValue: Self {
    Self()
  }
}

extension DependencyValues {
  var selectionText: SelectionTextClient {
    get { self[SelectionTextClient.self] }
    set { self[SelectionTextClient.self] = newValue }
  }
}

private final class SelectionTextClientLive {
  private enum ShortcutKey {
    case c
    case v
    case a
    case leftArrow
  }

  private struct PasteboardSnapshot {
    let items: [[String: Data]]

    init(pasteboard: NSPasteboard) {
      var savedItems: [[String: Data]] = []
      for item in pasteboard.pasteboardItems ?? [] {
        var savedItem: [String: Data] = [:]
        for type in item.types {
          if let data = item.data(forType: type) {
            savedItem[type.rawValue] = data
          }
        }
        savedItems.append(savedItem)
      }
      self.items = savedItems
    }

    func restore(to pasteboard: NSPasteboard) {
      pasteboard.clearContents()
      let restoredItems = items.compactMap { itemData -> NSPasteboardItem? in
        let item = NSPasteboardItem()
        for (typeRawValue, data) in itemData {
          item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: typeRawValue))
        }
        return item
      }
      if !restoredItems.isEmpty {
        pasteboard.writeObjects(restoredItems)
      }
    }
  }

  private static let terminalBundleIdentifiers: Set<String> = [
    "com.mitchellh.ghostty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
  ]

  func frontmostApp() -> SelectionTextClient.FrontmostApp? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return .init(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
  }

  func captureSelectedText() async -> String? {
    if let text = captureSelectedTextViaAccessibility() {
      return text
    }

    return await captureSelectedTextViaClipboardFallback()
  }

  func replaceSelectedText(with replacement: String) async -> Bool {
    if await replaceSelectedTextViaClipboardPaste(with: replacement) {
      return true
    }

    return insertTextViaAccessibility(replacement)
  }

  func copySelectionToClipboard() async -> Bool {
    let useTerminalShortcut = shouldUseTerminalShortcuts(for: frontmostBundleIdentifier())
    return postShortcut(
      key: .c,
      withCommand: true,
      withShift: useTerminalShortcut
    )
  }

  func pasteClipboardToSelection() async -> Bool {
    let useTerminalShortcut = shouldUseTerminalShortcuts(for: frontmostBundleIdentifier())
    return postShortcut(
      key: .v,
      withCommand: true,
      withShift: useTerminalShortcut
    )
  }

  func selectAll() async -> Bool {
    postShortcut(key: .a, withCommand: true, withShift: false)
  }

  func selectLeftCharacters(_ count: Int) async -> Bool {
    guard count > 0 else { return false }

    for _ in 0 ..< count {
      let didPostShortcut = postShortcut(key: .leftArrow, withCommand: false, withShift: true)
      if !didPostShortcut {
        return false
      }
      try? await Task.sleep(for: .milliseconds(2))
    }

    return true
  }

  func insertTextViaAccessibility(_ text: String) -> Bool {
    for element in focusedElementAncestry(maxDepth: 10) {
      let result = AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        text as CFTypeRef
      )
      if result == .success {
        return true
      }
    }

    selectionTextLogger.debug("AX insertion fallback failed for focused ancestry.")
    return false
  }

  private func captureSelectedTextViaAccessibility() -> String? {
    for element in focusedElementAncestry(maxDepth: 10) {
      if let selectedText = selectedTextAttributeValue(from: element), !selectedText.isEmpty {
        return selectedText
      }
      if let selectedText = selectedTextUsingRange(from: element), !selectedText.isEmpty {
        return selectedText
      }
    }
    return nil
  }

  private func captureSelectedTextViaClipboardFallback() async -> String? {
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    let token = "hex-selection-token-\(UUID().uuidString)"

    pasteboard.clearContents()
    pasteboard.setString(token, forType: .string)
    let baselineChangeCount = pasteboard.changeCount

    let copyShortcutWorked = await copySelectionToClipboard()
    if !copyShortcutWorked {
      selectionTextLogger.debug("Copy shortcut event posting failed; trying menu fallback.")
    }

    var captured = await waitForClipboardStringChange(
      excludingToken: token,
      afterChangeCount: baselineChangeCount,
      timeout: .milliseconds(220)
    )

    if captured == nil, executeMenuCopyFallback() {
      captured = await waitForClipboardStringChange(
        excludingToken: token,
        afterChangeCount: baselineChangeCount,
        timeout: .milliseconds(280)
      )
    }

    let expectedChangeCount = pasteboard.changeCount
    await restoreClipboardSnapshotIfUnchanged(
      snapshot,
      expectedChangeCount: expectedChangeCount,
      delay: .milliseconds(captured == nil ? 80 : 260)
    )

    return captured
  }

  private func replaceSelectedTextViaClipboardPaste(with replacement: String) async -> Bool {
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

    pasteboard.clearContents()
    pasteboard.setString(replacement, forType: .string)
    let expectedChangeCount = pasteboard.changeCount

    let pasted = await pasteClipboardToSelection()
    await restoreClipboardSnapshotIfUnchanged(
      snapshot,
      expectedChangeCount: expectedChangeCount,
      delay: .milliseconds(pasted ? 260 : 120)
    )

    if !pasted {
      selectionTextLogger.debug("Paste shortcut path failed; using AX insertion fallback.")
    }

    return pasted
  }

  private func focusedElementAncestry(maxDepth: Int) -> [AXUIElement] {
    guard let focusedElement = focusedElement() else { return [] }
    var ancestry: [AXUIElement] = []
    var currentElement: AXUIElement? = focusedElement

    while let element = currentElement, ancestry.count < maxDepth {
      ancestry.append(element)

      var parentRef: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(
        element,
        kAXParentAttribute as CFString,
        &parentRef
      )
      guard result == .success, let parentRef else { break }
      currentElement = unsafeBitCast(parentRef, to: AXUIElement.self)
    }

    return ancestry
  }

  private func focusedElement() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let systemResult = AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedRef
    )
    if systemResult == .success, let focusedRef {
      return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var appFocusedRef: CFTypeRef?
    let appResult = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &appFocusedRef
    )
    if appResult == .success, let appFocusedRef {
      return unsafeBitCast(appFocusedRef, to: AXUIElement.self)
    }

    return nil
  }

  private func selectedTextAttributeValue(from element: AXUIElement) -> String? {
    var selectedRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      &selectedRef
    )
    guard result == .success else { return nil }
    return selectedRef as? String
  }

  private func selectedTextUsingRange(from element: AXUIElement) -> String? {
    var rangeRef: CFTypeRef?
    let rangeResult = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &rangeRef
    )
    guard rangeResult == .success, let rangeRef else { return nil }
    let rangeValue = unsafeBitCast(rangeRef, to: AXValue.self)

    var selectedRange = CFRange()
    guard AXValueGetType(rangeValue) == .cfRange else { return nil }
    guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else { return nil }
    guard selectedRange.length > 0 else { return nil }

    var stringRef: CFTypeRef?
    let stringResult = AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &stringRef
    )
    guard stringResult == .success else { return nil }
    return stringRef as? String
  }

  private func waitForClipboardStringChange(
    excludingToken token: String,
    afterChangeCount changeCount: Int,
    timeout: Duration
  ) async -> String? {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      let pasteboard = NSPasteboard.general
      if pasteboard.changeCount > changeCount,
         let clipboardString = pasteboard.string(forType: .string),
         clipboardString != token {
        return clipboardString
      }

      try? await Task.sleep(for: .milliseconds(15))
    }

    return nil
  }

  // We only restore when clipboard ownership has not changed since our operation.
  private func restoreClipboardSnapshotIfUnchanged(
    _ snapshot: PasteboardSnapshot,
    expectedChangeCount: Int,
    delay: Duration
  ) async {
    try? await Task.sleep(for: delay)
    let pasteboard = NSPasteboard.general

    guard pasteboard.changeCount == expectedChangeCount else {
      selectionTextLogger.debug("Skipping clipboard restore because clipboard changed externally.")
      return
    }

    snapshot.restore(to: pasteboard)
  }

  private func frontmostBundleIdentifier() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }

  private func shouldUseTerminalShortcuts(for bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return Self.terminalBundleIdentifiers.contains(bundleIdentifier)
  }

  private func postShortcut(
    key: ShortcutKey,
    withCommand: Bool,
    withShift: Bool
  ) -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      selectionTextLogger.error("Failed to create CGEventSource for shortcut posting.")
      return false
    }

    let keyCode = keyCode(for: key)
    let commandCode: CGKeyCode = 55
    let shiftCode: CGKeyCode = 56

    var flags = CGEventFlags()
    if withCommand { flags.insert(.maskCommand) }
    if withShift { flags.insert(.maskShift) }

    if withCommand {
      CGEvent(keyboardEventSource: source, virtualKey: commandCode, keyDown: true)?.post(tap: .cghidEventTap)
    }
    if withShift {
      CGEvent(keyboardEventSource: source, virtualKey: shiftCode, keyDown: true)?.post(tap: .cghidEventTap)
    }

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = flags
    keyDown?.post(tap: .cghidEventTap)

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = flags
    keyUp?.post(tap: .cghidEventTap)

    if withShift {
      CGEvent(keyboardEventSource: source, virtualKey: shiftCode, keyDown: false)?.post(tap: .cghidEventTap)
    }
    if withCommand {
      CGEvent(keyboardEventSource: source, virtualKey: commandCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    return true
  }

  private func keyCode(for key: ShortcutKey) -> CGKeyCode {
    switch key {
    case .a:
      0
    case .c:
      8
    case .v:
      9
    case .leftArrow:
      123
    }
  }

  private func executeMenuCopyFallback() -> Bool {
    let script = """
    if application "System Events" is not running then
        tell application "System Events" to launch
        delay 0.1
    end if
    tell application "System Events"
        tell process (name of first application process whose frontmost is true)
            tell (menu item "Copy" of menu of menu item "Copy" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                if exists then
                    if enabled then
                        click it
                        return true
                    else
                        return false
                    end if
                end if
            end tell
            tell (menu item "Copy" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                if exists then
                    if enabled then
                        click it
                        return true
                    else
                        return false
                    end if
                else
                    return false
                end if
            end tell
        end tell
    end tell
    """

    var error: NSDictionary?
    guard let scriptObject = NSAppleScript(source: script) else {
      selectionTextLogger.error("Failed to create AppleScript object for menu copy fallback.")
      return false
    }

    let result = scriptObject.executeAndReturnError(&error)
    if let error {
      selectionTextLogger.error("Menu copy fallback AppleScript failed: \(error)")
      return false
    }
    return result.booleanValue
  }
}
