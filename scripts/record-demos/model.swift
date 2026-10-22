// Prints whether Apple's on-device model can run on this Mac right now —
// `available`, or `unavailable <reason>`. Demo 12 explains output with it.
import FoundationModels

switch SystemLanguageModel.default.availability {
case .available:
    print("available")
case let .unavailable(reason):
    print("unavailable \(reason)")
}
