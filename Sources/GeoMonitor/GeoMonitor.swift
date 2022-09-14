
import Foundation
import CoreLocation
import MapKit

public protocol GeoMonitorDataSource {
  func fetchRegions(trigger: GeoMonitor.FetchTrigger) async -> [CLCircularRegion]
}


/// Monitors the user's current location and triggers events when entering previously registered
/// regions; also stays up-to-date by checking for new regions whenever the user moves significantly.
///
/// Typical use cases:
/// - Monitoring dynamic regions that are of some relevant to the user and where the user wants to be
///   alerted, when they get to them (e.g., traffic incidents); where monitoring can be long-term.
/// - Monitoring a set of regions where the user wants to be alerted as they approach them, but
///   monitoring is limited for brief durations (e.g., "get off here" alerts for transit apps)
public class GeoMonitor: NSObject, ObservableObject {
  enum Constants {
    static var currentLocationRegionMaximumRadius: CLLocationDistance      = 2_500
    static var currentLocationRegionRadiusDelta: CLLocationDistance        = 2_000
    static var maximumDistanceToRegionCenter: CLLocationDistance           = 10_000
    static var maximumDistanceForPriorityPruningCenter: CLLocationDistance = 5_000
    static var currentLocationFetchTimeOut: TimeInterval                   = 30
    static var currentLocationFetchRecency: TimeInterval                   = 10
    static var minIntervalBetweenEnteringSameRegion: TimeInterval          = 120
  }
  
  public enum FetchTrigger: String {
    case manual
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

  public enum StatusKind {
    case updatingMonitoredRegions
    case updatedCurrentLocationRegion
    case enteredRegion
    case visitMonitoring
    case stateChange
    case failure
  }

  public enum Event {
    /// When the monitor detects the user entering a previously registered region
    case entered(CLCircularRegion, CLLocation?)
    
    /// When user is currently in a region, triggered from calling `checkIfInRegion()`
    case manual(CLCircularRegion, CLLocation?)

    /// Internal status message, useful for debugging; should not be shown to user
    case status(String, StatusKind)
  }
  
  private let fetchSource: GeoMonitorDataSource
  let eventHandler: (Event) -> Void
  
  private let locationManager: CLLocationManager
  
  private let enabledKey: String?
  
  private var recentlyReportedRegionIdentifiers: [(String, Date)] = []
  
  private var monitorTask: Task<Void, Error>? = nil

  public var maxRegionsToMonitor = 20

  /// Instantiates new monitor
  /// - Parameters:
  ///   - enabledKey: User defaults key to use store whether background tracking should be enabled
  ///   - fetch: Handler that's called when the monitor decides it's a good time to update the regions to monitor. Should fetch and then return all regions to be monitored (even if they didn't change).
  ///   - onEvent: Handler that's called when a relevant event is happening, including when one of the monitored regions is entered.
  public convenience init(enabledKey: String? = nil, fetch: @escaping (GeoMonitor.FetchTrigger) async -> [CLCircularRegion], onEvent: @escaping (Event) -> Void) {
    self.init(enabledKey: enabledKey, dataSource: SimpleDataSource(handler: fetch), onEvent: onEvent)
  }
  
  /// Instantiates new monitor
  /// - Parameters:
  ///   - enabledKey: User defaults key to use store whether background tracking should be enabled
  ///   - dataSource: Data source that provides regions. Will be maintained strongly.
  ///   - onEvent: Handler that's called when a relevant event is happening, including when one of the monitored regions is entered.
  public init(enabledKey: String? = nil, dataSource: GeoMonitorDataSource, onEvent: @escaping (Event) -> Void) {
    fetchSource = dataSource
    eventHandler = onEvent
    locationManager = .init()
    hasAccess = false
    self.enabledKey = enabledKey
    if let enabledKey = enabledKey {
      enableInBackground = UserDefaults.standard.bool(forKey: enabledKey)
    } else {
      enableInBackground = false
    }
    
    super.init()
    
    locationManager.delegate = self
    locationManager.allowsBackgroundLocationUpdates = true
    
#if !DEBUG
    locationManager.activityType = .automotiveNavigation
#endif
  }
  
  // MARK: - Access
  
  /// Whether user has granted any kind of access to the device's location, when-in-use or always
  @Published public var hasAccess: Bool
  
  private var askHandler: (Bool) -> Void = { _ in }

  /// Whether it's possible to bring up the system prompt to ask for access to the device's location
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
      // Note: We do NOT update `enableInBackground` here, as that's the user's
      // setting, i.e., they might not want to have it enabled even though the
      // app has permissions.
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
    if forBackground {
      if locationManager.authorizationStatus == .notDetermined {
        // Need to *first* ask for when in use, and only for always if that
        // is granted.
        ask(forBackground: false) { success in
          if success {
            self.ask(forBackground: true, handler)
          } else {
            handler(false)
          }
        }
      } else {
        self.askHandler = handler
        locationManager.requestAlwaysAuthorization()
      }
    } else {
      self.askHandler = handler
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
    
    let desiredAccuracy = kCLLocationAccuracyHundredMeters
    if let currentLocation = currentLocation,
        currentLocation.timestamp.timeIntervalSinceNow > Constants.currentLocationFetchRecency * -1,
        currentLocation.horizontalAccuracy <= desiredAccuracy {
      // We have a current location and it's less than 10 seconds old. Just use it
      return currentLocation
    }
    
    let originalAccuracy = locationManager.desiredAccuracy
    locationManager.desiredAccuracy = desiredAccuracy
    locationManager.requestLocation()
    
    fetchTimer = .scheduledTimer(withTimeInterval: Constants.currentLocationFetchTimeOut, repeats: false) { [unowned self] _ in
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
  
  /// Whether background monitoring is currently enabled
  ///
  /// - warning: Setting this will prompt for access to the user's location with always-on tracking.
  @Published public var enableInBackground: Bool = false {
    didSet {
      guard enableInBackground != oldValue else { return }
      if enableInBackground, (locationManager.authorizationStatus == .notDetermined || locationManager.authorizationStatus == .authorizedWhenInUse) {
        ask(forBackground: true)
      } else if enableInBackground {
        updateAccess()
      }
      if let enabledKey = enabledKey {
        UserDefaults.standard.set(enableInBackground, forKey: enabledKey)
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
      // Check if in region, which will also re-monitor the current location
      // and update the regions(!)
      await checkIfInRegion()
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
  
  /// Schedules an update after a short interval, only using the regions that were last used when
  /// this is called in quick succession.
  public func scheduleUpdate(regions: [CLCircularRegion]) async {
    let location = isMonitoring ? (try? await fetchCurrentLocation()) : nil
    monitorDebounced(regions, location: location)
  }
  
  public func update(regions: [CLCircularRegion]) async {
    let location = isMonitoring ? (try? await fetchCurrentLocation()) : nil
    monitorNow(regions, location: location)
  }
  
  /// Trigger a check whether the user is in any of the registered regions and, if so, trigger the primary
  /// event handler (with case `.manual`).
  public func checkIfInRegion() async {
    guard let location = await runUpdateCycle(trigger: .manual) else { return }
    
    let candidates = regionsToMonitor.filter { $0.contains(location.coordinate) }
    guard let closest = candidates.min(by: { lhs, rhs in
      let lefty = location.distance(from: .init(latitude: lhs.center.latitude, longitude: lhs.center.longitude))
      let righty = location.distance(from: .init(latitude: rhs.center.latitude, longitude: rhs.center.longitude))
      return lefty < righty
    }) else { return }
    
    eventHandler(.manual(closest, location))
  }
 
}

// MARK: - Trigger on move

extension GeoMonitor {
  
  @discardableResult
  func runUpdateCycle(trigger: FetchTrigger) async -> CLLocation? {
    // Re-monitor current area, so that it updates the data again
    // and also fetch current location at same time, to prioritise monitoring
    // when we leave it.
    let location = try? await monitorCurrentArea()

    // Ask to fetch data and wait for this to complete
    let regions = await fetchSource.fetchRegions(trigger: trigger)
    monitorDebounced(regions, location: location)
    return location
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
      
    eventHandler(.status("GeoMonitor is monitoring \(MKDistanceFormatter().string(fromDistance: region.radius))...", .updatedCurrentLocationRegion))

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
  
  func monitorDebounced(_ regions: [CLCircularRegion], location: CLLocation?) {
    monitorTask?.cancel()
    monitorTask = Task {
      try await Task.sleep(nanoseconds: 2_500_000_000)
      monitorNow(regions, location: location)
    }
  }
  
  func monitorNow(_ regions: [CLCircularRegion], location: CLLocation?) {
    guard !Task.isCancelled else { return }

    // Remember all the regions, if it currently too far away
    regionsToMonitor = regions
    
    guard isMonitoring else { return }
    
    let currentLocation = location ?? self.currentLocation
    
    // Then effectively monitor the nearest
    let nearby: [CLCircularRegion]
    if let currentLocation = currentLocation {
      nearby = regions.filter { region in
        let distance = currentLocation.distance(from: .init(latitude: region.center.latitude, longitude: region.center.longitude))
        return distance < Constants.maximumDistanceToRegionCenter
      }
    } else {
      nearby = regions
    }
    
    // The ones to monitor, optionally pruned by either priority or the nearest
    let toMonitor: [CLCircularRegion]
    let maxCount = maxRegionsToMonitor - 1 // keep one for current location
    if let currentLocation = currentLocation, nearby.count > maxCount {
      let prefix = nearby
        .sorted { lhs, rhs in
          let leftDistance = currentLocation.distance(from: .init(latitude: lhs.center.latitude, longitude: lhs.center.longitude))
          let rightDistance = currentLocation.distance(from: .init(latitude: rhs.center.latitude, longitude: rhs.center.longitude))
          if let leftPrioritized = lhs as? PrioritizedRegion,
              let rightPrioritized = rhs as? PrioritizedRegion,
              leftPrioritized.priority != rightPrioritized.priority,
              leftDistance < Constants.maximumDistanceForPriorityPruningCenter,
              rightDistance < Constants.maximumDistanceForPriorityPruningCenter {
            return leftPrioritized.priority > rightPrioritized.priority
          } else {
            return leftDistance < rightDistance
          }
        }
        .prefix(maxCount)
      toMonitor = Array(prefix)
    } else {
      toMonitor = nearby
    }
    
    // Stop monitoring regions that are no irrelevant
    let toMonitorIDs = Set(toMonitor.map(\.identifier))
    var removedCount: Int = 0
    for previous in locationManager.monitoredRegions {
      if !toMonitorIDs.contains(previous.identifier) && previous.identifier != "current-location" {
        locationManager.stopMonitoring(for: previous)
        removedCount += 1
      }
    }
    
    // Start monitoring those we need to monitor
    let monitoredAlready = locationManager.monitoredRegions.map(\.identifier)
    let newRegion = toMonitor
      .filter { !monitoredAlready.contains($0.identifier) }
    newRegion
      .forEach(locationManager.startMonitoring(for:))
    
    eventHandler(.status("Updating monitored regions. \(regions.count) candidates, \(nearby.count) nearby; monitoring \(toMonitor.count) regions; removed \(removedCount), kept \(monitoredAlready.count), added \(newRegion.count); now monitoring \(locationManager.monitoredRegions.count).", .updatingMonitoredRegions))
  }
  
}

// MARK: - CLLocationManagerDelegate

extension GeoMonitor: CLLocationManagerDelegate {
  
  public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard isMonitoring else {
      eventHandler(.status("GeoMonitor exited region, even though we've since stopped monitoring. Ignoring...", .enteredRegion))
      return
    }
    
    guard region.identifier != currentLocationRegion?.identifier else {
      return // Ignore re-entering current region; we only care about exiting this
    }

    Task {
      // Make sure this is still a *current* region => update data
      await runUpdateCycle(trigger: .regionMonitoring)
      
      // Now we can check
      guard let match = regionsToMonitor.first(where: { $0.identifier == region.identifier }) else {
        eventHandler(.status("GeoMonitor entered outdated region -> \(region)", .enteredRegion))
        return // Has since disappeared
      }
      
      eventHandler(.status("GeoMonitor entered -> \(region)", .enteredRegion))
      
      do {
        let location = try await fetchCurrentLocation()
        let minInterval = Constants.minIntervalBetweenEnteringSameRegion * -1
        if let lastReport = recentlyReportedRegionIdentifiers.first(where: { $0.0 == region.identifier }), lastReport.1.timeIntervalSinceNow >= minInterval {
          eventHandler(.status("GeoMonitor reported duplicate for \(region.identifier). Entered \(lastReport.1.timeIntervalSinceNow * -1) seconds ago.", .enteredRegion))
          return // Already reported with `minIntervalBetweenEnteringSameRegion`
        }
        
        recentlyReportedRegionIdentifiers.append((region.identifier, Date()))
        recentlyReportedRegionIdentifiers.removeAll { $0.1.timeIntervalSinceNow < minInterval }
        
        eventHandler(.entered(match, location))
      } catch {
        eventHandler(.status("GeoMonitor location fetch failed after entering region -> \(error)", .failure))
        eventHandler(.entered(match, nil))
      }
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isMonitoring else {
      eventHandler(.status("GeoMonitor entered region, even though we've since stopped monitoring. Ignoring...", .enteredRegion))
      return
    }

    guard currentLocationRegion?.identifier == region.identifier else {
      return // Ignore exiting a monitored region; we only care about entering these.
    }

    Task {
      // 3. When leaving the current location, fetch...
      await runUpdateCycle(trigger: .departedCurrentArea)
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard isMonitoring else {
      eventHandler(.status("GeoMonitor detected visit change, even though we've since stopped monitoring. Ignoring...", .enteredRegion))
      return
    }

    if visit.departureDate == .distantFuture {
      eventHandler(.status("GeoMonitor visit arrival -> \(visit)", .visitMonitoring))
    } else {
      let duration = DateComponentsFormatter().string(from: visit.arrivalDate, to: visit.departureDate) ?? "unknown duration"
      eventHandler(.status("GeoMonitor visit departure after \(duration) -> \(visit)", .visitMonitoring))
    }

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
    eventHandler(.status("GeoMonitor paused updates -> \(manager == locationManager)", .stateChange))
  }
  
  public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
    eventHandler(.status("GeoMonitor resumed updates -> \(manager == locationManager)", .stateChange))
  }
  
  public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    eventHandler(.status("GeoMonitor failed -> \(error) -- \(error.localizedDescription)", .failure))
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
