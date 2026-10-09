import Foundation
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct AttachmentFiles {
    let directory: URL
    init(ownerID: String?) {
        let account = ownerID.flatMap(UUID.init(uuidString:))?.uuidString ?? "local"
        directory = URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/Photos/\(account)", isDirectory: true)
    }
    static func sanitizedJPEG(_ data: Data) throws -> Data {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 40_000_000 else { throw NutritionError.invalidData }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw NutritionError.invalidData }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw NutritionError.invalidData }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 10_000_000 else { throw NutritionError.invalidData }
        return output as Data
    }
    func save(_ data: Data, id: UUID, ownerID: String?) throws -> NutritionAttachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protected = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try protected.setResourceValues(values)
        let path = "\(id.uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(path), options: [.atomic, .completeFileProtection])
        return NutritionAttachment(id: id, relativePath: path, mimeType: "image/jpeg", byteCount: data.count, createdAt: .now, remoteOwnerID: ownerID)
    }
    func read(_ attachment: NutritionAttachment) throws -> Data {
        guard attachment.relativePath == "\(attachment.id.uuidString).jpg" else { throw NutritionError.invalidData }
        return try Data(contentsOf: directory.appendingPathComponent(attachment.relativePath))
    }
    func delete(_ attachment: NutritionAttachment) throws {
        guard attachment.relativePath == "\(attachment.id.uuidString).jpg" else { throw NutritionError.invalidData }
        let file = directory.appendingPathComponent(attachment.relativePath)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func deleteAll() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
}

struct CameraCapture: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.onImage(data) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
