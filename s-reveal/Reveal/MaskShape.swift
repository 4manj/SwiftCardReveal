import CoreGraphics
import Foundation

enum MaskShape {
    private static let pathData =
        "M19.1613 0C20.228 0.0584461 20.6717 1.48419 20.7238 2.37034C20.8005 3.67592 20.2871 4.89105 19.4373 5.86471C19.1762 6.16384 18.9032 6.44916 18.6362 6.74292C18.3352 7.05302 18.1108 7.42375 17.831 7.74003C17.9816 7.8434 18.1239 7.95848 18.2565 8.0842C18.4765 7.90611 18.7404 7.77118 18.9751 7.61119C20.0334 6.88965 20.8135 6.35912 22.1033 6.13339C22.7132 6.02666 24.7803 5.83135 25.272 6.19438C25.4179 6.3021 25.479 6.46638 25.5028 6.64018C25.554 7.01255 25.4975 7.43048 25.4578 7.80227C25.3212 9.08018 25.0917 10.1966 24.2982 11.2392C23.3997 12.4198 22.3198 12.8593 20.8916 13.0549C20.9622 13.5329 21.072 14.0817 21.2301 14.5394C21.3565 14.9055 21.5686 15.2737 21.714 15.6339C22.1045 16.601 22.1811 17.528 21.866 18.5245C21.4667 19.7874 20.6137 20.6592 19.5171 21.3582C19.2673 21.5174 19.0209 21.6914 18.7536 21.8227C17.815 22.2837 16.8686 22.6307 15.8591 22.8862C13.908 23.3803 12.5451 23.4885 10.574 23.0919C9.9429 22.9697 9.31979 22.8094 8.70811 22.6116C6.92054 22.0427 4.861 20.9655 3.94536 19.2402C3.40163 18.2157 3.30006 16.9487 3.71865 15.8683C3.94214 15.2915 4.18066 14.8704 4.37596 14.2589C4.48658 13.8635 4.57157 13.4612 4.63043 13.0549C3.78514 12.9476 2.93015 12.7134 2.22314 12.2214C1.49581 11.7151 0.891465 10.9146 0.556363 10.0953C0.383773 9.67334 0.273399 9.21881 0.194903 8.77064C0.106284 8.2647 -0.163923 6.71821 0.142099 6.30318C0.262092 6.14043 0.454543 6.07997 0.645219 6.04865C1.21072 5.95573 1.819 5.97177 2.3893 6.01414C4.254 6.1527 4.96254 6.52835 6.47789 7.56806C6.73568 7.74493 7.01132 7.89674 7.26463 8.07988C7.38958 7.97944 7.55851 7.8325 7.68839 7.75005C7.59905 7.65163 7.49082 7.50092 7.41172 7.39282C7.0409 6.88609 6.59487 6.43759 6.17659 5.97246C5.40847 5.11829 4.87667 4.06906 4.78919 2.91269C4.7264 2.0826 4.92524 1.14118 5.45959 0.48562C5.678 0.211309 6.28066 -0.18395 6.64356 0.0982488C6.84838 0.316423 6.67144 0.801717 6.58982 1.05647C6.0847 2.6333 6.76843 3.78355 7.87809 4.86538C7.95425 4.39223 8.43506 3.32842 8.79682 3.02147C8.96678 2.87967 9.18678 2.81248 9.40697 2.83509C10.2157 2.92279 9.59019 3.91484 9.44466 4.3223C9.24823 4.87239 9.16941 5.46659 9.38468 6.02404C9.46734 6.23804 9.60318 6.41692 9.74027 6.59887C9.76579 6.58779 9.79155 6.57724 9.81752 6.56724C10.391 6.346 11.0433 6.22616 11.6498 6.13784C12.6842 5.98722 13.7495 6.06911 14.7663 6.29625C15.115 6.37414 15.4579 6.45626 15.7856 6.60263C15.8736 6.49732 15.9266 6.42561 15.9979 6.30865C16.3734 5.69287 16.3148 4.88162 16.0552 4.23407C15.9415 3.95468 15.7959 3.69354 15.7203 3.39986C15.6444 3.10414 15.7484 2.90592 16.0519 2.84396C16.2392 2.80574 16.515 2.85291 16.6623 2.97245C17.0987 3.32672 17.5501 4.33142 17.649 4.8643C17.9365 4.5962 18.197 4.30045 18.4265 3.98132C19.0077 3.15874 19.2331 2.37898 19.0158 1.37184C18.9514 1.07797 18.8413 0.798432 18.7867 0.502059C18.7277 0.180384 18.8461 0.0424363 19.1613 0Z"

    static func makeCGPath() -> CGPath {
        var parser = SVGPathParser(data: pathData)
        return (try? parser.parse()) ?? CGMutablePath()
    }

    static func rasterize(size: Int) -> CGImage? {
        rasterize(path: makeCGPath(), size: size)
    }

    static func rasterizeFallbackCircle(size: Int) -> CGImage? {
        let circle = CGMutablePath()
        circle.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rasterize(path: circle, size: size)
    }

    private static func rasterize(path: CGPath, size: Int) -> CGImage? {
        guard size > 0 else { return nil }
        let bounds = path.boundingBoxOfPath
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }

        let width = size
        let height = size
        let padding = CGFloat(size) * 0.05
        let drawable = CGRect(
            x: padding,
            y: padding,
            width: CGFloat(size) - padding * 2,
            height: CGFloat(size) - padding * 2
        )
        let scale = min(drawable.width / bounds.width, drawable.height / bounds.height)

        var fit = CGAffineTransform.identity
        fit = fit.translatedBy(x: drawable.midX, y: drawable.midY)
        fit = fit.scaledBy(x: scale, y: scale)
        fit = fit.translatedBy(x: -bounds.midX, y: -bounds.midY)
        guard let fitted = path.copy(using: &fit) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(fitted)
        ctx.fillPath()
        return ctx.makeImage()
    }
}

private struct SVGPathParser {
    private let scalars: [UnicodeScalar]
    private var index: Int = 0
    private var currentPoint: CGPoint = .zero
    private var subpathStart: CGPoint = .zero

    init(data: String) {
        scalars = Array(data.unicodeScalars)
    }

    mutating func parse() throws -> CGPath {
        let path = CGMutablePath()
        var currentCommand: UnicodeScalar?

        while true {
            skipSeparators()
            guard !isAtEnd else { break }

            if let command = readCommandIfPresent() {
                currentCommand = command
            }
            guard let command = currentCommand else {
                throw ParseError.expectedCommand
            }

            switch command {
            case "M", "m":
                let isRelative = command == "m"
                let first = try readPoint(relative: isRelative)
                path.move(to: first)
                currentPoint = first
                subpathStart = first

                while hasNumberAhead {
                    let point = try readPoint(relative: isRelative)
                    path.addLine(to: point)
                    currentPoint = point
                }

            case "C", "c":
                let isRelative = command == "c"
                while hasNumberAhead {
                    let c1 = try readPoint(relative: isRelative)
                    let c2 = try readPoint(relative: isRelative)
                    let end = try readPoint(relative: isRelative)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    currentPoint = end
                }

            case "Z", "z":
                path.closeSubpath()
                currentPoint = subpathStart
                index += 1

            default:
                throw ParseError.unsupportedCommand(Character(command))
            }
        }

        return path
    }

    private var isAtEnd: Bool { index >= scalars.count }

    private var hasNumberAhead: Bool {
        var probe = index
        while probe < scalars.count {
            let scalar = scalars[probe]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "," {
                probe += 1
                continue
            }
            return scalar == "+" || scalar == "-" || scalar == "." || CharacterSet.decimalDigits.contains(scalar)
        }
        return false
    }

    private mutating func skipSeparators() {
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "," {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func readCommandIfPresent() -> UnicodeScalar? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        guard CharacterSet.letters.contains(scalar) else { return nil }
        index += 1
        return scalar
    }

    private mutating func readPoint(relative: Bool) throws -> CGPoint {
        let x = try readNumber()
        let y = try readNumber()
        if relative {
            return CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
        }
        return CGPoint(x: x, y: y)
    }

    private mutating func readNumber() throws -> CGFloat {
        skipSeparators()
        let start = index
        guard index < scalars.count else { throw ParseError.expectedNumber }

        if scalars[index] == "+" || scalars[index] == "-" {
            index += 1
        }

        var sawDigit = false
        while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
            sawDigit = true
            index += 1
        }

        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
                sawDigit = true
                index += 1
            }
        }

        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                index += 1
            }
            var exponentDigit = false
            while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
                exponentDigit = true
                index += 1
            }
            if !exponentDigit {
                throw ParseError.invalidNumber
            }
        }

        guard sawDigit else { throw ParseError.expectedNumber }
        let token = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let value = Double(token) else { throw ParseError.invalidNumber }
        return CGFloat(value)
    }

    enum ParseError: Error {
        case expectedCommand
        case expectedNumber
        case invalidNumber
        case unsupportedCommand(Character)
    }
}
