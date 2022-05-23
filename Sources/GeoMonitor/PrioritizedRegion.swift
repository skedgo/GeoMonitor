//
//  PrioritizedRegion.swift
//  
//
//  Created by Adrian Schönig on 3/5/2022.
//

import Foundation
import CoreLocation

public class PrioritizedRegion: CLCircularRegion {
  
  public let priority: Int
  
  public init(center: CLLocationCoordinate2D, radius: CLLocationDistance, identifier: String, priority: Int) {
    self.priority = priority
    super.init(center: center, radius: radius, identifier: identifier)
  }
  
  public required init?(coder: NSCoder) {
    priority = coder.decodeInteger(forKey: "priority")
    super.init(coder: coder)
  }
  
  public override func encode(with coder: NSCoder) {
    super.encode(with: coder)
    coder.encode(priority, forKey: "priority")
  }
  
}
