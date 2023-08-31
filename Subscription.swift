//
//  StoreKit.swift
//  CallRecorder
//
//  Created by Everything Apple on 30/05/2023.
//

import Foundation
import StoreKit
import SwiftyStoreKit

enum RegisteredPurchase: String {
    case Weekly
}

class SubscriptionManager {
    
    let weeklyProductID = ""
    let monthlyProductID = ""
    
    let purchaseID = ""
    let sharedSecretKey = ""
    static let shared = SubscriptionManager()
    
    
    func getSubscriptionPackageDetail(productId: String) -> String {
        if productId == weeklyProductID {
            return "WEEKLY SUBSCRIPTION"
        } else if productId == monthlyProductID {
            return "MONTHLY SUBSCRIPTION"
        } else {
            return ""
        }
    }
 
}

// MARK: - Restore Purchases

extension SubscriptionManager {
    /**Restore Purchases if user has already subscribed*/
    func restorePurchases(completion: @escaping(Bool,String) -> Void) {
        SwiftyStoreKit.restorePurchases(atomically: true) { results in
            print(results)
            if results.restoreFailedPurchases.count > 0 {
                print("Restore Failed: \(results.restoreFailedPurchases)")
                completion(false, "Restore Failed")
            }
            else if results.restoredPurchases.count > 0 {
                print("Restore Success: \(results.restoredPurchases)")
                if let lastPurchaseResult = results.restoredPurchases.first {
                    print("Last Purchase Product ID:",lastPurchaseResult.productId)
                    
                    self.verifySubscriptions(purchasedProductId: lastPurchaseResult.productId) { success in
                        completion(true, "Restore Success with information")
                    }
                }
                
            }
            else {
                print("Nothing to Restore")
            }
        }
    }
    
}

// MARK: - Purchase Subscription
extension SubscriptionManager {
    /**For purchasing subcription*/
    func purchase(_ purchase: RegisteredPurchase,_ productID: String, atomically: Bool, completion: @escaping (Bool) -> Void) {
        SwiftyStoreKit.purchaseProduct(productID, atomically: atomically) { result in
            switch result {
            case .success(let purchase):
                let downloads = purchase.transaction.downloads
                if !downloads.isEmpty {
                    SwiftyStoreKit.start(downloads)
                }
                UserDefaults.standard.setLastPremiumPlan(value: productID)
                isSubscribed = true
                print("Subscription Product ID:", purchase.productId)
                UserDefaults.standard.setSubscriptionProductID(value: purchase.productId)
                UserDefaults.standard.setSubscribedKey(value: true)
                
                
                FirebaseManager.shared.updateIsSubscribedValue(isSubscribed: true) { success, message in
                    print(message)
                }
                
                if purchase.needsFinishTransaction {
                    SwiftyStoreKit.finishTransaction(purchase.transaction)
                }
                
#if DEBUG
                let service = AppleReceiptValidator.VerifyReceiptURLType.sandbox
#else
                let service = AppleReceiptValidator.VerifyReceiptURLType.production
#endif
                
                let appleValidator = AppleReceiptValidator(service: service, sharedSecret: self.sharedSecretKey)
                SwiftyStoreKit.verifyReceipt(using: appleValidator) { result in
                    
                    if case .success(let receipt) = result {
                        let purchaseResult = SwiftyStoreKit.verifySubscription(
                            ofType: .autoRenewable,
                            productId: purchase.productId,
                            inReceipt: receipt)
                        
                        switch purchaseResult {
                        case .purchased(let expiryDate, let receiptItems):
                            print("Product is valid until \(expiryDate)")
                            print("Is Trial Period:",receiptItems.first?.isTrialPeriod)
                            print("Receipt Items",receiptItems)
                          
                            if let item = receiptItems.first {
                                self.handleIsSubscribed(item: item, onMessage: { msg in
                                })
                            } else {
                                print("Receipt Not Found")
                            }

                        
                        case .expired(let expiryDate, let receiptItems):
                            print("Product is expired since \(expiryDate)")
                            print("Receipt Items",receiptItems)
                          
                            for item in receiptItems {
                                print("eeeeeeee",item.subscriptionExpirationDate)
                            }
                            if let item = receiptItems.first {
                                self.handleSubscriptionExpired(item: item, onMessage: { msg in
                                })
                            } else {
                                print("Receipt Not Found")
                            }

                        case .notPurchased:
                            print("This product has never been purchased")
                        }
                        completion(true) // Call completion with true for successful purchase
                        
                    } else {
                        // receipt verification error
                    }
                }
            case .error(let error):
                // Handle purchase error if needed
                switch error.code {
                case .unknown: print("Unknown error. Please contact support")
                case .clientInvalid: print("Not allowed to make the payment")
                case .paymentCancelled: break
                case .paymentInvalid: print("The purchase identifier was invalid")
                case .paymentNotAllowed: print("The device is not allowed to make the payment")
                case .storeProductNotAvailable: print("The product is not available in the current storefront")
                case .cloudServicePermissionDenied: print("Access to cloud service information is not allowed")
                case .cloudServiceNetworkConnectionFailed: print("Could not connect to the network")
                case .cloudServiceRevoked: print("User has revoked permission to use this cloud service")
                default: print((error as NSError).localizedDescription)
                    print("Purchase error: \(error)")
                    completion(false) // Call completion with false for failed purchase
                }
            }
        }
    }
}

// MARK: - Retrieve Subscriptions
extension SubscriptionManager {
    /**Retrieving Subscriptions**/
    func retrieveSubscriptions(completion: @escaping (String, String) -> Void) {
        let productIds = Set([self.weeklyProductID, self.monthlyProductID])
        
        var weeklyPrice  = ""
        var monthlyPrice = ""
        
        SwiftyStoreKit.retrieveProductsInfo(productIds) { result in
            if let product = result.retrievedProducts.first(where: { $0.productIdentifier == self.weeklyProductID }) {
                weeklyPrice = product.localizedPrice ?? "4.99"
            }
            
            if let product = result.retrievedProducts.first(where: { $0.productIdentifier == self.monthlyProductID }) {
                monthlyPrice = product.localizedPrice ?? "9.99"
                completion(weeklyPrice, monthlyPrice)
            }
            
            else if let error = result.error {
                print(error.localizedDescription)
                // Handle the error condition
                completion("Error", "Error")
            }
        }
    }
}

// MARK: - Verify Subscriptions
extension SubscriptionManager {
    /**Verify subscription that user's subscription has expired or not*/
    func verifySubscriptions(purchasedProductId: String,completion:@escaping (Bool) -> () ) {
        
        verifyReceipt { result in
            
            switch result {
            case .success(let receipt):
                let productIds = Set([purchasedProductId])
                let purchaseResult = SwiftyStoreKit.verifySubscriptions(productIds: productIds, inReceipt: receipt)
                print(purchaseResult)
                switch purchaseResult {
                case .purchased(let expiryDate, let receiptItems):
                    print("Product is valid until \(expiryDate)")
                    print("Receipt Items",receiptItems)

                 // receiptItems.first means last purchased subscription reciept
                    if let item = receiptItems.first {
                        self.handleIsSubscribed(item: item, onMessage: { msg in
                        })
                    } else {
                        print("Receipt Not Found")
                    }

                case .expired(let expiryDate, let receiptItems):
                    print("Product is expired since \(expiryDate)")
                    print("Receipt Items",receiptItems)
                 
                    if let item = receiptItems.first {
                        self.handleSubscriptionExpired(item: item, onMessage: { msg in
                        })
                    } else {
                        print("Receipt Not Found")
                    }
                    

                    
                case .notPurchased:
                    print("This product has never been purchased")
                }
                completion(true)
            case .error:
                completion(false)
            }
        }
    }

    /**Returns the latest reciept**/
    func verifyReceipt(completion: @escaping (VerifyReceiptResult) -> Void) {
        let appleValidator = AppleReceiptValidator(service: .sandbox, sharedSecret: sharedSecretKey)
        SwiftyStoreKit.verifyReceipt(using: appleValidator) { receipt in
            print(receipt)
            completion(receipt)
        }
    }

}

// MARK: - Local functions to save reciept information
extension SubscriptionManager {

    /**If subscription has expired**/
    func handleSubscriptionExpired(item: ReceiptItem, onMessage: (String)-> Void){
        isSubscribed = false
        print(item.subscriptionExpirationDate)
        print(UserDefaults.standard.getSubscriptionExpirationDate())
        UserDefaults.standard.setSubscribedKey(value: false)
        UserDefaults.standard.setSubscriptionProductID(value: item.productId)
        UserDefaults.standard.setSubscriptionLastPurchasedDate(value: item.purchaseDate)
        UserDefaults.standard.setSubscriptionFirstPurchasedDate(value: item.originalPurchaseDate)
        UserDefaults.standard.setSubscriptionExpirationDate(value: item.subscriptionExpirationDate!)

        let message = "We wanted to let you know that your subscription to Weekly Version has expired on \((item.subscriptionExpirationDate ?? Date()).formatted()). If you enjoyed the service and would like to continue, you can renew your subscription at any time. If you choose not to renew, your access to the service will be limited. We hope you enjoyed your time with us and appreciate your support. If you have any questions or concerns, please don't hesitate to contact our support team. Thank you for being a valued subscriber."
        
        UserDefaults.standard.setSubscribedStatusMessage(value: message)
        FirebaseManager.shared.updateIsSubscribedValue(isSubscribed: false) { succes, message in
            print("\(message)")
        }
        onMessage(message)
    }
    
    
    /**If subscription has already purchased**/
    func handleIsSubscribed(item: ReceiptItem, onMessage: (String)-> Void){
        print("ITEMMM",item)
        print("Subscription Expiration Timeee",item.subscriptionExpirationDate)
        isSubscribed = true
        UserDefaults.standard.setSubscribedKey(value: true)
        UserDefaults.standard.setLastPremiumPlan(value: item.productId)
        UserDefaults.standard.setSubscriptionProductID(value: item.productId)
        UserDefaults.standard.setSubscriptionLastPurchasedDate(value: item.purchaseDate)
        UserDefaults.standard.setSubscriptionFirstPurchasedDate(value: item.originalPurchaseDate)
        UserDefaults.standard.setSubscriptionExpirationDate(value: item.subscriptionExpirationDate!)
        
        let message = "Thank you for subscribing to Weekly Package. Your subscription started on \(item.purchaseDate) and is currently active. Your next billing date is \((item.subscriptionExpirationDate ?? Date()).formatted()), at which point your subscription will automatically renew. If you have any questions or concerns about your subscription, please don't hesitate to contact our support team. Thank you for being a valued subscriber!"
        
        UserDefaults.standard.setSubscribedStatusMessage(value: message)
        onMessage(message)
    }
}
