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
        
        let documentsURL = sharedContainer.appendingPathComponent("Documents")
        let musicURL = documentsURL.appendingPathComponent("Music")
        
        // Create directories if they don't exist
        do {
            try FileManager.default.createDirectory(at: musicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create directories: \(error)")
            return
        }
        
        let fileName = sourceURL.lastPathComponent
        let destinationURL = musicURL.appendingPathComponent(fileName)
        
        do {
            // Remove existing file if it exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            print("Successfully copied audio file to: \(destinationURL.path)")
        } catch {
            print("Failed to copy audio file: \(error)")
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
