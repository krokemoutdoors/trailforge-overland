import Foundation
import StoreKit
import SwiftUI

@MainActor
final class TrailForgeStoreKitManager: ObservableObject {
    static let annualProductID = "com.edwardshin.trailforge.pro.annual"
    static let foundersProductID = "com.edwardshin.trailforge.founders.lifetime"
    static let weekendProductID = "com.edwardshin.trailforge.pro.monthly"

    static let productIds: Set<String> = [
        annualProductID,
        foundersProductID,
        weekendProductID
    ]

    func product(id: String) -> Product? {
        products.first { $0.id == id }
    }

    func displayPrice(for productID: String) -> String {
        if let product = product(id: productID) {
            switch productID {
            case Self.annualProductID:
                return "\(product.displayPrice)/year"
            case Self.weekendProductID:
                return "\(product.displayPrice)/month"
            default:
                return product.displayPrice
            }
        }
        return Self.fallbackPrice(for: productID)
    }

    static func fallbackPrice(for productID: String) -> String {
        switch productID {
        case foundersProductID:
            return "$149.99"
        case annualProductID:
            return "$24.99/year"
        case weekendProductID:
            return "$4.99/month"
        default:
            return ""
        }
    }

    @Published var products: [Product] = []
    @Published var isProUnlocked: Bool = false

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIds)
            await updateEntitlements()
        } catch {
            print("StoreKit load error: \(error)")
        }
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        if case .success(let verification) = result,
           case .verified(let transaction) = verification {
            await transaction.finish()
            await updateEntitlements()
        }
    }

    func updateEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, Self.productIds.contains(tx.productID) {
                unlocked = true
            }
        }
        isProUnlocked = unlocked
    }
}

typealias SubscriptionManager = TrailForgeStoreKitManager

struct TrailForgePaywallView: View {
    @EnvironmentObject private var store: TrailForgeStoreKitManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = TrailForgeStoreKitManager.annualProductID
    @State private var buying = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pro Annual stays the default. The Founders Lifetime Pass is the one-time anchor.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    planCard(
                        id: TrailForgeStoreKitManager.annualProductID,
                        title: "Pro Annual",
                        badge: "MOST POPULAR • SAVE 83%",
                        subtitle: "7-day free trial",
                        highlighted: true
                    )
                    planCard(
                        id: TrailForgeStoreKitManager.weekendProductID,
                        title: "Weekend Pass",
                        badge: nil,
                        subtitle: "Billed monthly",
                        highlighted: false
                    )
                    planCard(
                        id: TrailForgeStoreKitManager.foundersProductID,
                        title: "Founders Lifetime Pass",
                        badge: nil,
                        subtitle: "One-Time • 6-Yr Value Anchor",
                        highlighted: false
                    )
                    Button(buttonTitle) { buy() }
                        .font(.headline)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(buying || store.product(id: selectedID) == nil)
                    if store.product(id: selectedID) == nil {
                        Text("The button stays off until StoreKit loads \(TrailForgeStoreKitManager.fallbackPrice(for: selectedID)), so the label matches the charge.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if store.isProUnlocked {
                        Text("Pro is active on this Apple ID.")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.06, green: 0.08, blue: 0.1))
            .navigationTitle("TrailForge Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close") { dismiss() }
            }
        }
        .task { await store.loadProducts() }
    }

    private var buttonTitle: String {
        if buying { return "Working…" }
        guard store.product(id: selectedID) != nil else { return "Waiting for App Store" }
        return "Continue • \(store.displayPrice(for: selectedID))"
    }

    private func planCard(id: String, title: String, badge: String?, subtitle: String, highlighted: Bool) -> some View {
        let selected = selectedID == id
        return Button {
            selectedID = id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(store.displayPrice(for: id))
                        .font(.headline.monospacedDigit())
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(selected ? 0.12 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(highlighted || selected ? Color.cyan : Color.white.opacity(0.12), lineWidth: highlighted ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
    }

    private func buy() {
        guard let product = store.product(id: selectedID) else { return }
        buying = true
        Task {
            do {
                try await store.purchase(product)
                message = store.isProUnlocked ? "Pro is unlocked on this Apple ID." : "The App Store did not finish that purchase."
            } catch {
                message = "Purchase did not finish."
            }
            buying = false
        }
    }
}
