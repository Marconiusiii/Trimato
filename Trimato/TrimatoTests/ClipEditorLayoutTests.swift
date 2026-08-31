import CoreGraphics
import Foundation
import Testing
@testable import Trimato

struct ClipEditorLayoutTests {
    @Test func previouslyOverflowingWindowFitsUsableScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let overflow = CGRect(x: 755, y: -80, width: 900, height: 812)
        let fitted = ClipEditorLayout.fitting(overflow, in: screen)
        #expect(screen.contains(fitted))
        #expect(fitted.size == overflow.size)
    }

    @Test func oversizedWindowFitsSmallerDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1280, y: 40, width: 1280, height: 720)
        let fitted = ClipEditorLayout.fitting(CGRect(x: 40, y: 800, width: 1400, height: 1000), in: screen)
        #expect(fitted == screen)
    }

    @Test func alreadyVisibleWindowDoesNotMove() {
        let frame = CGRect(x: 140, y: 80, width: 900, height: 760)
        #expect(ClipEditorLayout.fitting(frame, in: CGRect(x: 0, y: 0, width: 1512, height: 949)) == frame)
    }
}
