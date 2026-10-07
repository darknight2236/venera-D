import UIKit
import Flutter

class DirectoryPicker: NSObject, UIDocumentPickerDelegate {
    private var result: FlutterResult?

    // 初始化选择目录方法
    func selectDirectory(result: @escaping FlutterResult) {
        self.result = result

        // 配置 UIDocumentPicker 为目录选择模式
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false

        // 获取根视图控制器并显示选择器
        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(documentPicker, animated: true, completion: nil)
        }
    }

    // 处理选择完成后的结果
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            result?(nil)
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            result?(nil)
            return
        }

        // The scope is deliberately left open: this picker chooses the storage
        // path, which stays in use for the rest of the run. The bookmark is the
        // part that outlives the process - it is only valid while the pick is
        // still live, so take it now; `url.path` alone cannot reopen the
        // directory after a relaunch.
        var picked: [String: Any] = ["path": url.path]
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            picked["bookmark"] = data.base64EncodedString()
        }
        result?(picked)
    }

    // 处理取消选择情况
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        result?(nil)
    }
}
