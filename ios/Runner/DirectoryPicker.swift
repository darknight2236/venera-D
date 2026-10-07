import UIKit
import Flutter

class DirectoryPicker: NSObject, UIDocumentPickerDelegate {
    private var result: FlutterResult?

    /// Hands the picked URL to its owner once the security scope has been
    /// claimed, so the owner can revoke it by path later. Without the claim,
    /// listing or writing into a provider-backed directory fails with EPERM.
    var onGranted: ((URL) -> Void)?

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

        if !url.startAccessingSecurityScopedResource() {
            result?(nil)
            return
        }

        onGranted?(url)
        result?(url.path)
    }

    // 处理取消选择情况
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        result?(nil)
    }
}
