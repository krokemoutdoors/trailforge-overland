import Foundation
import MultipeerConnectivity

final class ConvoyMeshManager: NSObject, ObservableObject {
    @Published var isBroadcasting: Bool = true
    @Published var connectedPeers: [String] = [
        "SIERRA-2 (Tacoma TRD Pro • 0.4 mi)",
        "NOMAD-3 (Bronco Badlands • 1.1 mi)"
    ]
}
