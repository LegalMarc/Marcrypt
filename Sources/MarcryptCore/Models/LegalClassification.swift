import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Legal classification system for document stamps.
/// Each classification has a display name, watermark text, and associated color.
public enum LegalClassification: String, CaseIterable, Codable {
    case none
    case confidential
    case privileged
    case workProduct
    case protectiveOrder
    case custom
    
    public var displayName: String {
        switch self {
        case .none:             return "None"
        case .confidential:     return "CONFIDENTIAL"
        case .privileged:       return "ATTORNEY-CLIENT PRIVILEGED"
        case .workProduct:      return "ATTORNEY WORK PRODUCT"
        case .protectiveOrder:  return "SUBJECT TO PROTECTIVE ORDER"
        case .custom:           return "Custom"
        }
    }
    
    public var watermarkText: String {
        switch self {
        case .none:             return ""
        case .confidential:     return "CONFIDENTIAL"
        case .privileged:       return "ATTORNEY-CLIENT PRIVILEGED"
        case .workProduct:      return "ATTORNEY WORK PRODUCT"
        case .protectiveOrder:  return "CONFIDENTIAL — SUBJECT TO PROTECTIVE ORDER"
        case .custom:           return ""  // User provides custom text
        }
    }
    
    #if canImport(AppKit)
    /// Classification color for UI badges and watermark tinting.
    public var color: NSColor {
        switch self {
        case .none:             return .secondaryLabelColor
        case .confidential:     return NSColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1.0) // Gold/Yellow
        case .privileged:       return NSColor(red: 0.86, green: 0.21, blue: 0.27, alpha: 1.0) // Red
        case .workProduct:      return NSColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1.0) // Orange
        case .protectiveOrder:  return NSColor(red: 0.58, green: 0.34, blue: 0.80, alpha: 1.0) // Purple
        case .custom:           return .labelColor
        }
    }
    #endif
    
    /// All classifications available as watermark presets (excluding .none and .custom).
    public static var presets: [LegalClassification] {
        [.confidential, .privileged, .workProduct, .protectiveOrder]
    }
}
