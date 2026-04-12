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
        return "\(selected) of \(total)"
    }

    @ObservationIgnored
    private var cancellable: AnyCancellable?
    @ObservationIgnored
    private var subject = PassthroughSubject<String, Never>()

    func startPublishing(send: @escaping (String) -> Void) {
        cancellable = subject
            .removeDuplicates()
            .map { needle -> AnyPublisher<String, Never> in
                if needle.isEmpty || needle.count >= 3 {
                    return Just(needle).eraseToAnyPublisher()
                }
                return Just(needle).delay(for: .milliseconds(300), scheduler: DispatchQueue.main).eraseToAnyPublisher()
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
