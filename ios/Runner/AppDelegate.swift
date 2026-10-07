import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation // 添加此行

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?

  /// Security-scoped grants handed out by the document picker, keyed by path,
  /// so a revoke can only drop the directory it was granted for.
  var grantedDirectories: [String: URL] = [:]

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { (call, result) in
      if call.method == "getProxy" {
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
          let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
          let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
          let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
          let proxyConfig = "\(host):\(port)"
          result(proxyConfig)
        } else {
          result("")
        }
      } else if call.method == "setScreenOn" {
        if let arguments = call.arguments as? Bool {
          let screenOn = arguments
          UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        result(nil)
      } else if call.method == "getDirectoryPath" {
        self.flutterResult = result
        self.getDirectoryPath()
      } else if call.method == "stopAccessingSecurityScopedResource" {
        // Grants are keyed by path so that a revoke can only ever drop the
        // directory it was granted for; an unknown path is ignored rather than
        // cancelling whatever happens to be current.
        if let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String,
          let url = self.grantedDirectories.removeValue(forKey: path) {
          url.stopAccessingSecurityScopedResource()
        }
        result(nil)
      } else if call.method == "selectDirectory" {
        self.directoryPicker = DirectoryPicker()
        self.directoryPicker?.selectDirectory(result: result)
      } else if call.method == "startAccessingSecurityScopedBookmark" {
        // Re-open what a previous run's picker was granted: the stored path
        // stays closed until this bookmark is claimed. The grant is kept for
        // the whole run and is deliberately not put in `grantedDirectories`,
        // which only holds the import picker's short-lived grants.
        var restored: String?
        if let arguments = call.arguments as? [String: Any],
          let base64 = arguments["bookmark"] as? String,
          let data = Data(base64Encoded: base64) {
          var isStale = false
          if let url = try? URL(resolvingBookmarkData: data,
                                bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource() {
            restored = url.path
          }
        }
        if let restored = restored {
          result(["path": restored])
        } else {
          result(nil)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func getDirectoryPath() {
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    if let rootViewController = window?.rootViewController {
      rootViewController.present(documentPicker, animated: true, completion: nil)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      flutterResult?(nil)
      return
    }

    if !url.startAccessingSecurityScopedResource() {
      flutterResult?(nil)
      return
    }

    // Picking the same path twice keeps the newer grant and leaks the earlier
    // one; a leaked grant only means access stays open until the app exits.
    grantedDirectories[url.path] = url
    flutterResult?(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil)
  }
}
