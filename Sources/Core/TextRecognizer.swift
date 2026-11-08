import AppKit
import Vision

/// 截图中识别出的文字。
struct TextRecognitionResult {
    let text: String
    let lineCount: Int
    let errorMessage: String?

    static let empty = TextRecognitionResult(text: "", lineCount: 0, errorMessage: nil)

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 基于 macOS Vision 的离线文字识别。中英混合，按行从上到下排序。
enum TextRecognizer {

    /// 在后台线程识别，回调固定回到主线程。
    static func recognize(
        cgImage: CGImage,
        completion: @escaping (TextRecognitionResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                // 先按水平方向把文本行聚成「列」：主内容在左、侧栏在右时，
                // 直接按 y 排序会把两列交错在一起；按列输出更符合阅读顺序。
                struct RecognizedLine {
                    let text: String
                    let box: CGRect
                }

                let rawLines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return line.isEmpty ? nil : RecognizedLine(text: line, box: observation.boundingBox)
                }

                var columns: [[RecognizedLine]] = []
                for line in rawLines.sorted(by: { $0.box.maxY > $1.box.maxY }) {
                    if let index = columns.firstIndex(where: { column in
                        let union = column.reduce(CGRect.null) { $0.union($1.box) }
                        let overlap = max(0, min(line.box.maxX, union.maxX) - max(line.box.minX, union.minX))
                        return overlap > min(line.box.width, union.width) * 0.45
                    }) {
                        columns[index].append(line)
                    } else {
                        columns.append([line])
                    }
                }

                let ordered = columns
                    .sorted { lhs, rhs in
                        let lhsMinX = lhs.map(\.box.minX).min() ?? 0
                        let rhsMinX = rhs.map(\.box.minX).min() ?? 0
                        return lhsMinX < rhsMinX
                    }
                    .flatMap { column in
                        column.sorted { lhs, rhs in
                            if abs(lhs.box.maxY - rhs.box.maxY) > 0.012 {
                                return lhs.box.maxY > rhs.box.maxY
                            }
                            return lhs.box.minX < rhs.box.minX
                        }
                    }

                let lines = ordered.map(\.text)

                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async {
                    completion(TextRecognitionResult(text: text, lineCount: lines.count, errorMessage: nil))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(TextRecognitionResult(text: "", lineCount: 0, errorMessage: error.localizedDescription))
                }
            }
        }
    }
}
