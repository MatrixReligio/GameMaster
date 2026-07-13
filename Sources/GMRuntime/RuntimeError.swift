import Foundation

public enum RuntimeError: Error, LocalizedError, Equatable {
    case manifestMissing
    case checksumMismatch(expected: String, actual: String)
    case archiveLayoutUnrecognized
    case runtimeNotInstalled(id: String)
    case dmgLayoutUnrecognized
    case dmgSignatureInvalid

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            String(localized: "The built-in runtime manifest is missing or corrupted.")
        case .checksumMismatch:
            String(localized: "The downloaded file failed verification. Please try downloading again.")
        case .archiveLayoutUnrecognized:
            String(localized: "The downloaded runtime has an unexpected layout.")
        case let .runtimeNotInstalled(id):
            String(localized: "Runtime “\(id)” is not installed.")
        case .dmgLayoutUnrecognized:
            // swiftlint:disable line_length
            String(
                localized: "This disk image doesn’t look like Apple’s “Evaluation environment for Windows games”. Download it from developer.apple.com/download (search for “Evaluation environment”)."
            )
        case .dmgSignatureInvalid:
            String(
                localized: "The libraries in this disk image are not signed by Apple, so they were not imported. Download the original from developer.apple.com/download and try again."
            )
            // swiftlint:enable line_length
        }
    }
}
