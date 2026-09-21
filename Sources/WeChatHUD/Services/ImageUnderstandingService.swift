import Foundation
import Vision

struct ImageUnderstandingResult: Equatable {
    let filePath: String?
    let ocrText: String
    let errorMessage: String?

    var hasText: Bool {
        !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

   var promptContext: String {
       if hasText {
            return "图片里出现的文字（可能不准，只能当图上写了什么）：\(Self.compact(ocrText, limit: 280))"
       }
       if filePath == nil {
            return "对方发了一张图片，本机没有这份图，看不出图上写了什么。"
       }
       if let errorMessage, !errorMessage.isEmpty {
            return "对方发了一张图片，本机还读不出图上的字。"
       }
        return "对方发了一张图片，图上没有读出文字。"
   }

    static func compact(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}

enum ImageUnderstandingService {
    static func analyzeImage(at filePath: String?) -> ImageUnderstandingResult {
        guard let filePath, !filePath.isEmpty else {
            return ImageUnderstandingResult(filePath: nil, ocrText: "", errorMessage: "missing")
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ImageUnderstandingResult(filePath: filePath, ocrText: "", errorMessage: "absent")
        }
        if looksLikeWeChatEncryptedData(filePath) {
            return ImageUnderstandingResult(filePath: filePath, ocrText: "", errorMessage: "encrypted")
        }

        do {
            let url = URL(fileURLWithPath: filePath)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(url: url, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let text = lines.joined(separator: "\n")
            return ImageUnderstandingResult(filePath: filePath, ocrText: text, errorMessage: nil)
        } catch {
            return ImageUnderstandingResult(filePath: filePath, ocrText: "", errorMessage: "unreadable")
        }
    }

    private static func looksLikeWeChatEncryptedData(_ filePath: String) -> Bool {
        guard (filePath as NSString).pathExtension.lowercased() == "dat",
              let data = FileManager.default.contents(atPath: filePath),
              data.count >= 4 else { return false }
        let header = [UInt8](data.prefix(4))
        return header == [0x07, 0x08, 0x56, 0x32]
    }
}
