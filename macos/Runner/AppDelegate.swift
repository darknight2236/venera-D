import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var flutterResult: FlutterResult?

  /// Security-scoped grants handed out by the open panel, keyed by path, so a
  /// revoke can only drop the directory it was granted for.
  var grantedDirectories: [String: URL] = [:]

  override func applicationDidFinishLaunching(_ notification: Notification) {
      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
      let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.engine.binaryMessenger)

      methodChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "getProxy":
            if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary? {
                if let httpProxy = proxySettings[kCFNetworkProxiesHTTPProxy] as? String,
                   let httpPort = proxySettings[kCFNetworkProxiesHTTPPort] as? Int {
                    let proxyConfig = "\(httpProxy):\(httpPort)"
                    result(proxyConfig)
                } else if let socksProxy = proxySettings[kCFNetworkProxiesSOCKSProxy] as? String,
                          let socksPort = proxySettings[kCFNetworkProxiesSOCKSPort] as? Int {
                    let proxyConfig = "\(socksProxy):\(socksPort)"
                    result(proxyConfig)
                } else {
                    result("")
                }
            } else {
                result("")
            }
        case "getDirectoryPath":
          self.flutterResult = result
          self.getDirectoryPath()
        case "stopAccessingSecurityScopedResource":
          // An unknown path is ignored rather than cancelling whatever grant
          // happens to be current.
          if let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let url = grantedDirectories.removeValue(forKey: path) {
            url.stopAccessingSecurityScopedResource()
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let clipboardChannel = FlutterMethodChannel(name: "venera/clipboard", binaryMessenger: controller.engine.binaryMessenger)

      clipboardChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "writeImageToClipboard":
          guard let arguments = call.arguments as? [String: Any],
            let data = arguments["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
          }

          guard let image = NSImage(data: data.data) else {
            result(FlutterError(code: "INVALID_IMAGE", message: "Could not create image from data", details: nil))
            return
          }

          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.writeObjects([image])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

  func getDirectoryPath() {
      let openPanel = NSOpenPanel()
      openPanel.canChooseDirectories = true
      openPanel.canChooseFiles = false
      openPanel.allowsMultipleSelection = false

      openPanel.begin { (result) in
          if result == .OK, let url = openPanel.urls.first {
              if !url.startAccessingSecurityScopedResource() {
                  self.flutterResult?(nil)
                  return
              }
              // Picking the same path twice keeps the newer grant and leaks the
              // earlier one; a leaked grant only means access stays open.
              self.grantedDirectories[url.path] = url
              self.flutterResult?(url.path)
          } else {
              self.flutterResult?(nil)
          }
      }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
