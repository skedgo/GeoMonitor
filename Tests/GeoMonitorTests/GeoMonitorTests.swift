import XCTest
import CoreLocation

@testable import GeoMonitor

final class GeoMonitorTests: XCTestCase {
  func testManyRegions() throws {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct
    // results.
    
    let regions: [PrioritizedRegion] = [
      .init(-31.959492, 115.87516, 900, 400),
      .init(-31.953156, 115.877762, 900, 400),
      .init(-31.95963, 115.8713, 900, 400),
      .init(-31.947182, 115.890045, 900, 400),
      .init(-31.958626, 115.868134, 900, 400),
      .init(-31.950016, 115.876831, 900, 400),
      .init(-31.949875, 115.893112, 900, 400),
      .init(-31.957192, 115.876183, 900, 400),
      .init(-31.943138, 115.854218, 239, 150),
      .init(-31.951407, 115.861664, 184, 150),
      .init(-31.943138, 115.854218, 226, 150),
      .init(-31.951407, 115.861664, 210, 150),
      .init(-31.943138, 115.854218, 199, 150),
      .init(-31.951407, 115.861664, 183, 150),
      .init(-31.957066, 115.859146, 170, 150),
      .init(-31.957066, 115.859146, 223, 150),
      .init(-31.957066, 115.859146, 179, 150),
      .init(-31.943138, 115.854218, 296, 150),
      .init(-31.958574, 115.858421, 318, 150),
      .init(-31.943138, 115.854218, 278, 150),
      .init(-31.957066, 115.859146, 172, 150),
      .init(-31.943686, 115.922653, 208, 150),
      .init(-31.943686, 115.922653, 224, 150),
      .init(-31.9938, 115.913, 157, 150),
      .init(-31.958574, 115.858421, 472, 150),
      .init(-32.012253, 115.856537, 137, 150),
      .init(-31.958574, 115.858421, 321, 150),
      .init(-31.907438, 115.821877, 816, 150),
      .init(-31.953903, 115.8945, 424, 150),
      .init(-32.012253, 115.856537, 189, 150),
      .init(-31.907438, 115.821877, 695, 150),
      .init(-31.953903, 115.8945, 303, 150),
      .init(-31.940687, 116.015968, 140, 150),
      .init(-31.907438, 115.821877, 818, 150),
      .init(-31.958574, 115.858421, 349, 150),
      .init(-31.957066, 115.859146, 212, 150),
      .init(-31.907438, 115.821877, 824, 150),
      .init(-31.940687, 116.015968, 136, 150),
      .init(-31.913763, 115.823273, 332, 150),
      .init(-31.947477, 115.878456, 229, 150),
      .init(-31.957066, 115.859146, 167, 150),
      .init(-31.913763, 115.823273, 392, 150),
      .init(-31.8883, 115.801453, 140, 150),
      .init(-31.907438, 115.821877, 192, 150),
      .init(-31.907438, 115.821877, 408, 150),
      .init(-31.951407, 115.861664, 172, 150),
      .init(-31.943138, 115.854218, 295, 150),
      .init(-31.943686, 115.922653, 194, 150),
      .init(-31.873867, 115.76548, 151,  150),
      .init(-31.943686, 115.922653, 226,  150),
      .init(-31.9938, 115.913, 127,  150),
      .init(-31.943686, 115.922653, 217,  150),
      .init(-31.873867, 115.76548, 175,  150),
      .init(-31.951407, 115.861664, 241,  150),
      .init(-31.899336, 115.971687, 212,  150),
      .init(-31.913763, 115.823273, 315,  150),
      .init(-31.957066, 115.859146, 168,  150),
      .init(-31.907438, 115.821877, 817,  150),
      .init(-31.953903, 115.8945, 425,  150),
      .init(-31.940687, 116.015968, 127,  150),
      .init(-31.947477, 115.878456, 235,  150),
      .init(-31.940687, 116.015968, 130,  150),
      .init(-31.958574, 115.858421, 451,  150),
      .init(-31.907438, 115.821877, 799,  150),
      .init(-31.907438, 115.821877, 804,  150),
      .init(-31.947477, 115.878456, 234,  150),
      .init(-31.947477, 115.878456, 223,  150),
      .init(-31.947477, 115.878456, 230,  150),
      .init(-31.947477, 115.878456, 234,  150),
      .init(-31.96996, 115.893616, 122,  150),
      .init(-31.96996, 115.893616, 122,  150),
      .init(-31.873867, 115.76548, 158,  150),
      .init(-31.913763, 115.823273, 400,150),
      .init(-31.8883, 115.801453, 148, 150),
      .init(-31.907438, 115.821877, 672,  150),
      .init(-31.953903, 115.8945, 280,  150),
      .init(-31.943138, 115.854218, 291,  150),
      .init(-31.96996, 115.893616, 126,  150),
      .init(-31.907438, 115.821877, 529,  150),
      .init(-31.953903, 115.8945, 137,  150),
      .init(-31.958574, 115.858421, 357,  150),
      .init(-31.958574, 115.858421, 511,  150),
      .init(-31.958574, 115.858421, 508,  150),
      .init(-31.958574, 115.858421, 533,  150),
      .init(-32.012253, 115.856537, 145,  150),
      .init(-32.012253, 115.856537, 184,  150),
      .init(-31.907438, 115.821877, 827,  150),
      .init(-31.953903, 115.8945, 435,  150),
      .init(-31.940687, 116.015968, 191,  150),
      .init(-31.940687, 116.015968, 156,  150),
      .init(-31.958574, 115.858421, 486,  150),
    ]

    let needle = CLLocation(latitude: -31.9586, longitude: 115.8681)

    let withoutLocation = GeoMonitor.determineRegionsToMonitor(regions: regions, location: nil, max: 19)
    XCTAssertEqual(withoutLocation.count, 19)
    XCTAssertFalse(withoutLocation.allSatisfy { needle.distance(from: .init(latitude: $0.center.latitude, longitude: $0.center.longitude)) <= 5_000 })
    XCTAssertEqual(withoutLocation.compactMap { $0 as? PrioritizedRegion }.map(\.priority).min() ?? 0, 529) // highest priorities
    XCTAssertEqual(withoutLocation.compactMap { $0 as? PrioritizedRegion }.map(\.priority).max(), 900)
    XCTAssertEqual(withoutLocation.compactMap { $0 as? PrioritizedRegion }.filter { $0.priority == 900 }.count, 8) // all top priorities included
    
    let withLocation = GeoMonitor.determineRegionsToMonitor(regions: regions, location: needle, max: 19)
    XCTAssertEqual(withLocation.count, 19)
    XCTAssertTrue(withLocation.allSatisfy { needle.distance(from: .init(latitude: $0.center.latitude, longitude: $0.center.longitude)) <= 5_000 })
    XCTAssertEqual(withLocation.compactMap { $0 as? PrioritizedRegion }.map(\.priority).min() ?? 0, 349) // highest priorities
    XCTAssertEqual(withLocation.compactMap { $0 as? PrioritizedRegion }.map(\.priority).max(), 900)
    XCTAssertEqual(withLocation.compactMap { $0 as? PrioritizedRegion }.filter { $0.priority == 900 }.count, 8) // all top priorities included
  }
}

extension PrioritizedRegion {
  convenience init(_ lat: Double, _ lng: Double, _ prio: Int, _ radius: Double) {
    self.init(center: .init(latitude: lat, longitude: lng), radius: radius, identifier: UUID().uuidString, priority: prio)
  }
}
