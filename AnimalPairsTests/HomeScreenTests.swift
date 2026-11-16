import SwiftUI
import UIKit
import XCTest
@testable import AnimalPairs

@MainActor
final class HomeScreenTests: XCTestCase {
    private func spec() throws -> HomeLayoutSpec {
        try XCTUnwrap(HomeLayoutSpec.shared, "HomeLayout.json must be bundled and valid")
    }

    func testEachFriendAppearsExactlyOnceInBothLayouts() throws {
        let spec = try spec()
        for name in ["wide", "tall"] {
            let layout = try XCTUnwrap(spec.layouts[name])
            XCTAssertEqual(Set(layout.characters.keys), Set(HomeLayoutSpec.characterIDs), name)
            XCTAssertEqual(layout.characters.count, 10, name)
        }
        XCTAssertEqual(HomeLayoutSpec.characterIDs.filter { $0 == "iris" }.count, 1)
    }

    func testIrisIsTheCentralHost() throws {
        let spec = try spec()
        for (name, layout) in spec.layouts {
            let iris = try XCTUnwrap(layout.characters["iris"])
            XCTAssertEqual(iris.cx, 0.5, accuracy: 0.001, name)
            for (id, other) in layout.characters where id != "iris" {
                XCTAssertGreaterThan(iris.height, other.height, "Iris is the largest in \(name)")
            }
        }
    }

    func testLayoutChoiceForIPadAndIPhone() throws {
        let spec = try spec()
        XCTAssertTrue(spec.layout(for: CGSize(width: 1180, height: 776))?.characters.count == 10)
        XCTAssertEqual(spec.layout(for: CGSize(width: 1180, height: 776))?.play.width, spec.layouts["wide"]?.play.width)
        XCTAssertEqual(spec.layout(for: CGSize(width: 393, height: 759))?.play.width, spec.layouts["tall"]?.play.width)
    }

    func testEveryHomeLayerAndTheWordmarkAreBundled() {
        for id in HomeLayoutSpec.characterIDs {
            XCTAssertNotNil(UIImage(named: "home_\(id)"), "missing home_\(id)")
        }
        XCTAssertNotNil(UIImage(named: BrandGraphic.wordmark))
    }

    func testWobbleStaysWithinItsLimits() throws {
        let spec = try spec()
        for (id, motion) in spec.motion {
            for step in 0..<400 {
                let w = Wobble.at(time: Double(step) * 0.05, motion: motion)
                XCTAssertLessThanOrEqual(abs(w.rotation), motion.rotation + 1e-9, id)
                XCTAssertGreaterThanOrEqual(w.rise, -1e-9, "\(id) never sinks below its feet")
                XCTAssertLessThanOrEqual(w.rise, motion.bob + 1e-9, id)
                XCTAssertGreaterThanOrEqual(w.scale, 1 - 1e-9, id)
                XCTAssertLessThanOrEqual(w.scale, 1 + motion.scale + 1e-9, id)
            }
            XCTAssertLessThanOrEqual(motion.rotation, id == "iris" ? 3 : 2)
        }
    }

    func testStillPoseIsNeutral() {
        XCTAssertEqual(Wobble.still, Wobble(rotation: 0, rise: 0, scale: 1))
    }

    func testFriendsMoveOutOfStep() throws {
        let spec = try spec()
        let poses = HomeLayoutSpec.characterIDs.compactMap { id in spec.motion[id].map { Wobble.at(time: 10, motion: $0) } }
        XCTAssertEqual(poses.count, 10)
        XCTAssertGreaterThan(Set(poses.map { ($0.rotation * 100).rounded() }).count, 6, "staggered, not in unison")
    }
}
