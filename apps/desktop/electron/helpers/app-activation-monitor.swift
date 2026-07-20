import AppKit
import Foundation

// Emits one JSON line per macOS app activation / Space change so Open Assist
// can react instantly (the polling fallback takes 1-2s and feels sluggish).
// Exits when stdin closes so it can never outlive the app that spawned it.

setbuf(stdout, nil)

func emit(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object),
        let line = String(data: data, encoding: .utf8) else { return }
  print(line)
}

let center = NSWorkspace.shared.notificationCenter

center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
  guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
  emit([
    "event": "activate",
    "pid": Int(app.processIdentifier),
    "bundleID": app.bundleIdentifier ?? "",
    "name": app.localizedName ?? ""
  ])
}

center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
  emit(["event": "spaceChanged"])
}

DispatchQueue.global(qos: .utility).async {
  while readLine(strippingNewline: false) != nil {}
  exit(0)
}

emit(["event": "ready"])
RunLoop.main.run()
