import XCTest
@testable import MacPlatform

/// Exercise focus transitions independently of TCC, other applications, and the translation provider.
final class InputFocusHandoffTests: XCTestCase {
    /// A source that already owns the original field must not fail merely because the overlay is inactive.
    @MainActor func testAlreadyFocusedSourceNeedsNoActivation() async throws {
        let session = Session()
        session.foreground = .destination
        session.focused = true
        try await session.restore()
        XCTAssertEqual(session.activations, 0)
        XCTAssertEqual(session.focusRequests, 0)
        XCTAssertEqual(session.dismissals, 1)
    }

    /// A different field selected in an already-active source is user navigation, not a restoration request.
    @MainActor func testDifferentFieldIsNotOverridden() async {
        let session = Session()
        session.foreground = .destination
        do { try await session.restore(); XCTFail("Expected field change") }
        catch { XCTAssertEqual(error as? InputFocusHandoff.Failure, .fieldChanged) }
        XCTAssertEqual(session.activations, 0)
        XCTAssertEqual(session.focusRequests, 0)
    }

    /// Simulate an Electron-style asynchronous activation followed by restoring its inner editor.
    @MainActor func testDelayedActivationExplicitlyRestoresOriginalField() async throws {
        let session = Session()
        session.onPause = {
            if session.pauses >= 2 { session.foreground = .destination }
            if session.focusRequests > 0 { session.focused = true }
        }
        try await session.restore()
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(session.focusRequests, 1)
        XCTAssertTrue(session.focused)
    }

    /// Dismissing the overlay can itself activate the source; keep ownership of that expected handoff.
    @MainActor func testDismissalReturningFocusToSourceStillRestoresField() async throws {
        let session = Session()
        session.onDismiss = { session.foreground = .destination }
        session.onPause = { if session.focusRequests > 0 { session.focused = true } }
        try await session.restore()
        XCTAssertEqual(session.dismissals, 1)
        XCTAssertEqual(session.focusRequests, 1)
    }

    /// Switching to a third application while waiting must never trigger a second activation or refocus.
    @MainActor func testSwitchingAppsDuringHandoffStopsRestoration() async {
        let session = Session()
        session.onPause = { session.foreground = .other }
        do { try await session.restore(); XCTFail("Expected application change") }
        catch { XCTAssertEqual(error as? InputFocusHandoff.Failure, .applicationChanged) }
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(session.focusRequests, 0)
    }

    /// A translation finishing after the user leaves the app must not steal focus back.
    @MainActor func testOtherApplicationIsNeverActivatedAwayFrom() async {
        let session = Session()
        session.foreground = .other
        do { try await session.restore(); XCTFail("Expected application change") }
        catch { XCTAssertEqual(error as? InputFocusHandoff.Failure, .applicationChanged) }
        XCTAssertEqual(session.activations, 0)
    }

    /// Changes to text or selection during activation invalidate the snapshot before any focus request.
    @MainActor func testChangedSnapshotDuringActivationStopsHandoff() async {
        let session = Session()
        session.onPause = {
            session.foreground = .destination
            session.snapshotChanged = true
        }
        do { try await session.restore(); XCTFail("Expected changed input") }
        catch { XCTAssertTrue(error is Session.ChangedInput) }
        XCTAssertEqual(session.focusRequests, 0)
    }

    /// A source that refuses activation reports a bounded restoration failure, not a user focus change.
    @MainActor func testActivationTimeoutIsSpecificAndBounded() async {
        let session = Session()
        do { try await session.restore(); XCTFail("Expected restoration timeout") }
        catch { XCTAssertEqual(error as? InputFocusHandoff.Failure, .restorationFailed) }
        XCTAssertEqual(session.pauses, 24)
        XCTAssertEqual(session.focusRequests, 0)
    }

    /// Cancellation ends the handoff without attempting to restore or mutate an input field.
    @MainActor func testCancellationDuringActivation() async {
        let session = Session()
        session.cancelDuringPause = true
        do { try await session.restore(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(session.focusRequests, 0)
    }
}

/// A controllable desktop models asynchronous activation without simulating any real keyboard input.
@MainActor
private final class Session {
    struct ChangedInput: Error {}
    var foreground: InputFocusHandoff.Foreground = .overlay
    var focused = false
    var snapshotChanged = false
    var activations = 0
    var dismissals = 0
    var focusRequests = 0
    var pauses = 0
    var cancelDuringPause = false
    var onPause: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// The real handoff owns ordering and retries; this fixture only supplies the changing desktop state.
    func restore() async throws {
        try await InputFocusHandoff.restore(
            foreground: { self.foreground },
            dismissOverlay: {
                self.dismissals += 1
                self.onDismiss?()
            },
            validateTarget: { if self.snapshotChanged { throw ChangedInput() } },
            isTargetFocused: { self.focused },
            activateTarget: { self.activations += 1 },
            focusTarget: { self.focusRequests += 1 },
            pause: {
                self.pauses += 1
                if self.cancelDuringPause { throw CancellationError() }
                self.onPause?()
            }
        )
    }
}
