import Foundation
import CoreLocation

struct GPXWaypoint: Identifiable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var elevationMeters: Double
    var slopeDegrees: Double
    var starlinkSkyPct: Int
    var sym: String
}

final class GPXTrackManager: NSObject, ObservableObject, XMLParserDelegate {
    @Published var waypoints: [GPXWaypoint] = []
    @Published var trackPoints: [CLLocationCoordinate2D] = []

    /// Exports current trail track and dispersed campsite pads to standard GPX 1.1 XML
    func exportGPXString(trailName: String, waypoints: [GPXWaypoint], track: [CLLocationCoordinate2D]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TrailForge Overland iOS" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(trailName)</name>
            <desc>Exported from TrailForge Overland with Rig-Fit &lt;3 deg Flat Boondocking Pads</desc>
          </metadata>
        """
        for wpt in waypoints {
            xml += """
            
              <wpt lat="\(String(format: "%.6f", wpt.latitude))" lon="\(String(format: "%.6f", wpt.longitude))">
                <ele>\(String(format: "%.1f", wpt.elevationMeters))</ele>
                <name>\(wpt.name)</name>
                <desc>Slope: \(wpt.slopeDegrees) deg | Starlink Sky: \(wpt.starlinkSkyPct)%</desc>
                <sym>\(wpt.sym)</sym>
              </wpt>
            """
        }
        xml += "\n  <trk>\n    <name>\(trailName) Track</name>\n    <trkseg>"
        for pt in track {
            xml += "\n      <trkpt lat=\"\(String(format: "%.6f", pt.latitude))\" lon=\"\(String(format: "%.6f", pt.longitude))\"></trkpt>"
        }
        xml += "\n    </trkseg>\n  </trk>\n</gpx>\n"
        return xml
    }
}
