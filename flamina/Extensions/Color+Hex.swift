//  Color+Hex.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//


import AppKit
import SwiftUI

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0

        } else {
            return nil
        }

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func toHex() -> String? {
        guard let rgbColor = self.usingColorSpace(.sRGB) else {
            return nil
        }
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent

        if a == 1.0 {
            return String(format: "#%02X%02X%02X",
                          Int(round(r * 255)),
                          Int(round(g * 255)),
                          Int(round(b * 255)))
        } else {
            return String(format: "#%02X%02X%02X%02X",
                          Int(round(r * 255)),
                          Int(round(g * 255)),
                          Int(round(b * 255)),
                          Int(round(a * 255)))
        }
    }
}

extension Color {
    init?(hex: String) {
        guard let nsColor = NSColor(hex: hex) else { return nil }
        self.init(nsColor)
    }
}
