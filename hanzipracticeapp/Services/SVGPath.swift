//
//  SVGPath.swift
//  hanzipracticeapp
//
//  Minimal SVG path parser tuned for the Make-Me-a-Hanzi dataset.
//  MMA paths use M, L, Q, C and Z commands (both absolute and relative
//  variants). Coordinates live in a 1024×1024 space with the y-axis
//  flipped — the standard transform is `translate(0, 900) scale(1, -1)`.
//
//  This parser produces a `Path` already mapped into normal y-down
//  coordinates within a 1024×1024 box, so callers just need to scale it
//  by the display side length.
//

import SwiftUI

nonisolated enum SVGPath {

    /// Convert one MMA stroke path string into a y-down `Path` in the
    /// canonical 1024×1024 space.
    nonisolated static func makePath(_ d: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var startOfSubpath = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: Character = " "

        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: ", \t\n\r")

        // Helper: read a number, allowing scientific notation and negatives.
        func readNumber() -> Double? {
            scanner.charactersToBeSkipped = CharacterSet(charactersIn: ", \t\n\r")
            return scanner.scanDouble()
        }

        func toDisplay(_ p: CGPoint) -> CGPoint {
            // MMA: y-up with translate(0,900) scale(1,-1). So display_y = 900 - data_y.
            CGPoint(x: p.x, y: 900 - p.y)
        }

        while !scanner.isAtEnd {
            // Skip whitespace / commas — `Scanner.charactersToBeSkipped` only
            // applies inside `scan*` calls, so the parser can otherwise spin
            // forever on a space when `peekIsNumber` returns false.
            var idx = scanner.currentIndex
            while idx < d.endIndex {
                let c = d[idx]
                if c == " " || c == "," || c == "\t" || c == "\n" || c == "\r" {
                    idx = d.index(after: idx)
                } else { break }
            }
            scanner.currentIndex = idx
            if scanner.isAtEnd { break }

            // Read a command letter (or implicit repeat of last command).
            let charIdx = scanner.currentIndex
            guard let next = d[charIdx...].first else { break }

            var cmd: Character
            if next.isLetter {
                cmd = next
                scanner.currentIndex = d.index(after: charIdx)
            } else if lastCommand == " " {
                // No command yet and we're sitting on a non-letter, non-space.
                // Bail out rather than spin.
                return path
            } else {
                cmd = lastCommand
            }

            let isRel = cmd.isLowercase
            let upper = Character(cmd.uppercased())

            switch upper {
            case "M":
                guard let x = readNumber(), let y = readNumber() else { return path }
                var p = CGPoint(x: x, y: y)
                if isRel { p.x += current.x; p.y += current.y }
                path.move(to: toDisplay(p))
                current = p
                startOfSubpath = p
                lastControl = nil
                // Subsequent pairs after M become implicit L.
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let xx = readNumber(), let yy = readNumber() else { break }
                    var lp = CGPoint(x: xx, y: yy)
                    if isRel { lp.x += current.x; lp.y += current.y }
                    path.addLine(to: toDisplay(lp))
                    current = lp
                }
                lastCommand = isRel ? "l" : "L"

            case "L":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let x = readNumber(), let y = readNumber() else { break }
                    var p = CGPoint(x: x, y: y)
                    if isRel { p.x += current.x; p.y += current.y }
                    path.addLine(to: toDisplay(p))
                    current = p
                }
                lastControl = nil
                lastCommand = cmd

            case "H":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let x = readNumber() else { break }
                    var p = CGPoint(x: x, y: current.y)
                    if isRel { p.x = current.x + x }
                    path.addLine(to: toDisplay(p))
                    current = p
                }
                lastControl = nil
                lastCommand = cmd

            case "V":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let y = readNumber() else { break }
                    var p = CGPoint(x: current.x, y: y)
                    if isRel { p.y = current.y + y }
                    path.addLine(to: toDisplay(p))
                    current = p
                }
                lastControl = nil
                lastCommand = cmd

            case "Q":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let cx = readNumber(), let cy = readNumber(),
                          let x = readNumber(), let y = readNumber() else { break }
                    var c = CGPoint(x: cx, y: cy)
                    var p = CGPoint(x: x, y: y)
                    if isRel {
                        c.x += current.x; c.y += current.y
                        p.x += current.x; p.y += current.y
                    }
                    path.addQuadCurve(to: toDisplay(p), control: toDisplay(c))
                    lastControl = c
                    current = p
                }
                lastCommand = cmd

            case "T":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let x = readNumber(), let y = readNumber() else { break }
                    var p = CGPoint(x: x, y: y)
                    if isRel { p.x += current.x; p.y += current.y }
                    // Reflect last quad control around current point.
                    let reflected: CGPoint = {
                        guard let c = lastControl else { return current }
                        return CGPoint(x: 2*current.x - c.x, y: 2*current.y - c.y)
                    }()
                    path.addQuadCurve(to: toDisplay(p), control: toDisplay(reflected))
                    lastControl = reflected
                    current = p
                }
                lastCommand = cmd

            case "C":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let c1x = readNumber(), let c1y = readNumber(),
                          let c2x = readNumber(), let c2y = readNumber(),
                          let x = readNumber(), let y = readNumber() else { break }
                    var c1 = CGPoint(x: c1x, y: c1y)
                    var c2 = CGPoint(x: c2x, y: c2y)
                    var p = CGPoint(x: x, y: y)
                    if isRel {
                        c1.x += current.x; c1.y += current.y
                        c2.x += current.x; c2.y += current.y
                        p.x += current.x; p.y += current.y
                    }
                    path.addCurve(to: toDisplay(p),
                                  control1: toDisplay(c1),
                                  control2: toDisplay(c2))
                    lastControl = c2
                    current = p
                }
                lastCommand = cmd

            case "S":
                while !scanner.isAtEnd, peekIsNumber(scanner: scanner, in: d) {
                    guard let c2x = readNumber(), let c2y = readNumber(),
                          let x = readNumber(), let y = readNumber() else { break }
                    var c2 = CGPoint(x: c2x, y: c2y)
                    var p = CGPoint(x: x, y: y)
                    if isRel {
                        c2.x += current.x; c2.y += current.y
                        p.x += current.x; p.y += current.y
                    }
                    let c1: CGPoint = {
                        guard let c = lastControl else { return current }
                        return CGPoint(x: 2*current.x - c.x, y: 2*current.y - c.y)
                    }()
                    path.addCurve(to: toDisplay(p),
                                  control1: toDisplay(c1),
                                  control2: toDisplay(c2))
                    lastControl = c2
                    current = p
                }
                lastCommand = cmd

            case "Z":
                path.closeSubpath()
                current = startOfSubpath
                lastControl = nil
                lastCommand = cmd

            default:
                // Unknown command — bail.
                return path
            }
        }
        return path
    }

    /// Peek at the next non-whitespace character to decide if another
    /// coordinate pair starts there (i.e. the previous command continues
    /// implicitly).
    nonisolated private static func peekIsNumber(scanner: Scanner, in source: String) -> Bool {
        var idx = scanner.currentIndex
        while idx < source.endIndex {
            let c = source[idx]
            if c == "," || c == " " || c == "\t" || c == "\n" || c == "\r" {
                idx = source.index(after: idx)
                continue
            }
            return c == "-" || c == "+" || c == "." || c.isNumber
        }
        return false
    }
}
