
import Foundation
import CoreLocation
import MapKit

public protocol GeoMonitorDataSource {
  func fetchRegions(trigger: GeoMonitor.FetchTrigger) async -> [CLCircularRegion]
}


public class GeoMonitor: NSObject, ObservableObject {
  enum Constants {
    #if DEBUG
    static var currentLocationRegionMaximumRadius: CLLocationDistance = 400
    static var currentLocationRegionRadiusDelta: CLLocationDistance   = 350
    #else
    static var currentLocationRegionMaximumRadius: CLLocationDistance = 2_500
    static var currentLocationRegionRadiusDelta: CLLocationDistance   = 2_000
    #endif
    static var maximumDistanceToRegionCenter: CLLocationDistance   = 25_000
  }
  
  public enum FetchTrigger: String {
    case initial
    case visitMonitoring
    case regionMonitoring
    case departedCurrentArea
  }
  
  public enum LocationFetchError: Error {
    case accessNotProvided
    
    /// Happens if you stop monitoring before a location could be found
    case noLocationFetchedInTime
    
    /// Happens if no accurate fix could be found, best location attached
    case locationInaccurate(CLLocation)
  }

#if DEBUG
  public enum DebugKind {
    case updatedCurrentLocationRegion
    case enteredRegion
    case visitMonitoring
    case stateChange
    case failure
  }
#endif

  public enum Event {
#if DEBUG
    case debug(String, DebugKind)
#endif
    case entered(CLCircularRegion, CLLocation?)
  }
  
  private let fetchSource: GeoMonitorDataSource
  let eventHandler: (Event) -> Void
  
  private let locationManager: CLLocationManager
  
  public var maxRegionsToMonitor = 20

  /// Instantiates new monitor
  /// - Parameters:
  ///   - fetch: Handler that's called when the monitor decides it's a good time to update the regions to monitor. Should fetch and then return all regions to be monitored (even if they didn't change).
  ///   - onEvent: Handler that's called when a relevant event is happening, including when one of the monitored regions is entered.
  public convenience init(fetch: @escaping (GeoMonitor.FetchTrigger) async -> [CLCircularRegion], onEvent: @escaping (Event) -> Void) {
    self.init(dataSource: SimpleDataSource(handler: fetch), onEvent: onEvent)
  }
  
  public init(dataSource: GeoMonitorDataSource, onEvent: @escaping (Event) -> Void) {
    fetchSource = dataSource
    eventHandler = onEvent
    locationManager = .init()
    hasAccess = false
    
    super.init()
    
    locationManager.delegate = self
    
#if !DEBUG
    locationManager.activityType = .automotiveNavigation
#endif
  }
  
  // MARK: - Access
  
  @Published public var hasAccess: Bool
  
  private var askHandler: (Bool) -> Void = { _ in }

  public var canAsk: Bool {
    switch locationManager.authorizationStatus {
    case .notDetermined:
      return true
    case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
  
  private func updateAccess() {
    switch locationManager.authorizationStatus {
    case .authorizedAlways:
      hasAccess = true
      enableInBackground = true
    case .authorizedWhenInUse:
      hasAccess = true
      enableInBackground = false
    case .denied, .notDetermined, .restricted:
      hasAccess = false
      enableInBackground = false
    @unknown default:
      hasAccess = false
      enableInBackground = false
    }
  }
  
  public func ask(forBackground: Bool = false, _ handler: @escaping (Bool) -> Void = { _ in }) {
    self.askHandler = handler
    if forBackground {
      locationManager.requestAlwaysAuthorization()
    } else {
      locationManager.requestWhenInUseAuthorization()
    }
  }

  
  // MARK: - Location tracking
  
  @Published public var currentLocation: CLLocation?

  @Published public var isTracking: Bool = false {
    didSet {
      if isTracking {
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 250
        locationManager.startUpdatingLocation()
      } else {
        locationManager.stopUpdatingLocation()
      }
    }
  }
  
  // MARK: - Location fetching

  private var withNextLocation: [(Result<CLLocation, Error>) -> Void] = []
  
  private var fetchTimer: Timer?
  
  private func fetchCurrentLocation() async throws -> CLLocation {
    guard hasAccess else {
      throw LocationFetchError.accessNotProvided
    }
    
    let originalAccuracy = locationManager.desiredAccuracy
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    locationManager.requestLocation()
    
    fetchTimer = .scheduledTimer(withTimeInterval: 30, repeats: false) { [unowned self] _ in
      self.notify(.failure(LocationFetchError.noLocationFetchedInTime))
    }
    
    return try await withCheckedThrowingContinuation { continuation in
      withNextLocation.append({ [unowned self] result in
        self.locationManager.desiredAccuracy = originalAccuracy
        continuation.resume(with: result)
      })
    }
  }
  
  private func notify(_ result: Result<CLLocation, Error>) {
    fetchTimer?.invalidate()
    fetchTimer = nil
    
    withNextLocation.forEach {
      $0(result)
    }
    withNextLocation = []
  }
  
  // MARK: - Current region monitoring
  
  @Published public var enableInBackground: Bool = false {
    didSet {
      guard enableInBackground != oldValue else { return }
      if enableInBackground, (locationManager.authorizationStatus == .notDetermined || locationManager.authorizationStatus == .authorizedWhenInUse) {
        ask(forBackground: true)
      } else {
        updateAccess()
      }
    }
  }
  
  private var regionsToMonitor: [CLCircularRegion] = []

  private var isMonitoring: Bool = false
  
  private var currentLocationRegion: CLRegion? = nil
  
  public var enableVisitMonitoring = true {
    didSet {
      if isMonitoring {
        if enableVisitMonitoring {
          locationManager.startMonitoringVisits()
        } else {
          locationManager.stopMonitoringVisits()
        }
      }
    }
  }
  
  public func startMonitoring() {
    guard !isMonitoring, hasAccess else { return }
    
    isMonitoring = true
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = enableInBackground // we can do that, as it implies "always on" permissions

    Task {
      // It's okay for this to fail, but best to enable visit monitoring as
      // a backup.
      try? await monitorCurrentArea()
    }
    
    if enableVisitMonitoring {
      locationManager.startMonitoringVisits()
    }
  }
  
  public func stopMonitoring() {
    guard isMonitoring else { return }
    
    isMonitoring = false
    locationManager.allowsBackgroundLocationUpdates = false
    locationManager.pausesLocationUpdatesAutomatically = true

    stopMonitoringCurrentArea()
    locationManager.stopMonitoringVisits()
  }
  
  public func update(regions: [CLCircularRegion]) async {
    let location = try? await fetchCurrentLocation()
    monitor(regions, location: location)
  }
 
}

// MARK: - Trigger on move

extension GeoMonitor {
  
  func runUpdateCycle(trigger: FetchTrigger) async {
    // Re-monitor current area, so that it updates the data again
    // and also fetch current location at same time, to prioritise monitoring
    // when we leave it.
    let location = try? await monitorCurrentArea()

    // Ask to fetch data and wait for this to complete
    let regions = await fetchSource.fetchRegions(trigger: trigger)
    monitor(regions, location: location)
  }

  func monitorCurrentArea() async throws -> CLLocation {
    let location = try await fetchCurrentLocation()

    // Monitor a radius around it, using a single fixed "my location" circle
    if let previous = currentLocationRegion as? CLCircularRegion, previous.contains(location.coordinate) {
      return location
    }
      
    // Monitor new region
    let region = CLCircularRegion(
      center: location.coordinate,
      radius:
      // "In iOS 6, regions with a radius between 1 and 400 meters work better on iPhone 4S or later devices. "
        min(Constants.currentLocationRegionMaximumRadius,
      // "This property defines the largest boundary distance allowed from a region’s center point. Attempting to monitor a region with a distance larger than this value causes the location manager to send a CLError.Code.regionMonitoringFailure error to the delegate."
            min(self.locationManager.maximumRegionMonitoringDistance,
                
                location.horizontalAccuracy + Constants.currentLocationRegionRadiusDelta
               )
           ),
      identifier: "current-location"
    )
    self.currentLocationRegion = region
    self.locationManager.startMonitoring(for: region)
      
#if DEBUG
    eventHandler(.debug("GeoMonitor is monitoring \(MKDistanceFormatter().string(fromDistance: region.radius))...", .updatedCurrentLocationRegion))
#endif

    // ... continues in `didExitRegion`...
    
    return location
  }
  
  func stopMonitoringCurrentArea() {
    notify(.failure(LocationFetchError.noLocationFetchedInTime))
    currentLocationRegion = nil
  }
}

// MARK: - Alert monitoring logic

extension GeoMonitor {
  
  func monitor(_ regions: [CLCircularRegion], location: CLLocation?) {
    let nearby: [CLCircularRegion]
    if let currentLocation = location {
      nearby = regions.filter { region in
        let distance = currentLocation.distance(from: .init(latitude: region.center.latitude, longitude: region.center.longitude))
        return distance < Constants.maximumDistanceToRegionCenter
      }
    } else {
      nearby = regions
    }
    
    regionsToMonitor = nearby
    
    // Stop monitoring regions that are no irrelevant
    let toBeMonitored = Set(nearby.map(\.identifier))
    for previous in locationManager.monitoredRegions {
      if !toBeMonitored.contains(previous.identifier) && previous.identifier != "current-location" {
        locationManager.stopMonitoring(for: previous)
      }
    }
    
    // New regions to monitor
    let monitoredAlready = locationManager.monitoredRegions.map(\.identifier) // includes current-location
    let toMonitor = nearby.filter { !monitoredAlready.contains($0.identifier) }
    let monitoredCount = monitoredAlready.count + toMonitor.count
    
    // Optionally sort, if we're above the limit
    let sorted: [CLCircularRegion]
    if let currentLocation = location, monitoredCount > maxRegionsToMonitor {
      sorted = toMonitor.sorted { lhs, rhs in
        let leftDistance = currentLocation.distance(from: .init(latitude: lhs.center.latitude, longitude: lhs.center.longitude))
        let rightDistance = currentLocation.distance(from: .init(latitude: rhs.center.latitude, longitude: rhs.center.longitude))
        return leftDistance < rightDistance
      }
    } else {
      sorted = toMonitor
    }
    
    // Now monitor
    sorted
      .prefix(maxRegionsToMonitor - 1) // deduct current-location
      .forEach(locationManager.startMonitoring(for:))
  }
  
}

// MARK: - CLLocationManagerDelegate

extension GeoMonitor: CLLocationManagerDelegate {
  
  public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard region.identifier != currentLocationRegion?.identifier else {
      return // Ignore re-entering current region; we only care about exiting this
    }

    Task {
      // Make sure this is still a *current* region => update data
      await runUpdateCycle(trigger: .regionMonitoring)
      
      // Now we can check
      guard let match = regionsToMonitor.first(where: { $0.identifier == region.identifier }) else {
#if DEBUG
        eventHandler(.debug("GeoMonitor entered outdated region -> \(region)", .enteredRegion))
#endif
        return // Has since disappeared
      }
      
#if DEBUG
      eventHandler(.debug("GeoMonitor entered -> \(region)", .enteredRegion))
#endif
      
      do {
        let location = try await fetchCurrentLocation()
        eventHandler(.entered(match, location))
      } catch {
#if DEBUG
        eventHandler(.debug("GeoMonitor location fetch failed after entering region -> \(error)", .failure))
#endif
        eventHandler(.entered(match, nil))
      }
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard currentLocationRegion?.identifier == region.identifier else {
      return // Ignore exiting a monitored region; we only care about entering these.
    }

    Task {
      // 3. When leaving the current location, fetch...
      await runUpdateCycle(trigger: .departedCurrentArea)
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
#if DEBUG
    if visit.departureDate == .distantFuture {
      eventHandler(.debug("GeoMonitor visit arrival -> \(visit)", .visitMonitoring))
    } else {
      let duration = DateComponentsFormatter().string(from: visit.arrivalDate, to: visit.departureDate) ?? "unknown duration"
      eventHandler(.debug("GeoMonitor visit departure after \(duration) -> \(visit)", .visitMonitoring))
    }
#endif

    Task {
      // TODO: We could detect if it's an arrival at a new location, by checking `visit.departureTime == .distanceFuture`
      await runUpdateCycle(trigger: .visitMonitoring)
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
#if DEBUG
    print("GeoMonitor updated locations -> \(locations)")
#endif
    
    guard let latest = locations.last else { return assertionFailure() }
    
    guard let latestAccurate = locations
      .filter({ $0.horizontalAccuracy <= manager.desiredAccuracy })
      .last
    else {
      notify(.failure(LocationFetchError.locationInaccurate(latest)))
      return
    }

    self.currentLocation = latestAccurate
    
    notify(.success(latestAccurate))
  }
  
  public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
#if DEBUG
    eventHandler(.debug("GeoMonitor paused updates -> \(manager == locationManager)", .stateChange))
#endif
  }
  
  public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
#if DEBUG
    eventHandler(.debug("GeoMonitor resumed updates -> \(manager == locationManager)", .stateChange))
#endif
  }
  
  public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
    eventHandler(.debug("GeoMonitor failed -> \(error) -- \(error.localizedDescription)", .failure))
    print("GeoMonitor's location manager failed: \(error)")
#endif
    
    notify(.failure(error))
  }
  
  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    updateAccess()
    askHandler(hasAccess)
    askHandler = { _ in }
    
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      if isMonitoring {
        startMonitoring()
      }
    case .denied, .notDetermined, .restricted:
      return
    @unknown default:
      return
    }
  }
  
}

// MARK: - Helpers

private struct SimpleDataSource: GeoMonitorDataSource {
  let handler: (GeoMonitor.FetchTrigger) async -> [CLCircularRegion]
  
  func fetchRegions(trigger: GeoMonitor.FetchTrigger) async -> [CLCircularRegion] {
    await handler(trigger)
  }
}
