import MapKit
import SwiftUI
import UIKit

/// Transparent installer that attaches a 0.5s long-press to the underlying map
/// without stealing pans or pinches. The press point is converted with MapProxy.
struct MapTapOverlayView: UIViewRepresentable {
    var proxy: MapProxy
    var onLongPress: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> MapPressInstaller {
        let view = MapPressInstaller()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MapPressInstaller, context: Context) {
        context.coordinator.proxy = proxy
        context.coordinator.onLongPress = onLongPress
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var proxy: MapProxy?
        var onLongPress: (CLLocationCoordinate2D) -> Void

        init(onLongPress: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = proxy?.convert(point, from: .local) ?? mapView.convert(point, toCoordinateFrom: mapView)
            onLongPress(coordinate)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

final class MapPressInstaller: UIView {
    weak var coordinator: MapTapOverlayView.Coordinator?
    private var recognizer: UILongPressGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installIfNeeded()
    }

    func installIfNeeded() {
        guard recognizer == nil, let coordinator, let map = Self.findMap(startingAt: self) else { return }
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(MapTapOverlayView.Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.5
        press.allowableMovement = 10
        press.cancelsTouchesInView = false
        press.delegate = coordinator
        map.addGestureRecognizer(press)
        recognizer = press
    }

    private static func findMap(startingAt view: UIView) -> MKMapView? {
        var current: UIView? = view
        while let node = current {
            if let map = node as? MKMapView { return map }
            if let map = findMap(in: node.subviews) { return map }
            current = node.superview
        }
        return nil
    }

    private static func findMap(in views: [UIView]) -> MKMapView? {
        for view in views {
            if let map = view as? MKMapView { return map }
            if let map = findMap(in: view.subviews) { return map }
        }
        return nil
    }
}

enum ReversePlace {
    static func lookup(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let mark = marks?.first else { return nil }
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [mark.locality, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        let text = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
        if !text.isEmpty { return text }
        return mark.name
    }
}
