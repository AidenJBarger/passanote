import UIKit
import Photos

/// Image compression for BLE transfer, following bitchat's ImageUtils approach:
/// downscale first, then walk JPEG quality down, then shrink dimensions until
/// the result fits the hard byte budget.
///
/// BLE throughput is ~20-40 KB/s, so the budget is a hard 300KB max.
enum ImageUtils {
    static let maxTransferBytes = 300 * 1024
    static let maxDimension: CGFloat = 1024

    /// Returns JPEG data guaranteed to be <= maxTransferBytes, or nil if the
    /// image can't be squeezed under budget.
    static func prepareForTransfer(_ original: UIImage) -> Data? {
        var image = downscale(original, maxDimension: maxDimension)

        var quality: CGFloat = 0.7
        var data = image.jpegData(compressionQuality: quality)
        while let current = data, current.count > maxTransferBytes, quality > 0.35 {
            quality -= 0.1
            data = image.jpegData(compressionQuality: quality)
        }

        var dimension = maxDimension
        while let current = data, current.count > maxTransferBytes, dimension > 256 {
            dimension *= 0.75
            image = downscale(original, maxDimension: dimension)
            data = image.jpegData(compressionQuality: quality)
        }

        guard let final = data, final.count <= maxTransferBytes else { return nil }
        return final
    }

    static func saveToPhotoLibrary(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
