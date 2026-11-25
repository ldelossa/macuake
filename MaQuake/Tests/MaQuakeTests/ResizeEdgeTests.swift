import Testing
import CoreGraphics
@testable import Macuake

@Suite(.serialized)
struct ResizeEdgeTests {

    @Test func resizeEdge_hasThreeCases() {
        let edges: [ResizeEdge] = [.left, .right, .bottom]

        switch edges[0] {
        case .left: break
        default: Issue.record("Expected .left")
        }
        switch edges[1] {
        case .right: break
        default: Issue.record("Expected .right")
        }
        switch edges[2] {
        case .bottom: break
        default: Issue.record("Expected .bottom")
        }
    }

    @Test func resizeEdge_casesAreDistinct() {
        let left = ResizeEdge.left
        let right = ResizeEdge.right
        let bottom = ResizeEdge.bottom

        switch (left, right) {
        case (.left, .right): break
        default: Issue.record("left and right should differ")
        }
        switch (left, bottom) {
        case (.left, .bottom): break
        default: Issue.record("left and bottom should differ")
        }
        switch (right, bottom) {
        case (.right, .bottom): break
        default: Issue.record("right and bottom should differ")
        }
    }
}

@Suite(.serialized)
struct ResizePreviewMathTests {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func leftEdge_dragOutward_widensByTwiceTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .left,
            translation: CGSize(width: -100, height: 0),
            screen: screen
        )
        #expect(result.width == 1200)
        #expect(result.height == 500)
    }

    @Test func leftEdge_dragInward_narrowsByTwiceTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .left,
            translation: CGSize(width: 40, height: 0),
            screen: screen
        )
        #expect(result.width == 920)
        #expect(result.height == 500)
    }

    @Test func rightEdge_dragOutward_widensByTwiceTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .right,
            translation: CGSize(width: 50, height: 0),
            screen: screen
        )
        #expect(result.width == 1100)
        #expect(result.height == 500)
    }

    @Test func rightEdge_dragInward_narrowsByTwiceTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .right,
            translation: CGSize(width: -60, height: 0),
            screen: screen
        )
        #expect(result.width == 880)
        #expect(result.height == 500)
    }

    @Test func bottomEdge_dragDown_tallensByTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottom,
            translation: CGSize(width: 0, height: 80),
            screen: screen
        )
        #expect(result.width == 1000)
        #expect(result.height == 580)
    }

    @Test func bottomEdge_dragUp_shortensByTranslation() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottom,
            translation: CGSize(width: 0, height: -100),
            screen: screen
        )
        #expect(result.width == 1000)
        #expect(result.height == 400)
    }

    @Test func width_clampedToMinimum300() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .left,
            translation: CGSize(width: 500, height: 0),
            screen: screen
        )
        #expect(result.width == 300)
    }

    @Test func width_clampedToScreenWidth() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .right,
            translation: CGSize(width: 5000, height: 0),
            screen: screen
        )
        #expect(result.width == screen.width)
    }

    @Test func height_clampedToMinimum150() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottom,
            translation: CGSize(width: 0, height: -5000),
            screen: screen
        )
        #expect(result.height == 150)
    }

    @Test func height_clampedToNinetyPercentOfScreen() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottom,
            translation: CGSize(width: 0, height: 5000),
            screen: screen
        )
        #expect(result.height == screen.height * 0.9)
    }

    @Test func leftRight_doNotChangeHeight() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .right,
            translation: CGSize(width: 100, height: 999),
            screen: screen
        )
        #expect(result.height == 500)
    }

    @Test func bottom_doesNotChangeWidth() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottom,
            translation: CGSize(width: 999, height: 100),
            screen: screen
        )
        #expect(result.width == 1000)
    }
}
