import Foundation
import StoreKit

@MainActor
final class TrailForgeStoreKitManager: ObservableObject {
    static let productIds: Set<String> = [
        "com.edwardshin.trailforge.pro.annual",
        "com.edwardshin.trailforge.founders.lifetime",
        "com.edwardshin.trailforge.pro.monthly"
    ]

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
