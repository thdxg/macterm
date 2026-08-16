import Foundation
@testable import Macterm
import Testing

/// The pane drag's wire form. Two drop paths decode it — the workspace
/// leaves read the drag pasteboard directly, the sidebar imports it as a
/// `Transferable` — and both go through `MovablePane(payload:)`, so this
/// pins the codec they share.
@MainActor
struct PaneDragDropTests {
    @Test
    func payload_round_trips_the_pane_id() throws {
        let id = UUID()
        let decoded = try #require(MovablePane(payload: MovablePane.payload(for: id)))
        #expect(decoded.paneID == id)
    }

    @Test
    func payload_is_the_uuid_as_sixteen_raw_bytes() {
        #expect(MovablePane.payload(for: UUID()).count == 16)
    }

    /// A short, long, or empty payload is "not a pane drag", never a
    /// half-decoded UUID: the raw bytes are loaded unaligned straight out of
    /// the buffer, so the length check is what keeps that read in bounds.
    @Test
    func payload_of_the_wrong_length_is_rejected() {
        #expect(MovablePane(payload: Data()) == nil)
        #expect(MovablePane(payload: Data(repeating: 0, count: 15)) == nil)
        #expect(MovablePane(payload: Data(repeating: 0, count: 17)) == nil)
    }
}
