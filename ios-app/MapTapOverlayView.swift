import MapKit
import SwiftUI
import UIKit

/// Transparent installer that attaches a 0.45s long-press to the map container.
/// SwiftUI Map on iOS 17+ often has no MKMapView, so the recognizer lives on the
/// hosting container and the press point is converted with MapProxy.
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
        context.coordinator.installer = view
        return view
    }

    func updateUIView(_ uiView: MapPressInstaller, context: Context) {
        context.coordinator.proxy = proxy
        context.coordinator.onLongPress = onLongPress
        context.coordinator.installer = uiView
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var proxy: MapProxy?
        var onLongPress: (CLLocationCoordinate2D) -> Void
        weak var installer: MapPressInstaller?

        init(onLongPress: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let installer else { return }
            if installer.touchStartsOnControl(gesture) { return }
            let localPoint = gesture.location(in: installer)
            if let coordinate = proxy?.convert(localPoint, from: .local) {
                onLongPress(coordinate)
                return
            }
            let mapView = (gesture.view as? MKMapView) ?? MapPressInstaller.findMap(startingAt: installer)
            if let mapView {
                let point = gesture.location(in: mapView)
                onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.numberOfTouches <= 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view is UIControl)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer.numberOfTouches <= 1
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
        guard let coordinator else { return }
        guard let host = pressHost() else { return }
        if let recognizer, recognizer.view === host { return }
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(MapTapOverlayView.Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 14
        press.numberOfTouchesRequired = 1
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = coordinator
        host.addGestureRecognizer(press)
        recognizer = press
    }

    func touchStartsOnControl(_ gesture: UILongPressGestureRecognizer) -> Bool {
        let local = gesture.location(in: self)
        guard bounds.contains(local) else { return true }
        guard let window else { return false }
        let point = gesture.location(in: window)
        guard let hit = window.hitTest(point, with: nil) else { return false }
        var node: UIView? = hit
        while let view = node {
            if view is UIControl { return true }
            node = view.superview
        }
        return false
    }

    private func pressHost() -> UIView? {
        if let map = Self.findMap(startingAt: self) { return map }
        var node = superview
        var hops = 0
        var host = superview
        while let view = node, hops < 8, !(view is UIWindow) {
            host = view
            let name = String(describing: type(of: view))
            if name.contains("MKMapView") || name.contains("MapView") {
                return view
            }
            // The SwiftUI Map and this overlay share a large multi-child container.
            // Attach there so one-finger long-press reaches the map, and stop
            // before UIWindow so sheet controls are not part of the recognizer.
            if view.bounds.width > 240, view.bounds.height > 240, view.subviews.count > 1 {
                return view
            }
            node = view.superview
            hops += 1
        }
        return host
    }

    static func findMap(startingAt view: UIView) -> MKMapView? {
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
