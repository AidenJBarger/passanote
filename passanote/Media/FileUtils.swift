import UIKit
import UniformTypeIdentifiers

enum FileUtils {
    static let maxTransferBytes = ImageUtils.maxTransferBytes

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    static func sanitizedFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "file" }
        return (trimmed as NSString).lastPathComponent
    }

    static func formattedSize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Presents the system share sheet so the user can save to Files.
    static func presentSaveSheet(data: Data, fileName: String) {
        let safeName = sanitizedFileName(fileName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 0,
                    height: 0
                )
            }
            presenter.present(activity, animated: true)
        }
    }
}
