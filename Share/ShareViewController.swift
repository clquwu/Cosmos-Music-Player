//
//  ShareViewController.swift
//  Share
//
//  Created by CLQ on 10/09/2025.
//

import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        processAudioFiles()
    }

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        completeRequest()
    }
    
    private func processAudioFiles() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            completeRequest()
            return
        }
        
        let group = DispatchGroup()
        
        for inputItem in inputItems {
            guard let attachments = inputItem.attachments else { continue }
            
            for attachment in attachments {
                if isAudioFile(attachment) {
                    group.enter()
                    copyAudioFile(attachment) {
                        group.leave()
                    }
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.completeRequest()
        }
    }
    
    private func isAudioFile(_ attachment: NSItemProvider) -> Bool {
        return attachment.hasItemConformingToTypeIdentifier(UTType.audio.identifier) ||
               attachment.hasItemConformingToTypeIdentifier(UTType.mp3.identifier) ||
               attachment.hasItemConformingToTypeIdentifier("org.xiph.flac") ||
               attachment.hasItemConformingToTypeIdentifier("com.microsoft.waveform-audio")
    }
    
    private func copyAudioFile(_ attachment: NSItemProvider, completion: @escaping () -> Void) {
        let typeIdentifier: String
        
        if attachment.hasItemConformingToTypeIdentifier(UTType.mp3.identifier) {
            typeIdentifier = UTType.mp3.identifier
        } else if attachment.hasItemConformingToTypeIdentifier("org.xiph.flac") {
            typeIdentifier = "org.xiph.flac"
        } else if attachment.hasItemConformingToTypeIdentifier("com.microsoft.waveform-audio") {
            typeIdentifier = "com.microsoft.waveform-audio"
        } else {
            typeIdentifier = UTType.audio.identifier
        }
        
        attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] (item, error) in
            defer { completion() }
            
            guard error == nil, let url = item as? URL else {
                print("Error loading audio file: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            self?.copyFileToSharedContainer(from: url)
        }
    }
    
    private func copyFileToSharedContainer(from sourceURL: URL) {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("Failed to get shared container URL")
            return
        }

        // Instead of copying, store the URL and bookmark data for the main app to process
        storeSharedURL(sourceURL)
    }

    private func storeSharedURL(_ url: URL) {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("Failed to get shared container URL")
            return
        }

        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        do {
            // Create bookmark data for security-scoped access
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

            // Load existing shared files or create new array
            var sharedFiles: [[String: Data]] = []
            if FileManager.default.fileExists(atPath: sharedDataURL.path) {
                if let data = try? Data(contentsOf: sharedDataURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] {
                    sharedFiles = plist
                }
            }

            // Add new file info
            let fileInfo: [String: Data] = [
                "url": url.absoluteString.data(using: .utf8) ?? Data(),
                "bookmark": bookmarkData,
                "filename": url.lastPathComponent.data(using: .utf8) ?? Data()
            ]
            sharedFiles.append(fileInfo)

            // Save updated list
            let plistData = try PropertyListSerialization.data(fromPropertyList: sharedFiles, format: .xml, options: 0)
            try plistData.write(to: sharedDataURL)

            print("Successfully stored shared audio file reference: \(url.lastPathComponent)")
        } catch {
            print("Failed to store shared audio file reference: \(error)")
        }
    }
    
    private func completeRequest() {
        // Open main app to trigger library refresh
        openMainApp()
        
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func openMainApp() {
        guard let url = URL(string: "cosmos-music://refresh") else {
            print("❌ Failed to create URL for main app")
            return
        }
        
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: { success in
                    print(success ? "✅ Successfully opened main app" : "❌ Failed to open main app")
                })
                return
            }
            responder = responder?.next
        }
        
        // Fallback method for iOS 14+
        if let windowScene = view.window?.windowScene {
            windowScene.open(url, options: nil) { success in
                print(success ? "✅ Successfully opened main app via windowScene" : "❌ Failed to open main app via windowScene")
            }
        } else {
            print("❌ Could not find UIApplication or WindowScene to open main app")
        }
    }


}
