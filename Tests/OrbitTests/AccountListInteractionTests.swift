import XCTest
@testable import Orbit

final class AccountListInteractionTests: XCTestCase {
    func testPreviewOrderMovesDraggedAccountDownAfterCrossingNextRowMidpoint() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let frames: [UUID: CGRect] = [
            first: CGRect(x: 0, y: 0, width: 100, height: 80),
            second: CGRect(x: 0, y: 88, width: 100, height: 80),
            third: CGRect(x: 0, y: 176, width: 100, height: 80),
        ]

        let reordered = AccountListReorderLogic.previewOrder(
            currentOrder: [first, second, third],
            draggedAccountID: second,
            draggedMidY: 230,
            rowFrames: frames
        )

        XCTAssertEqual(reordered, [first, third, second])
    }

    func testPreviewOrderMovesDraggedAccountUpAfterCrossingPreviousRowMidpoint() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let frames: [UUID: CGRect] = [
            first: CGRect(x: 0, y: 0, width: 100, height: 80),
            second: CGRect(x: 0, y: 88, width: 100, height: 80),
            third: CGRect(x: 0, y: 176, width: 100, height: 80),
        ]

        let reordered = AccountListReorderLogic.previewOrder(
            currentOrder: [first, second, third],
            draggedAccountID: third,
            draggedMidY: 20,
            rowFrames: frames
        )

        XCTAssertEqual(reordered, [third, first, second])
    }

    func testPreviewOrderKeepsOrderWhenDraggedCardStaysInCurrentSlot() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let frames: [UUID: CGRect] = [
            first: CGRect(x: 0, y: 0, width: 100, height: 80),
            second: CGRect(x: 0, y: 88, width: 100, height: 80),
            third: CGRect(x: 0, y: 176, width: 100, height: 80),
        ]

        let reordered = AccountListReorderLogic.previewOrder(
            currentOrder: [first, second, third],
            draggedAccountID: second,
            draggedMidY: 125,
            rowFrames: frames
        )

        XCTAssertEqual(reordered, [first, second, third])
    }

    func testDestinationAccountIDUsesPreviousItemWhenDraggingDown() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let destination = AccountListReorderLogic.destinationAccountID(
            currentOrder: [first, second, third],
            previewOrder: [first, third, second],
            draggedAccountID: second
        )

        XCTAssertEqual(destination, third)
    }

    func testDestinationAccountIDUsesNextItemWhenDraggingUp() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let destination = AccountListReorderLogic.destinationAccountID(
            currentOrder: [first, second, third],
            previewOrder: [third, first, second],
            draggedAccountID: third
        )

        XCTAssertEqual(destination, first)
    }

    func testAutoScrollVelocityIsZeroInCenterRegion() {
        XCTAssertEqual(
            AccountListAutoScrollLogic.velocity(pointerY: 160, viewportHeight: 320),
            0
        )
    }

    func testAutoScrollVelocityIncreasesTowardEdgesAndClamps() {
        XCTAssertEqual(
            AccountListAutoScrollLogic.velocity(pointerY: 0, viewportHeight: 320),
            -AccountListAutoScrollLogic.maximumPointsPerSecond
        )
        XCTAssertEqual(
            AccountListAutoScrollLogic.velocity(pointerY: 320, viewportHeight: 320),
            AccountListAutoScrollLogic.maximumPointsPerSecond
        )

        let upperVelocity = AccountListAutoScrollLogic.velocity(pointerY: 16, viewportHeight: 320)
        let lowerVelocity = AccountListAutoScrollLogic.velocity(pointerY: 304, viewportHeight: 320)

        XCTAssertEqual(upperVelocity, -AccountListAutoScrollLogic.maximumPointsPerSecond / 2, accuracy: 0.001)
        XCTAssertEqual(lowerVelocity, AccountListAutoScrollLogic.maximumPointsPerSecond / 2, accuracy: 0.001)
    }
}
