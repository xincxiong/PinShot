import CoreGraphics
import Foundation

/// 滚动截图拼接器：把同一块屏幕区域连续截到的多张帧，按「重叠行」拼成一张纵向长图。
///
/// 设计要点：
/// - 所有帧统一转成 RGBA8、行优先、左上原点（内存 row 0 = 画面顶部），便于按行比较；
/// - 重叠检测在「已拼接内容尾部」与「新帧顶部」之间搜索：在
///   `[minimumOverlapRows, min(累积高, 帧高)]` 内从大到小尝试，命中即表示新帧顶部
///   与旧内容尾部重合 `overlap` 行，只追加新帧 `overlap..<帧高` 的部分；
/// - 行比较带颜色容差 + 行内允许少量像素差异，吸收滚动条 / 光标闪烁 / 抗锯齿抖动；
/// - 反向重叠（新帧底部与旧内容顶部重合）说明页面往上滚，单独返回 `.reversed`，
///   由控制器决定丢弃该帧或翻转滚动方向；
/// - 找不到重叠时退化为「直接追加整帧」并记录警告，避免整次截图失败；
/// - 最终高度硬上限（默认 200,000px），到顶后停止追加，避免内存爆炸。
///
/// 该类型不依赖 AppKit / 屏幕权限，可单独编译做离屏测试。
final class ScrollingStitcher {

    // MARK: - 配置

    struct Options {
        /// 最终长图的最大像素高度，默认 200,000
        var maximumHeight: Int = 200_000
        /// 认为是「可靠重叠」的最小行数
        var reliableOverlapRows: Int = 18
        /// 搜索重叠时的最小行数，低于该值视为没有重叠
        var minimumOverlapRows: Int = 4
        /// 单行内允许的不同像素比例（滚动条 / 抗锯齿 / 光标残影）
        var maximumRowMismatchRatio: CGFloat = 0.22
        /// 单通道颜色容差（0...255）
        var channelTolerance: Int = 12

        init() {}
    }

    /// 一次追加的结果类型
    enum Outcome: Equatable {
        /// 找到可靠重叠并追加了新增行
        case appended
        /// 只找到较小重叠，按较小重叠追加（已记录警告）
        case appendedWeak
        /// 没有重叠，直接追加整帧（已记录警告）
        case appendedWholeFrame
        /// 新帧与已拼接尾部完全相同：滚动没有产生变化
        case identical
        /// 页面往回滚（新帧底部与旧内容顶部重合），未追加
        case reversed
        /// 帧宽与已拼接宽度不一致，未追加
        case widthMismatch
        /// 帧图像无法解码，未追加
        case invalidImage
        /// 已达到高度上限（可能追加了最后一部分）
        case heightLimit
    }

    struct AppendResult {
        let outcome: Outcome
        /// 本次实际追加的像素行数
        let addedRows: Int
        /// 匹配到的重叠行数（没有匹配时为 0）
        let overlapRows: Int
        /// 追加后的总像素高度
        let totalHeight: Int
        /// 已处理的帧数（初始帧算 1）
        let frameCount: Int

        var didAppend: Bool { addedRows > 0 }
        var reachedHeightLimit: Bool { outcome == .heightLimit }
    }

    /// 不产生副作用的匹配预览（用于自动滚动方向校准）
    struct Preview {
        let forwardOverlapRows: Int
        let reverseOverlapRows: Int
        let isIdentical: Bool
        let widthMismatch: Bool
        let frameHeight: Int
    }

    // MARK: - 状态

    let options: Options

    private(set) var totalHeight: Int = 0
    private(set) var frameCount: Int = 0
    private(set) var warnings: [String] = []

    /// 拼接宽度（像素），由初始帧决定
    private var width: Int = 0
    /// RGBA8 累积像素，行优先；`pixels.count == width * 4 * totalHeight`
    private var pixels: [UInt8] = []

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - 生命周期

    /// 用初始帧（从冻结帧裁剪出的选区）建立拼接画布
    @discardableResult
    func begin(with image: CGImage) -> Bool {
        guard let frame = Self.makeFrame(from: image) else {
            warnings.append("初始帧像素解码失败")
            return false
        }
        reset()
        width = frame.width
        pixels = frame.bytes
        totalHeight = frame.height
        frameCount = 1
        return true
    }

    func reset() {
        width = 0
        pixels.removeAll(keepingCapacity: false)
        totalHeight = 0
        frameCount = 0
        warnings.removeAll()
    }

    // MARK: - 匹配 / 追加

    /// 预览新帧与已拼接内容的匹配情况，不修改内部状态。
    func preview(_ image: CGImage) -> Preview? {
        guard width > 0, totalHeight > 0 else { return nil }
        guard let frame = Self.makeFrame(from: image) else { return nil }
        guard frame.width == width else {
            return Preview(
                forwardOverlapRows: 0,
                reverseOverlapRows: 0,
                isIdentical: false,
                widthMismatch: true,
                frameHeight: frame.height
            )
        }

        let rowBytes = width * 4
        let prevHeight = totalHeight
        let newHeight = frame.height
        var forward = 0
        var reverse = 0
        pixels.withUnsafeBufferPointer { prev in
            frame.bytes.withUnsafeBufferPointer { new in
                forward = findOverlap(
                    prev: prev, prevHeight: prevHeight,
                    new: new, newHeight: newHeight,
                    rowBytes: rowBytes, reversed: false
                )
                if forward == 0 {
                    reverse = findOverlap(
                        prev: prev, prevHeight: prevHeight,
                        new: new, newHeight: newHeight,
                        rowBytes: rowBytes, reversed: true
                    )
                }
            }
        }
        return Preview(
            forwardOverlapRows: forward,
            reverseOverlapRows: reverse,
            isIdentical: forward >= newHeight,
            widthMismatch: false,
            frameHeight: newHeight
        )
    }

    /// 追加一帧。新帧必须是同一块屏幕区域、与初始帧同宽。
    @discardableResult
    func append(_ image: CGImage) -> AppendResult {
        guard width > 0, totalHeight > 0 else {
            return result(.invalidImage, added: 0, overlap: 0)
        }
        guard totalHeight < options.maximumHeight else {
            return result(.heightLimit, added: 0, overlap: 0)
        }
        guard let frame = Self.makeFrame(from: image) else {
            warnings.append("第 \(frameCount + 1) 帧像素解码失败，已跳过")
            return result(.invalidImage, added: 0, overlap: 0)
        }
        guard frame.width == width else {
            warnings.append("第 \(frameCount + 1) 帧宽度 \(frame.width)px 与已拼接宽度 \(width)px 不一致，已跳过")
            return result(.widthMismatch, added: 0, overlap: 0)
        }

        frameCount += 1
        let rowBytes = width * 4
        let prevHeight = totalHeight
        let newHeight = frame.height

        var forward = 0
        var reverse = 0
        pixels.withUnsafeBufferPointer { prev in
            frame.bytes.withUnsafeBufferPointer { new in
                forward = findOverlap(
                    prev: prev, prevHeight: prevHeight,
                    new: new, newHeight: newHeight,
                    rowBytes: rowBytes, reversed: false
                )
                if forward == 0 {
                    reverse = findOverlap(
                        prev: prev, prevHeight: prevHeight,
                        new: new, newHeight: newHeight,
                        rowBytes: rowBytes, reversed: true
                    )
                }
            }
        }

        // 整帧都落在已拼接内容里：滚动没有产生新内容
        if forward >= newHeight {
            return result(.identical, added: 0, overlap: forward)
        }

        if forward > 0 {
            let reliable = forward >= min(options.reliableOverlapRows, newHeight)
            let appended = appendRows(from: frame, skipping: forward)
            if !reliable {
                warnings.append("第 \(frameCount) 帧仅匹配到 \(forward)px 重叠，已按较小重叠拼接")
            }
            let outcome: Outcome = appended.limited
                ? .heightLimit
                : (reliable ? .appended : .appendedWeak)
            return result(outcome, added: appended.added, overlap: forward)
        }

        // 反向重叠：页面往上滚了。不追加，交给控制器处理。
        if reverse > 0 {
            return result(.reversed, added: 0, overlap: reverse)
        }

        // 完全没有重叠：直接追加整帧兜底（会重复一部分内容，但保证流程不中断）
        warnings.append("第 \(frameCount) 帧未找到重叠（画面跳变或滚动过快），已直接追加整帧")
        let appended = appendRows(from: frame, skipping: 0)
        return result(
            appended.limited ? .heightLimit : .appendedWholeFrame,
            added: appended.added,
            overlap: 0
        )
    }

    /// 把当前累积像素封装成 CGImage
    func makeImage() -> CGImage? {
        guard width > 0, totalHeight > 0 else { return nil }
        let rowBytes = width * 4
        let byteCount = rowBytes * totalHeight
        guard byteCount > 0, pixels.count >= byteCount else { return nil }

        let data = Data(pixels[0..<byteCount])
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        return CGImage(
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - 内部：追加

    /// 把 frame 从第 `rows` 行起追加到累积像素，返回实际追加行数与是否触顶。
    private func appendRows(from frame: Frame, skipping rows: Int) -> (added: Int, limited: Bool) {
        let rowBytes = width * 4
        guard rows >= 0, rows < frame.height else { return (0, false) }
        let wanted = frame.height - rows
        let capacity = max(0, options.maximumHeight - totalHeight)
        let added = min(wanted, capacity)
        if added > 0 {
            let start = rows * rowBytes
            pixels.append(contentsOf: frame.bytes[start..<(start + added * rowBytes)])
            totalHeight += added
        }
        let limited = added < wanted || totalHeight >= options.maximumHeight
        return (added, limited)
    }

    private func result(_ outcome: Outcome, added: Int, overlap: Int) -> AppendResult {
        AppendResult(
            outcome: outcome,
            addedRows: added,
            overlapRows: overlap,
            totalHeight: totalHeight,
            frameCount: frameCount
        )
    }

    // MARK: - 内部：重叠搜索

    /// 在 [minimumOverlapRows, min(prevHeight, newHeight)] 内从大到小搜重叠。
    /// - reversed == false：prev 尾部 ↔ new 头部（页面往下滚）
    /// - reversed == true ：prev 头部 ↔ new 底部（页面往上滚）
    private func findOverlap(
        prev: UnsafeBufferPointer<UInt8>,
        prevHeight: Int,
        new: UnsafeBufferPointer<UInt8>,
        newHeight: Int,
        rowBytes: Int,
        reversed: Bool
    ) -> Int {
        let maximum = min(prevHeight, newHeight)
        guard maximum >= options.minimumOverlapRows else { return 0 }

        let maximumMismatch = max(1, Int(Double(width) * options.maximumRowMismatchRatio))
        var overlap = maximum
        while overlap >= options.minimumOverlapRows {
            // 跳过新帧贴着视口边缘的一小段：页面常有吸顶 header / 吸底工具栏，
            // 这一小段在每帧里位置固定、内容不随滚动变化，参与比较会导致假性不匹配。
            let edgeSkip = overlap >= 64 ? min(overlap / 4, Self.maximumEdgeSkipRows) : 0
            let matched: Bool
            if reversed {
                matched = rowsMatch(
                    prev: prev, prevStartRow: 0,
                    new: new, newStartRow: newHeight - overlap,
                    rows: overlap, skipNewHead: 0, skipNewTail: edgeSkip,
                    rowBytes: rowBytes, maxMismatch: maximumMismatch
                )
            } else {
                matched = rowsMatch(
                    prev: prev, prevStartRow: prevHeight - overlap,
                    new: new, newStartRow: 0,
                    rows: overlap, skipNewHead: edgeSkip, skipNewTail: 0,
                    rowBytes: rowBytes, maxMismatch: maximumMismatch
                )
            }
            if matched { return overlap }
            overlap -= 1
        }
        return 0
    }

    /// 匹配时忽略新帧贴边行数的上限（兼顾吸顶 header 与匹配证据量）
    private static let maximumEdgeSkipRows = 128

    /// 比较两段行是否「足够相等」：先抽查 9 个探针行快速排除错误候选，再逐行确认。
    /// - skipNewHead / skipNewTail：跳过新帧重叠区里贴视口上 / 下边的行（吸顶 / 吸底元素）。
    private func rowsMatch(
        prev: UnsafeBufferPointer<UInt8>,
        prevStartRow: Int,
        new: UnsafeBufferPointer<UInt8>,
        newStartRow: Int,
        rows: Int,
        skipNewHead: Int,
        skipNewTail: Int,
        rowBytes: Int,
        maxMismatch: Int
    ) -> Bool {
        let head = min(max(skipNewHead, 0), rows)
        let tail = min(max(skipNewTail, 0), rows - head)
        let compareCount = rows - head - tail
        // 跳过太多行会导致证据不足，直接按完整重叠区比较
        guard compareCount >= 4 else {
            return compareRowsLoose(
                prev: prev, prevStartRow: prevStartRow,
                new: new, newStartRow: newStartRow,
                rows: rows, rowBytes: rowBytes, maxMismatch: maxMismatch
            )
        }

        var probes = Set<Int>()
        let probeCount = min(compareCount, 9)
        if probeCount <= 1 {
            probes.insert(0)
        } else {
            for index in 0..<probeCount {
                probes.insert((compareCount - 1) * index / (probeCount - 1))
            }
        }

        for row in probes {
            let offset = head + row
            if !rowMatches(
                prev: prev, prevOffset: (prevStartRow + offset) * rowBytes,
                new: new, newOffset: (newStartRow + offset) * rowBytes,
                rowBytes: rowBytes, maxMismatch: maxMismatch
            ) {
                return false
            }
        }
        for row in 0..<compareCount where !probes.contains(row) {
            let offset = head + row
            if !rowMatches(
                prev: prev, prevOffset: (prevStartRow + offset) * rowBytes,
                new: new, newOffset: (newStartRow + offset) * rowBytes,
                rowBytes: rowBytes, maxMismatch: maxMismatch
            ) {
                return false
            }
        }
        return true
    }

    private func compareRowsLoose(
        prev: UnsafeBufferPointer<UInt8>,
        prevStartRow: Int,
        new: UnsafeBufferPointer<UInt8>,
        newStartRow: Int,
        rows: Int,
        rowBytes: Int,
        maxMismatch: Int
    ) -> Bool {
        for row in 0..<rows {
            if !rowMatches(
                prev: prev, prevOffset: (prevStartRow + row) * rowBytes,
                new: new, newOffset: (newStartRow + row) * rowBytes,
                rowBytes: rowBytes, maxMismatch: maxMismatch
            ) {
                return false
            }
        }
        return true
    }

    /// 单行比较：RGB 三通道都允许 channelTolerance 容差，不同像素数超过 maxMismatch 即失败。
    private func rowMatches(
        prev: UnsafeBufferPointer<UInt8>,
        prevOffset: Int,
        new: UnsafeBufferPointer<UInt8>,
        newOffset: Int,
        rowBytes: Int,
        maxMismatch: Int
    ) -> Bool {
        let tolerance = options.channelTolerance
        var mismatches = 0
        var offset = 0
        while offset + 3 < rowBytes {
            let p = prevOffset + offset
            let n = newOffset + offset
            let redDelta = abs(Int(prev[p]) - Int(new[n]))
            let greenDelta = abs(Int(prev[p + 1]) - Int(new[n + 1]))
            let blueDelta = abs(Int(prev[p + 2]) - Int(new[n + 2]))
            if redDelta > tolerance || greenDelta > tolerance || blueDelta > tolerance {
                mismatches += 1
                if mismatches > maxMismatch { return false }
            }
            offset += 4
        }
        return true
    }

    // MARK: - 内部：像素解码

    private struct Frame {
        let width: Int
        let height: Int
        /// RGBA8、行优先、左上原点
        let bytes: [UInt8]
    }

    /// 把任意 CGImage 画进 RGBA8 位图上下文，得到稳定的行优先像素。
    /// CGBitmapContext 内存 row 0 对应画面顶部，和 CGImage 的行序一致。
    private static func makeFrame(from image: CGImage) -> Frame? {
        let frameWidth = image.width
        let frameHeight = image.height
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        // 单帧像素上限保护（正常选区远小于此值）
        guard frameWidth <= 32_768, frameHeight <= 32_768,
              frameWidth * frameHeight <= 64_000_000 else { return nil }

        let rowBytes = frameWidth * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * frameHeight)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: frameWidth,
                    height: frameHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
            return true
        }
        guard drawn else { return nil }
        return Frame(width: frameWidth, height: frameHeight, bytes: bytes)
    }
}
