//
//  TutorialView.swift
//  Cosmos Music Player
//
//  Tutorial flow for first-time users
//

import SwiftUI

struct TutorialView: View {
    @StateObject private var viewModel = TutorialViewModel()
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)? = nil
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Progress indicator
                HStack {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index <= viewModel.currentStep ? settings.backgroundColorChoice.color : Color.gray.opacity(0.3))
                            .frame(width: 10, height: 10)
                        
                        if index < 2 {
                            Rectangle()
                                .fill(index < viewModel.currentStep ? settings.backgroundColorChoice.color : Color.gray.opacity(0.3))
                                .frame(height: 2)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                
                // Content
                TabView(selection: $viewModel.currentStep) {
                    AppleIDStepView(viewModel: viewModel)
                        .tag(0)
                    
                    iCloudDriveStepView(viewModel: viewModel)
                        .tag(1)
                    
                    MusicFilesStepView(viewModel: viewModel, onComplete: onComplete)
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: viewModel.currentStep)
            }
            .navigationTitle(Localized.welcomeToCosmos)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
        }
    }
}

struct AppleIDStepView: View {
    @ObservedObject var viewModel: TutorialViewModel
    @State private var settings = DeleteSettings.load()
    
    private var statusIcon: String {
        if viewModel.isSignedIntoAppleID {
            return "checkmark.circle.fill"
        } else if viewModel.appleIDDetectionFailed {
            return "questionmark.circle.fill"
        } else {
            return "exclamationmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        if viewModel.isSignedIntoAppleID {
            return .green
        } else if viewModel.appleIDDetectionFailed {
            return .blue
        } else {
            return .orange
        }
    }
    
    private var statusMessage: String {
        if viewModel.isSignedIntoAppleID {
            return Localized.signedInToAppleId
        } else if viewModel.appleIDDetectionFailed {
            return Localized.cannotDetectAppleIdStatus
        } else {
            return Localized.notSignedInToAppleId
        }
    }
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(settings.backgroundColorChoice.color)
            
            VStack(spacing: 16) {
                Text(Localized.signInToAppleId)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(Localized.signInMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
            
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                    
                    Text(statusMessage)
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 20)
                
                if !viewModel.isSignedIntoAppleID && !viewModel.appleIDDetectionFailed {
                    Button(Localized.openSettings) {
                        viewModel.openAppleIDSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                
                if viewModel.appleIDDetectionFailed {
                    VStack(spacing: 8) {
                        Text(Localized.ifSignedInContinue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            Button(Localized.openSettings) {
                                viewModel.openAppleIDSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button(Localized.imSignedIn) {
                                viewModel.isSignedIntoAppleID = true
                                viewModel.appleIDDetectionFailed = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                
                Button(Localized.continue) {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
        .onAppear {
            viewModel.checkAppleIDStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Re-check status when app becomes active (user returns from Settings)
            viewModel.checkAppleIDStatus()
        }
    }
}

struct iCloudDriveStepView: View {
    @ObservedObject var viewModel: TutorialViewModel
    @State private var settings = DeleteSettings.load()
    
    private var statusIcon: String {
        if viewModel.isiCloudDriveEnabled {
            return "checkmark.circle.fill"
        } else if viewModel.iCloudDetectionFailed {
            return "questionmark.circle.fill"
        } else {
            return "exclamationmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        if viewModel.isiCloudDriveEnabled {
            return .green
        } else if viewModel.iCloudDetectionFailed {
            return .blue
        } else {
            return .orange
        }
    }
    
    private var statusMessage: String {
        if viewModel.isiCloudDriveEnabled {
            return Localized.icloudDriveEnabled
        } else if viewModel.iCloudDetectionFailed {
            return Localized.cannotDetectIcloudStatus
        } else {
            return Localized.icloudDriveNotEnabled
        }
    }
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "icloud.fill")
                .font(.system(size: 80))
                .foregroundColor(settings.backgroundColorChoice.color)
            
            VStack(spacing: 16) {
                Text(Localized.enableIcloudDrive)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(Localized.icloudDriveMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
            
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                    
                    Text(statusMessage)
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 20)
                
                if !viewModel.isiCloudDriveEnabled && !viewModel.iCloudDetectionFailed {
                    Button(Localized.openSettings) {
                        viewModel.openiCloudSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                
                if viewModel.iCloudDetectionFailed {
                    VStack(spacing: 8) {
                        Text(Localized.ifIcloudEnabledContinue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            Button(Localized.openSettings) {
                                viewModel.openiCloudSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button(Localized.itsEnabled) {
                                viewModel.isiCloudDriveEnabled = true
                                viewModel.iCloudDetectionFailed = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            
            Spacer()
            
            HStack {
                Button(Localized.back) {
                    viewModel.previousStep()
                }
                .font(.body)
                .foregroundColor(settings.backgroundColorChoice.color)
                
                Spacer()
                
                Button(Localized.continue) {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canProceedFromiCloud)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
        .onAppear {
            viewModel.checkiCloudDriveStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Re-check status when app becomes active (user returns from Settings)
            viewModel.checkiCloudDriveStatus()
        }
    }
}

struct MusicFilesStepView: View {
    @ObservedObject var viewModel: TutorialViewModel
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)? = nil
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                Spacer(minLength: 20)
                
                Image(systemName: "music.note")
                    .font(.system(size: 70))
                    .foregroundColor(settings.backgroundColorChoice.color)
                
                VStack(spacing: 12) {
                    Text(Localized.addYourMusic)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(Localized.howToAddMusic)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    InstructionRow(
                        step: "1",
                        title: Localized.openFilesApp,
                        description: Localized.findOpenFilesApp
                    )
                    
                    InstructionRow(
                        step: "2",
                        title: Localized.navigateToIcloudDrive,
                        description: Localized.tapIcloudDriveSidebar
                    )
                    
                    InstructionRow(
                        step: "3",
                        title: Localized.findCosmosPlayerFolder,
                        description: Localized.lookForCosmosFolder
                    )
                    
                    InstructionRow(
                        step: "4",
                        title: Localized.addYourMusicInstruction,
                        description: Localized.copyMusicFiles
                    )
                }
                .padding(.horizontal, 20)
                
                Spacer(minLength: 20)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                // Gradient overlay to separate content from buttons
                LinearGradient(
                    colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)
                
                HStack {
                    Button(Localized.back) {
                        viewModel.previousStep()
                    }
                    .font(.body)
                    .foregroundColor(settings.backgroundColorChoice.color)
                    
                    Spacer()
                    
                    Button(Localized.getStarted) {
                        print("🎯 Get Started button tapped")
                        viewModel.completeTutorial()
                        print("🎯 About to dismiss tutorial")
                        onComplete?()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 40)
                .background(Color(.systemBackground))
            }
        }
    }
}

struct InstructionRow: View {
    let step: String
    let title: String
    let description: String
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(settings.backgroundColorChoice.color))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    TutorialView()
}