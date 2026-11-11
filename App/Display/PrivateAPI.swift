import CoreGraphics
import Foundation
import IOKit

/// The private C functions the app uses, looked up at runtime. A function macOS no longer has is
/// `nil`, and the control that needs it is hidden: nothing here is linked, so a missing symbol
/// never stops the launch. Each constant is resolved once, on first use.
enum PrivateAPI {
    private static let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let displayServices =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    // MARK: IOKit (DDC over I2C)

    /// Returns a retained IOAVService for a `DCPAVServiceProxy` entry.
    static let IOAVServiceCreateWithService:
        (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?)? =
            symbol("IOAVServiceCreateWithService", in: ioKit)

    /// Arguments: service, chip address, offset, buffer, size.
    static let IOAVServiceReadI2C:
        (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn)? =
            symbol("IOAVServiceReadI2C", in: ioKit)

    /// Arguments: service, chip address, data address, buffer, size.
    static let IOAVServiceWriteI2C:
        (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn)? =
            symbol("IOAVServiceWriteI2C", in: ioKit)

    /// Gives a retained EDID.
    static let IOAVServiceCopyEDID:
        (@convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn)? =
            symbol("IOAVServiceCopyEDID", in: ioKit)

    // MARK: DisplayServices (native brightness, 0...1; a result of 0 means success)

    static let DisplayServicesCanChangeBrightness:
        (@convention(c) (CGDirectDisplayID) -> Bool)? =
            symbol("DisplayServicesCanChangeBrightness", in: displayServices)

    static let DisplayServicesGetBrightness:
        (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? =
            symbol("DisplayServicesGetBrightness", in: displayServices)

    static let DisplayServicesSetBrightness:
        (@convention(c) (CGDirectDisplayID, Float) -> Int32)? =
            symbol("DisplayServicesSetBrightness", in: displayServices)

    // MARK: Report

    /// The names of the functions that were not found; empty when all seven were.
    static var missing: [String] {
        let found: [(name: String, found: Bool)] = [
            ("IOAVServiceCreateWithService", IOAVServiceCreateWithService != nil),
            ("IOAVServiceReadI2C", IOAVServiceReadI2C != nil),
            ("IOAVServiceWriteI2C", IOAVServiceWriteI2C != nil),
            ("IOAVServiceCopyEDID", IOAVServiceCopyEDID != nil),
            ("DisplayServicesCanChangeBrightness", DisplayServicesCanChangeBrightness != nil),
            ("DisplayServicesGetBrightness", DisplayServicesGetBrightness != nil),
            ("DisplayServicesSetBrightness", DisplayServicesSetBrightness != nil),
        ]
        return found.filter { !$0.found }.map(\.name)
    }

    /// Resolves the seven functions and, in DEBUG, logs how many were found. Calls none of them.
    static func logResolved() {
        let missing = missing
        debugLog("PrivateAPI",
            "resolved=\(7 - missing.count) missing=\(missing.isEmpty ? "none" : missing.joined(separator: ","))")
    }

    /// The function `name` of the image at `path` as a C function pointer of type `T`; nil when
    /// the image or the symbol is absent.
    private static func symbol<T>(_ name: String, in path: String) -> T? {
        guard let image = dlopen(path, RTLD_LAZY), let address = dlsym(image, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
