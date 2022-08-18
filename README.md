# GeoMonitor

A battery-efficient and privacy-friendly mini framework for monitoring the user's
location, triggering callbacks when the user starts moving and monitoring
whether the user approaches specified regions.

Relies on a mixture of techniques, such as:
- Region-monitoring for detecting when the user leaves their current location
- Region-monitoring for detecting when the user approaches pre-defined locations
- Visit-monitoring for detecting when the user has arrived somewhere

## Setup

1. Configure your *Target*:
  - Go to *Signing & Capabilities*, *Background Modes* and make sure *Location updates* is ticket.
  - Go to *Info*, and make sure you have usage descriptions for "Privacy - Location Always", "Privacy - Location Always and When in Use", and "Privacy - Location When In Use" set.


## Usage

TODO:

- [ ] Optional: Set maximum number of regions for GeoMonitor to use. If this
      is not specified, it'll use the maximum of 20. Set this if you're 
      monitoring regions yourself.

```swift
self.monitor = GeoMonitor {
  // Fetch the latest regions; also called when entering one.
  // Make sure `region.identifier` is stable.
  let regions = await ...
  return circles = regions.map { CLCircularRegion(...) }
} onEvent: { event, currentLocation in
  switch event {
  case .departed(visit):
    // Called when a previously-visited location was left
  case .entered(region):
    // Called when entering a defined region.
    let notification = MyNotification(for: region)
    notification.fire()
  case .arrived(visit):
    // Called when a visit was registered
  }
}
monitor.maxRegionsToMonitor = 18
monitor.enableVisitMonitoring = true
monitor.start()
```

## Considerations

TODO:

Regular iOS restrictions apply, such as:

> [...] When Background App Refresh is disabled, either for your app or for all apps, the user must explicitly launch your app to resume the delivery of all location-related events.


