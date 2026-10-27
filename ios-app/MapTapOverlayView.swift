import MapKit
import SwiftUI
import UIKit

/// Transparent installer that attaches a 0.45s long-press to the map container.
/// SwiftUI Map on iOS 17+ often has no MKMapView, so the recognizer lives on the
/// hosting container and the press point is converted with MapProxy.
struct MapTapOverlayView: UIViewRepresentable {
    var proxy: MapProxy
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var pitchEnabled: Bool = false
    var pitch: Double = 0
    var horizonAssist: Double = 0
    var onPitch: (Double, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress, onPitch: onPitch)
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
        context.coordinator.onPitch = onPitch
        context.coordinator.pitchEnabled = pitchEnabled
        context.coordinator.pitch = pitch
        context.coordinator.installer = uiView
        uiView.coordinator = context.coordinator
        uiView.horizonAssist = horizonAssist
        uiView.installIfNeeded()
        uiView.applyHorizonAssist()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var proxy: MapProxy?
        var onLongPress: (CLLocationCoordinate2D) -> Void
        var onPitch: (Double, Bool) -> Void
        var pitchEnabled = false
        var pitch: Double = 0
        weak var installer: MapPressInstaller?
        private var panStartPitch: Double = 0
        private var panStartSpan: CGFloat = -1
        private var panPitching = false
        private var panBlocked = false
        private var panLastPitch: Double = 0

        init(
            onLongPress: @escaping (CLLocationCoordinate2D) -> Void,
            onPitch: @escaping (Double, Bool) -> Void
        ) {
            self.onLongPress = onLongPress
            self.onPitch = onPitch
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

        @objc func pitched(_ gesture: UIPanGestureRecognizer) {
            let ended = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
            if ended {
                if panPitching {
                    onPitch(panLastPitch, false)
                }
                panPitching = false
                panBlocked = false
                panStartSpan = -1
                return
            }
            guard pitchEnabled, gesture.numberOfTouches == 2, let view = gesture.view else { return }
            if panBlocked { return }
            let first = gesture.location(ofTouch: 0, in: view)
            let second = gesture.location(ofTouch: 1, in: view)
            let span = hypot(first.x - second.x, first.y - second.y)
            if gesture.state == .began || panStartSpan < 0 {
                panStartSpan = span
                panStartPitch = pitch
                panLastPitch = pitch
                panPitching = false
            }
            // A widening span is a pinch. Leave zoom and rotate to MapKit
            // until the vertical drag has already locked in as pitch.
            if !panPitching && abs(span - panStartSpan) > 45 {
                panBlocked = true
                return
            }
            let dy = gesture.translation(in: view).y
            if !panPitching, abs(dy) < 8 { return }
            panPitching = true
            let next = min(90, max(0, panStartPitch - Double(dy) * 0.28))
            panLastPitch = next
            onPitch(next, true)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPanGestureRecognizer { return true }
            return gestureRecognizer.numberOfTouches <= 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var node: UIView? = touch.view
            while let view = node {
                if view is UIControl { return false }
                node = view.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIPanGestureRecognizer { return true }
            return gestureRecognizer.numberOfTouches <= 1
        }
    }
}

final class MapPressInstaller: UIView {
    weak var coordinator: MapTapOverlayView.Coordinator?
    var horizonAssist: Double = 0
    private var recognizer: UILongPressGestureRecognizer?
    private var panRecognizer: UIPanGestureRecognizer?
    private weak var assistedCanvas: UIView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installIfNeeded()
        applyHorizonAssist()
    }

    func installIfNeeded() {
        guard let coordinator else { return }
        guard let host = pressHost() else { return }
        installPress(on: host, coordinator: coordinator)
        installPitchPan(on: host, coordinator: coordinator)
    }

    private func installPress(on host: UIView, coordinator: MapTapOverlayView.Coordinator) {
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

    private func installPitchPan(on host: UIView, coordinator: MapTapOverlayView.Coordinator) {
        if let panRecognizer, panRecognizer.view === host { return }
        if let panRecognizer {
            panRecognizer.view?.removeGestureRecognizer(panRecognizer)
            self.panRecognizer = nil
        }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(MapTapOverlayView.Coordinator.pitched(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = coordinator
        host.addGestureRecognizer(pan)
        panRecognizer = pan
    }

    /// Supplemental tilt is a SwiftUI rotation on the Map. Clear any UIKit
    /// plane transform so the two effects are not stacked.
    func applyHorizonAssist() {
        if horizonAssist > 90 { return }
        assistedCanvas?.layer.transform = CATransform3DIdentity
        assistedCanvas = nil
        guard let map = Self.findMap(startingAt: self) else { return }
        let canvas = mapCanvas(in: map) ?? map
        canvas.layer.transform = CATransform3DIdentity
    }

    private func mapCanvas(in map: MKMapView) -> UIView? {
        let candidates = map.subviews.filter { view in
            let name = String(describing: type(of: view))
            if view is UIControl { return false }
            let blocked = ["Compass", "Pitch", "Scale", "Attribution", "UserLocation", "Label"]
            if blocked.contains(where: { name.contains($0) }) { return false }
            return view.bounds.width > 120 && view.bounds.height > 120
        }
        return candidates.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
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
