import Testing
import CoreGraphics
@testable import Macuake

@Suite(.serialized)
struct ResizeEdgeTests {

    @Test func resizeEdge_hasFiveCases() {
        let edges: [ResizeEdge] = [.left, .right, .bottom, .bottomLeft, .bottomRight]

        switch edges[0] { case .left: break; default: Issue.record("Expected .left") }
        switch edges[1] { case .right: break; default: Issue.record("Expected .right") }
        switch edges[2] { case .bottom: break; default: Issue.record("Expected .bottom") }
        switch edges[3] { case .bottomLeft: break; default: Issue.record("Expected .bottomLeft") }
        switch edges[4] { case .bottomRight: break; default: Issue.record("Expected .bottomRight") }
    }

    @Test func resizeEdge_casesAreDistinct() {
        let cases: [ResizeEdge] = [.left, .right, .bottom, .bottomLeft, .bottomRight]
        for i in 0..<cases.count {
            for j in (i + 1)..<cases.count {
                #expect(cases[i] != cases[j])
            }
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

    // MARK: - Proportional corner scaling (top-center anchor)

    @Test func bottomRight_dragDownRight_growsProportionally() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottomRight,
            translation: CGSize(width: 100, height: 100),
            screen: screen
        )
        #expect(abs(result.width - 1200) < 0.5)
        #expect(abs(result.height - 600) < 0.5)
    }

    @Test func bottomRight_dragUpLeft_shrinksProportionally() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottomRight,
            translation: CGSize(width: -100, height: -100),
            screen: screen
        )
        #expect(abs(result.width - 800) < 0.5)
        #expect(abs(result.height - 400) < 0.5)
    }

    @Test func bottomLeft_dragDownLeft_growsProportionally() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottomLeft,
            translation: CGSize(width: -100, height: 100),
            screen: screen
        )
        #expect(abs(result.width - 1200) < 0.5)
        #expect(abs(result.height - 600) < 0.5)
    }

    @Test func corner_preservesAspectRatio() {
        let start = CGSize(width: 1000, height: 500)
        let result = ResizePreview.size(
            start: start,
            edge: .bottomRight,
            translation: CGSize(width: 137, height: -23),
            screen: screen
        )
        #expect(abs(result.width / result.height - start.width / start.height) < 0.001)
    }

    @Test func corner_clampedToMinimumSize() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottomRight,
            translation: CGSize(width: -400, height: -400),
            screen: screen
        )
        #expect(abs(result.width - 300) < 0.5)
        #expect(abs(result.height - result.width / 2) < 0.5)
    }

    @Test func corner_clampedToMaximumSize() {
        let result = ResizePreview.size(
            start: CGSize(width: 1000, height: 500),
            edge: .bottomRight,
            translation: CGSize(width: 1000, height: 1000),
            screen: screen
        )
        #expect(abs(result.width - screen.width) < 0.5)
        #expect(abs(result.height - result.width / 2) < 0.5)
    }
}
