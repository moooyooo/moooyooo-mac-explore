import Foundation

public struct CanvasSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(1, width.isFinite ? width : 1)
        self.height = max(1, height.isFinite ? height : 1)
    }
}

/// A frame in top-left-origin canvas coordinates, independent of AppKit.
public struct PaneFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func constrained(to canvas: CanvasSize) -> Self {
        let w = min(canvas.width, max(min(320, canvas.width), width.isFinite ? width : 320))
        let h = min(canvas.height, max(min(220, canvas.height), height.isFinite ? height : 220))
        return Self(
            x: min(max(0, x.isFinite ? x : 0), canvas.width - w),
            y: min(max(0, y.isFinite ? y : 0), canvas.height - h),
            width: w, height: h
        )
    }

    public func normalized(in canvas: CanvasSize) -> Self {
        let frame = constrained(to: canvas)
        return Self(x: frame.x / canvas.width, y: frame.y / canvas.height,
                    width: frame.width / canvas.width, height: frame.height / canvas.height)
    }

    public func resolved(in canvas: CanvasSize) -> Self {
        Self(x: x * canvas.width, y: y * canvas.height,
             width: width * canvas.width, height: height * canvas.height).constrained(to: canvas)
    }
}

public enum Arrangement: Sendable {
    case columns, rows, cascade
}

public enum PaneLayout {
    public static func cascade(index: Int, canvas: CanvasSize) -> PaneFrame {
        let offset = Double(index % 7) * 26
        return PaneFrame(x: offset, y: offset,
                         width: max(560, canvas.width * 0.76),
                         height: max(340, canvas.height * 0.78))
            .normalized(in: canvas)
    }

    public static func arrange(count: Int, style: Arrangement, canvas: CanvasSize) -> [PaneFrame] {
        guard count > 0 else { return [] }
        guard style != .cascade else {
            return (0..<count).map { cascade(index: $0, canvas: canvas) }
        }
        let maxColumns = max(1, Int(canvas.width / 320))
        let maxRows = max(1, Int(canvas.height / 220))
        // Preserve usable controls when there isn't enough space to tile every pane.
        guard count <= maxColumns * maxRows else {
            return (0..<count).map { cascade(index: $0, canvas: canvas) }
        }
        let columns = style == .columns ? min(count, maxColumns) : (count + min(count, maxRows) - 1) / min(count, maxRows)
        let rows = (count + columns - 1) / columns
        let width = canvas.width / Double(columns)
        let height = canvas.height / Double(rows)
        return (0..<count).map { index in
            PaneFrame(x: Double(index % columns) * width, y: Double(index / columns) * height,
                      width: width, height: height).normalized(in: canvas)
        }
    }
}
