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

    /// How many files actually reached the shared container. The extension
    /// used to open the main app and report success unconditionally, so a
    /// share that matched nothing looked identical to one that worked.
    private var importedFileCount = 0
    private let sharedFilesLock = NSLock()
    private var isProcessingAttachments = false
    private var hasCompletedRequest = false
    private var isPresentingNothingImportedAlert = false

    override func viewDidLoad() {
        super.viewDidLoad()
        processAudioFiles()
    }

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        // The attachment providers may still be copying asynchronously. The
        // group completion below owns completion once processing has begun.
        guard !isProcessingAttachments else { return }
        completeRequest()
    }
    
    private func processAudioFiles() {
        isProcessingAttachments = true
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            print("❌ No extension context or input items")
            isProcessingAttachments = false
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
            self?.isProcessingAttachments = false
            self?.completeRequest()
        }
    }
    
    /// Everything the main app can index. The share extension used to accept
    /// only mp3/flac/wav while its activation rule matched any file, so
    /// sharing an m4a, aac, opus, ogg, dsf or dff ran the whole flow and
    /// silently imported nothing.
    static let supportedAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "m4a", "aac", "opus", "ogg", "oga", "dsf", "dff"
    ]

    /// Concrete identifiers worth asking `loadItem` for, most specific first.
    /// iOS declares no UTI at all for Opus, OGG or DSD, which is exactly why
    /// the extension-name fallback below has to exist.
    private static let knownAudioTypeIdentifiers: [String] = [
        UTType.mp3.identifier,
        "org.xiph.flac",
        "com.microsoft.waveform-audio",
        UTType.wav.identifier,
        UTType.mpeg4Audio.identifier,
        "public.aac-audio",
        UTType.aiff.identifier,
        "org.xiph.ogg",
        "org.xiph.opus",
        "com.sony.dsf",
        "com.sony.dsdiff"
    ]

    static func isSupportedAudioFileName(_ name: String) -> Bool {
        supportedAudioExtensions.contains(
            (name as NSString).pathExtension.lowercased()
        )
    }

    private func isAudioFile(_ attachment: NSItemProvider) -> Bool {
        if attachment.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            return true
        }

        for identifier in Self.knownAudioTypeIdentifiers
        where attachment.hasItemConformingToTypeIdentifier(identifier) {
            return true
        }

        // Opus/OGG/DSD arrive as a dynamic type conforming only to
        // public.data, so the name is the only thing left to go on.
        if let name = attachment.suggestedName, Self.isSupportedAudioFileName(name) {
            return true
        }

        return false
    }

    /// The identifier to hand `loadItem`. Prefer one the provider actually
    /// registered so it is never asked to vend a supertype it does not have.
    private func audioTypeIdentifier(for attachment: NSItemProvider) -> String? {
        let registered = attachment.registeredTypeIdentifiers

        if let exact = registered.first(where: { Self.knownAudioTypeIdentifiers.contains($0) }) {
            return exact
        }
        if let conforming = registered.first(where: { UTType($0)?.conforms(to: .audio) == true }) {
            return conforming
        }
        if registered.contains(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        return registered.first
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
        guard let typeIdentifier = audioTypeIdentifier(for: attachment) else {
            print("❌ Attachment registered no usable type identifier")
            completion()
            return
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
                if Self.isSupportedAudioFileName(folderURL.lastPathComponent) {
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
                    if Self.isSupportedAudioFileName(itemURL.lastPathComponent) {
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
        // Instead of copying, store the URL and bookmark data for the main app to process
        storeSharedURL(sourceURL)
    }

    private func storeSharedURL(_ url: URL) {
        print("💾 Attempting to store shared URL: \(url.lastPathComponent)")

        // Reject network URLs
        if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
            print("❌ Rejected network URL: \(url.absoluteString)")
            return
        }

        guard Self.isSupportedAudioFileName(url.lastPathComponent) else {
            print("❌ Not a format Cosmos can index: \(url.lastPathComponent)")
            return
        }

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

            // NSItemProvider completion handlers may arrive concurrently. Keep
            // the plist read/append/write and the success counter in one
            // critical section so sibling attachments cannot overwrite one
            // another (or race a folder attachment's serial enumeration).
            sharedFilesLock.lock()
            defer { sharedFilesLock.unlock() }

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
            try plistData.write(to: sharedDataURL, options: .atomic)

            print("✅ Successfully stored shared audio file reference: \(url.lastPathComponent)")
            importedFileCount += 1
        } catch {
            print("❌ Failed to store shared audio file reference: \(error)")
        }
    }

    private var storedImportCount: Int {
        sharedFilesLock.lock()
        defer { sharedFilesLock.unlock() }
        return importedFileCount
    }
    
    private func completeRequest() {
        guard !hasCompletedRequest else { return }

        guard storedImportCount > 0 else {
            // Nothing matched. Say so rather than opening the app and letting
            // the user hunt for a track that was never imported.
            guard !isPresentingNothingImportedAlert else { return }
            isPresentingNothingImportedAlert = true
            presentNothingImportedAlert()
            return
        }

        hasCompletedRequest = true

        // Open main app to trigger library refresh
        openMainApp()

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func presentNothingImportedAlert() {
        let formats = ShareViewController.supportedAudioExtensions
            .sorted()
            .map { $0.uppercased() }
            .joined(separator: ", ")

        // `value:` carries the English text inline: the Share target has no
        // Localizable.strings of its own, and an extension resolves keys
        // against its own bundle, not the app's.
        let alert = UIAlertController(
            title: NSLocalizedString(
                "share_nothing_imported_title",
                value: "Nothing Imported",
                comment: "Shown when a share matched no supported audio file"
            ),
            message: String(
                format: NSLocalizedString(
                    "share_nothing_imported_message",
                    value: "Cosmos did not find a supported audio file to import. Supported formats: %@.",
                    comment: "Body of the nothing-imported share alert"
                ),
                formats
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("ok", value: "OK", comment: ""), style: .default) { [weak self] _ in
            guard let self, !self.hasCompletedRequest else { return }
            self.isPresentingNothingImportedAlert = false
            self.hasCompletedRequest = true
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        present(alert, animated: true)
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
