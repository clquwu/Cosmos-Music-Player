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
            print("❌ No extension context or input items")
            completeRequest()
            return
        }

        print("📋 Processing \(inputItems.count) input items")

        let group = DispatchGroup()

        for (itemIndex, inputItem) in inputItems.enumerated() {
            guard let attachments = inputItem.attachments else {
                print("⚠️ Input item \(itemIndex) has no attachments")
                continue
            }

            print("📎 Input item \(itemIndex) has \(attachments.count) attachments")

            for (attachmentIndex, attachment) in attachments.enumerated() {
                print("🔍 Processing attachment \(itemIndex).\(attachmentIndex)")

                // Log what types this attachment supports
                let supportedTypes = attachment.registeredTypeIdentifiers
                print("📋 Supported types: \(supportedTypes)")

                if isAudioFile(attachment) {
                    print("🎵 Detected audio file at attachment \(itemIndex).\(attachmentIndex)")
                    group.enter()
                    copyAudioFile(attachment) {
                        group.leave()
                    }
                } else if isFolder(attachment) {
                    print("📁 Detected folder at attachment \(itemIndex).\(attachmentIndex)")
                    group.enter()
                    processFolderContents(attachment) {
                        group.leave()
                    }
                } else {
                    print("❓ Unknown attachment type at \(itemIndex).\(attachmentIndex)")
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            print("✅ All attachments processed, completing request")
            self?.completeRequest()
        }
    }
    
    private func isAudioFile(_ attachment: NSItemProvider) -> Bool {
        return attachment.hasItemConformingToTypeIdentifier(UTType.mp3.identifier) ||
               attachment.hasItemConformingToTypeIdentifier("org.xiph.flac") ||
               attachment.hasItemConformingToTypeIdentifier("com.microsoft.waveform-audio") ||
               attachment.hasItemConformingToTypeIdentifier(UTType.wav.identifier)
    }

    private func isFolder(_ attachment: NSItemProvider) -> Bool {
        let folderTypes = [
            UTType.folder.identifier,
            UTType.directory.identifier,
            "public.folder",
            "public.directory",
            UTType.fileURL.identifier // Sometimes folders come as file URLs
        ]

        for type in folderTypes {
            if attachment.hasItemConformingToTypeIdentifier(type) {
                return true
            }
        }

        return false
    }
    
    private func copyAudioFile(_ attachment: NSItemProvider, completion: @escaping () -> Void) {
        let typeIdentifier: String

        if attachment.hasItemConformingToTypeIdentifier(UTType.mp3.identifier) {
            typeIdentifier = UTType.mp3.identifier
        } else if attachment.hasItemConformingToTypeIdentifier("org.xiph.flac") {
            typeIdentifier = "org.xiph.flac"
        } else if attachment.hasItemConformingToTypeIdentifier("com.microsoft.waveform-audio") {
            typeIdentifier = "com.microsoft.waveform-audio"
        } else if attachment.hasItemConformingToTypeIdentifier(UTType.wav.identifier) {
            typeIdentifier = UTType.wav.identifier
        } else {
            // Fallback - shouldn't happen with our filtering
            typeIdentifier = UTType.mp3.identifier
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

    private func processFolderContents(_ attachment: NSItemProvider, completion: @escaping () -> Void) {
        // Try different type identifiers for folders
        let folderTypes = [
            UTType.folder.identifier,
            UTType.directory.identifier,
            "public.folder",
            "public.directory",
            UTType.fileURL.identifier
        ]

        var foundType: String?
        for typeIdentifier in folderTypes {
            if attachment.hasItemConformingToTypeIdentifier(typeIdentifier) {
                foundType = typeIdentifier
                print("🔍 Found folder type: \(typeIdentifier)")
                break
            }
        }

        guard let typeIdentifier = foundType else {
            print("❌ No supported folder type found")
            completion()
            return
        }

        attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] (item, error) in
            defer { completion() }

            guard error == nil else {
                print("❌ Error loading folder: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            guard let folderURL = item as? URL else {
                print("❌ Item is not a URL: \(String(describing: item))")
                return
            }

            print("📁 Successfully loaded folder URL: \(folderURL.absoluteString)")
            print("📁 Folder path: \(folderURL.path)")
            print("📁 Processing folder: \(folderURL.lastPathComponent)")

            // Verify it's actually a directory
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)

            if !exists {
                print("❌ Folder does not exist at path: \(folderURL.path)")
                return
            }

            if !isDirectory.boolValue {
                print("❌ Path is not a directory: \(folderURL.path)")
                // Maybe it's a single file, let's try to process it as such
                let fileExtension = folderURL.pathExtension.lowercased()
                let supportedExtensions = ["mp3", "flac", "wav"]
                if supportedExtensions.contains(fileExtension) {
                    print("🎵 Treating as single audio file: \(folderURL.lastPathComponent)")
                    self?.storeSharedURL(folderURL)
                }
                return
            }

            // Start accessing security-scoped resource
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            self?.processFolder(at: folderURL)
        }
    }

    private func processFolder(at folderURL: URL) {
        let supportedExtensions = ["mp3", "flac", "wav"]
        var audioFilesFound = 0

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])

            print("📂 Found \(contents.count) items in folder: \(folderURL.lastPathComponent)")

            for itemURL in contents {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    // Recursively process subdirectories
                    print("📁 Processing subfolder: \(itemURL.lastPathComponent)")
                    processFolder(at: itemURL)
                } else {
                    // Check if it's a supported audio file
                    let fileExtension = itemURL.pathExtension.lowercased()
                    if supportedExtensions.contains(fileExtension) {
                        print("🎵 Found audio file: \(itemURL.lastPathComponent)")

                        // Start accessing security-scoped resource for the individual file
                        let fileAccessing = itemURL.startAccessingSecurityScopedResource()
                        storeSharedURL(itemURL)
                        if fileAccessing {
                            itemURL.stopAccessingSecurityScopedResource()
                        }

                        audioFilesFound += 1
                    }
                }
            }

            if audioFilesFound > 0 {
                print("✅ Successfully processed \(audioFilesFound) audio files from folder: \(folderURL.lastPathComponent)")
            } else {
                print("⚠️ No audio files found in folder: \(folderURL.lastPathComponent)")
            }
        } catch {
            print("❌ Error reading folder contents for \(folderURL.lastPathComponent): \(error)")
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
        print("💾 Attempting to store shared URL: \(url.lastPathComponent)")

        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("❌ Failed to get shared container URL")
            return
        }

        print("📁 Shared container URL: \(sharedContainer.path)")

        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")
        print("💾 Shared data URL: \(sharedDataURL.path)")

        do {
            // Create bookmark data for security-scoped access
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

            // Load existing shared files or create new array
            var sharedFiles: [[String: Data]] = []
            if FileManager.default.fileExists(atPath: sharedDataURL.path) {
                print("📄 Existing plist found, loading...")
                if let data = try? Data(contentsOf: sharedDataURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] {
                    sharedFiles = plist
                    print("📄 Loaded \(sharedFiles.count) existing entries")
                }
            } else {
                print("📄 No existing plist, creating new one")
            }

            // Add new file info with folder path for playlist creation
            let parentFolder = url.deletingLastPathComponent()
            let fileInfo: [String: Data] = [
                "url": url.absoluteString.data(using: .utf8) ?? Data(),
                "bookmark": bookmarkData,
                "filename": url.lastPathComponent.data(using: .utf8) ?? Data(),
                "folderPath": parentFolder.path.data(using: .utf8) ?? Data(),
                "folderName": parentFolder.lastPathComponent.data(using: .utf8) ?? Data()
            ]
            sharedFiles.append(fileInfo)
            print("➕ Added new file entry, total entries: \(sharedFiles.count)")

            // Save updated list
            let plistData = try PropertyListSerialization.data(fromPropertyList: sharedFiles, format: .xml, options: 0)
            try plistData.write(to: sharedDataURL)

            print("✅ Successfully stored shared audio file reference: \(url.lastPathComponent)")
        } catch {
            print("❌ Failed to store shared audio file reference: \(error)")
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
