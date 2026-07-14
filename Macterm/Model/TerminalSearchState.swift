import Combine
import Foundation

@MainActor @Observable
final class TerminalSearchState {
    var needle: String = ""
    var total: Int?
    var selected: Int?
    var isVisible: Bool = false

    var displayText: String {
        guard let total else { return "" }
        guard let selected else { return "\(total) matches" }
        return "\(selected + 1) of \(total)"
    }

    /// Needles at least this long search instantly; shorter (1–2 char) needles
    /// are debounced, since a 1–2 char prefix matches almost everything and
    /// thrashing ghostty's search on every keystroke is wasteful.
    private static let minInstantSearchLength = 3
    /// How long to hold a short needle before searching, coalescing rapid typing.
    private static let shortNeedleDebounce = DispatchQueue.SchedulerTimeType.Stride.milliseconds(300)

    @ObservationIgnored
    private var cancellable: AnyCancellable?
    @ObservationIgnored
    private var subject = PassthroughSubject<String, Never>()

    func startPublishing(send: @escaping (String) -> Void) {
        cancellable = subject
            .removeDuplicates()
            .map { needle -> AnyPublisher<String, Never> in
                if needle.isEmpty || needle.count >= Self.minInstantSearchLength {
                    return Just(needle).eraseToAnyPublisher()
                }
                // switchToLatest cancels this pending delay if a new needle
                // arrives first, so only the final short needle actually fires.
                return Just(needle)
                    .delay(for: Self.shortNeedleDebounce, scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { send($0) }
    }

    func pushNeedle() {
        subject.send(needle)
    }

    func stopPublishing() {
        cancellable = nil
    }
}
