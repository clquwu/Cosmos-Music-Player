//
//  TutorialViewModel.swift
//  Cosmos Music Player
//
//  View model for the tutorial flow
//

import Foundation
import UIKit
import CloudKit

class TutorialViewModel: ObservableObject {
    @Published var currentStep: Int = 0
    @Published var isSignedIntoAppleID: Bool = false
    @Published var isiCloudDriveEnabled: Bool = false
    @Published var appleIDDetectionFailed: Bool = false
    @Published var iCloudDetectionFailed: Bool = false
    
    init() {
        setupNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupNotificationObservers() {
        // Monitor iCloud Drive availability changes
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("📱 iCloud Drive status changed - rechecking...")
            self?.checkiCloudDriveStatus()
        }
        
        // Monitor CloudKit account changes  
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("📱 CloudKit account status changed - rechecking...")
            self?.checkAppleIDStatus()
        }
    }
    
    var canProceedFromAppleID: Bool {
        return true // Always allow proceeding - let user decide
    }
    
    var canProceedFromiCloud: Bool {
        return true // Always allow proceeding - let user decide
    }
    
    func nextStep() {
        if currentStep < 2 {
            currentStep += 1
        }
    }
    
    func previousStep() {
        if currentStep > 0 {
            currentStep -= 1
        }
    }
    
    func checkAppleIDStatus() {
        // Use Apple's recommended CloudKit approach for detecting iCloud sign-in status
        CKContainer.default().accountStatus { [weak self] accountStatus, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error {
                    print("📱 Apple ID check: ❓ CloudKit error: \(error.localizedDescription)")
                    // Fallback to FileManager approach
                    self.fallbackAppleIDCheck()
                    return
                }
                
                switch accountStatus {
                case .available:
                    self.isSignedIntoAppleID = true
                    self.appleIDDetectionFailed = false
                    print("📱 Apple ID check: ✅ Confirmed signed into iCloud (CloudKit)")
                    
                case .noAccount:
                    self.isSignedIntoAppleID = false
                    self.appleIDDetectionFailed = false
                    print("📱 Apple ID check: ❌ Not signed into iCloud (CloudKit)")
                    
                case .restricted:
                    self.isSignedIntoAppleID = false
                    self.appleIDDetectionFailed = true
                    print("📱 Apple ID check: ⚠️ iCloud access restricted (CloudKit)")
                    
                case .couldNotDetermine:
                    self.isSignedIntoAppleID = false
                    self.appleIDDetectionFailed = true
                    print("📱 Apple ID check: ❓ Could not determine status (CloudKit)")
                    
                @unknown default:
                    self.isSignedIntoAppleID = false
                    self.appleIDDetectionFailed = true
                    print("📱 Apple ID check: ❓ Unknown CloudKit status")
                }
            }
        }
    }
    
    private func fallbackAppleIDCheck() {
        // Fallback to FileManager approach if CloudKit fails
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        let hasContainerAccess = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
        
        if hasIdentityToken || hasContainerAccess {
            isSignedIntoAppleID = true
            appleIDDetectionFailed = false
            print("📱 Apple ID check: ✅ Fallback detection successful")
        } else {
            isSignedIntoAppleID = false
            appleIDDetectionFailed = true
            print("📱 Apple ID check: ❓ Fallback detection failed")
        }
    }
    
    func checkiCloudDriveStatus() {
        // Check specifically for iCloud Drive document storage availability
        // This is the correct use of ubiquityIdentityToken according to Apple docs
        
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        let hasContainerAccess = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
        
        print("📱 iCloud Drive check: Identity token: \(hasIdentityToken), Container access: \(hasContainerAccess)")
        
        if hasIdentityToken {
            // Identity token exists - iCloud Drive document storage is definitely enabled
            isiCloudDriveEnabled = true
            iCloudDetectionFailed = false
            print("📱 iCloud Drive check: ✅ Confirmed enabled (identity token present)")
            
        } else if hasContainerAccess {
            // Has container URL but no identity token
            // This can happen when user is signed into iCloud but iCloud Drive is disabled
            // Let's try to create a test file to verify write access
            checkiCloudDriveWriteAccess()
            
        } else {
            // No container access - either not signed in or iCloud Drive completely disabled
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = false
            print("📱 iCloud Drive check: ❌ Disabled (no container access)")
        }
    }
    
    private func checkiCloudDriveWriteAccess() {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = true
            print("📱 iCloud Drive check: ❓ Container became unavailable")
            return
        }
        
        // Try to check if the container is actually writable
        do {
            let testFolderURL = containerURL.appendingPathComponent("Cosmos Player", isDirectory: true)
            
            // Try to create the app folder (this is what our app would do anyway)
            if !FileManager.default.fileExists(atPath: testFolderURL.path) {
                try FileManager.default.createDirectory(at: testFolderURL, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            // If we can access and create directories, iCloud Drive is working
            isiCloudDriveEnabled = true
            iCloudDetectionFailed = false
            print("📱 iCloud Drive check: ✅ Enabled (verified write access)")
            
        } catch {
            // Cannot write to container - iCloud Drive is likely disabled for this app
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = false
            print("📱 iCloud Drive check: ❌ Disabled (no write access: \(error.localizedDescription))")
        }
    }
    
    @MainActor func openAppleIDSettings() {
        // Try multiple URL schemes for Apple ID settings
        let appleIDUrls = [
            "prefs:root=APPLE_ACCOUNT",
            "prefs:root=APPLE_ACCOUNT&path=SIGN_IN",
            "App-prefs:APPLE_ACCOUNT",
            "App-prefs:root=APPLE_ACCOUNT"
        ]

        for urlString in appleIDUrls {
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        
        // If none work, open main Settings app (user can navigate to Apple ID from there)
        openMainSettings()
    }
    
    @MainActor func openiCloudSettings() {
        // Try multiple URL schemes for iCloud settings
        let iCloudUrls = [
            "prefs:root=CASTLE",
            "prefs:root=CASTLE&path=STORAGE_AND_BACKUP",
            "App-prefs:CASTLE",
            "App-prefs:root=CASTLE"
        ]
        
        for urlString in iCloudUrls {
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        
        // If none work, open main Settings app (user can navigate to iCloud from there)
        openMainSettings()
    }
    
    @MainActor private func openMainSettings() {
        // Open the main Settings app (not app-specific settings)
        if let url = URL(string: "prefs:"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: "App-Prefs:"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            // Last resort: open app-specific settings
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(url)
        }
    }
    
    func completeTutorial() {
        // Save that tutorial has been completed
        UserDefaults.standard.set(true, forKey: "HasCompletedTutorial")
        print("✅ Tutorial completed and saved to UserDefaults")
    }
    
    static func shouldShowTutorial() -> Bool {
        return !UserDefaults.standard.bool(forKey: "HasCompletedTutorial")
    }
}
