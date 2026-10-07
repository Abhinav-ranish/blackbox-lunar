import CoreImage
import CoreVideo
import Foundation
import ZeticMLange

/// Describes camera frames with Liquid AI LFM2.5-VL-450M running on-device through Melange.
final class SceneObserver {
    static let modelName = "zetic/LFM2.5-VL-450M"

    private var model: ZeticMLangeLLMModel?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var isReady: Bool { model != nil }

    func load(onProgress: @escaping (Float) -> Void) async throws {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "MelangePersonalKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else {
            throw NSError(domain: "Blackbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing Melange personal key (Secrets.xcconfig)"])
        }
        model = try await ZeticMLangeLLMModel(personalKey: key, name: Self.modelName, onDownload: onProgress)
    }

    /// Returns a one-sentence description of the frame.
    func describe(_ pixelBuffer: CVPixelBuffer) async throws -> String {
        guard let model else { return "" }
        let image = try rgbImage(from: pixelBuffer, maxSide: 448)
        try? model.resetKVState()
        let stream = try model.respond(
            systemPrompt: "You are the flight data recorder on a crewed space mission, watching the crew cabin. Report only what is visible. Be brief and literal.",
            userText: "In one short sentence, say whether a person is visible, what they are doing, and name the type of room.",
            image: image
        )
        var text = ""
        for try await token in stream {
            text += token
            if text.count > 240 { break }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts the landscape sensor buffer into an upright, downscaled RGB888 image.
    private func rgbImage(from pixelBuffer: CVPixelBuffer, maxSide: CGFloat) throws -> ZeticMLangeLLMModel.Image {
        var ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = maxSide / max(ci.extent.width, ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let w = Int(ci.extent.width.rounded(.down)), h = Int(ci.extent.height.rounded(.down))

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(ci, toBitmap: &rgba, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return try ZeticMLangeLLMModel.Image(rgb: rgb, width: w, height: h)
    }

    func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let small = ci.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return ciContext.jpegRepresentation(of: small, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
    }
}
