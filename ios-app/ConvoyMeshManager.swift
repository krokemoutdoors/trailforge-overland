import Foundation
import MultipeerConnectivity
import UIKit

enum ConvoyQuickStatus: String, CaseIterable, Identifiable {
    case stopping = "Stopping Ahead"
    case airing = "Airing Down"
    case stuck = "Stuck — Need Winch/Strap"
    case gate = "Gate Locked — Turn Around"

    var id: String { rawValue }

    var pill: String {
        switch self {
        case .stopping: return "🛑 Stopping Ahead"
        case .airing: return "🛞 Airing Down"
        case .stuck: return "🆘 Stuck — Need Winch/Strap"
        case .gate: return "🔒 Gate Locked — Turn Around"
        }
    }
}

final class ConvoyMeshManager: NSObject, ObservableObject {
    static let reportPrefix = "TFREPORTS:"

    @Published var isBroadcasting = false
    @Published var connectedPeers: [String] = []
    @Published var lastAlert = ""
    @Published var inboundCommunityJSON = ""
    @Published var inboundCommunityToken = 0
    @Published var connectedRevision = 0

    private let peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private let serviceType = "tf-convoy"

    override init() {
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        peerID = MCPeerID(displayName: device.isEmpty ? "TrailForge" : device)
        super.init()
    }

    func start() {
        guard session == nil else { return }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
        self.session = session
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        isBroadcasting = true
    }

    func broadcast(_ status: ConvoyQuickStatus) {
        start()
        lastAlert = "You • \(status.pill)"
        guard let session, !session.connectedPeers.isEmpty else { return }
        guard let data = status.pill.data(using: .utf8) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func sendCommunity(_ json: String) {
        start()
        guard let session, !session.connectedPeers.isEmpty else { return }
        guard let data = (Self.reportPrefix + json).data(using: .utf8) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func refreshPeers(justConnected: Bool = false) {
        let names = session?.connectedPeers.map(\.displayName).sorted() ?? []
        DispatchQueue.main.async {
            self.connectedPeers = names
            if justConnected {
                self.connectedRevision += 1
            }
        }
    }
}

extension ConvoyMeshManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        refreshPeers(justConnected: state == .connected)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let text = String(data: data, encoding: .utf8) ?? "Convoy update"
        if text.hasPrefix(Self.reportPrefix) {
            let json = String(text.dropFirst(Self.reportPrefix.count))
            DispatchQueue.main.async {
                self.inboundCommunityJSON = json
                self.inboundCommunityToken += 1
            }
            return
        }
        DispatchQueue.main.async {
            self.lastAlert = "\(peerID.displayName) • \(text)"
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension ConvoyMeshManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension ConvoyMeshManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let session else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        refreshPeers()
    }
}
