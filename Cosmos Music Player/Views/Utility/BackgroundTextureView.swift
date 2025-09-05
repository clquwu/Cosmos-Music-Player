import SwiftUI

enum BackgroundDesign: Int, CaseIterable, Codable {
    case topLeftToCenterRight = 0
    case bottomLeftToCenterRight = 1
    case topRightToCenterLeft = 2
    case bottomRightToCenterLeft = 3
    case subtleRadialGradient = 4
    case minimalistMesh = 5
    case softBlur = 6
}

enum ScreenType {
    case library
    case albums
    case albumDetail
    case artists
    case artistDetail
    case playlists
    case playlistDetail
    case allSongs
    case likedSongs
    case player
    case miniPlayer
}

struct ScreenSpecificBackgroundView: View {
    let screen: ScreenType
    
    var body: some View {
        ZStack {
            // Each screen gets a unique fixed design, details match their parent screens
            switch screen {
            case .library:
                BackgroundTextureView(design: .topLeftToCenterRight)
            case .albums:
                BackgroundTextureView(design: .bottomLeftToCenterRight)
            case .albumDetail:
                BackgroundTextureView(design: .bottomLeftToCenterRight) // Same as albums
            case .artists:
                BackgroundTextureView(design: .bottomRightToCenterLeft)
            case .artistDetail:
                BackgroundTextureView(design: .bottomRightToCenterLeft) // Same as artists
            case .playlists:
                BackgroundTextureView(design: .bottomLeftToCenterRight)
            case .playlistDetail:
                BackgroundTextureView(design: .bottomLeftToCenterRight) // Same as playlists
            case .allSongs:
                BackgroundTextureView(design: .topRightToCenterLeft) // Different from library
            case .likedSongs:
                BackgroundTextureView(design: .bottomRightToCenterLeft) // Different from library
            case .player:
                BackgroundTextureView(design: .subtleRadialGradient) // Minimalist player design
            case .miniPlayer:
                BackgroundTextureView(design: .topLeftToCenterRight) // Keep existing design for mini player
            }
        }
    }
}

struct BackgroundTextureView: View {
    let design: BackgroundDesign
    @State private var settings = DeleteSettings.load()
    
    init(design: BackgroundDesign) {
        self.design = design
    }
    
    var body: some View {
        ZStack {
            switch design {
            case .topLeftToCenterRight:
                topLeftToCenterRightDesign
            case .bottomLeftToCenterRight:
                bottomLeftToCenterRightDesign
            case .topRightToCenterLeft:
                topRightToCenterLeftDesign
            case .bottomRightToCenterLeft:
                bottomRightToCenterLeftDesign
            case .subtleRadialGradient:
                subtleRadialGradientDesign
            case .minimalistMesh:
                minimalistMeshDesign
            case .softBlur:
                softBlurDesign
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    // Design 1: Top Left to Center Right - Straight line halo
    private var topLeftToCenterRightDesign: some View {
        GeometryReader { geometry in
            ZStack {
                // Create the diagonal path with perpendicular gradient
                Path { path in
                    let startPoint = CGPoint(x: 0, y: 0) // Top-left corner
                    let endPoint = CGPoint(x: geometry.size.width, y: geometry.size.height * 0.5) // Center of right border
                    let bandWidth: CGFloat = 150
                    
                    // Calculate direction vector
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let length = sqrt(dx * dx + dy * dy)
                    let unitX = dx / length
                    let unitY = dy / length
                    
                    // Calculate perpendicular vector (rotated 90 degrees)
                    let perpX = -unitY * bandWidth / 2
                    let perpY = unitX * bandWidth / 2
                    
                    // Extend line to ensure full screen coverage
                    let extensionLength: CGFloat = max(geometry.size.width, geometry.size.height)
                    let extendedStart = CGPoint(
                        x: startPoint.x - unitX * extensionLength,
                        y: startPoint.y - unitY * extensionLength
                    )
                    let extendedEnd = CGPoint(
                        x: endPoint.x + unitX * extensionLength,
                        y: endPoint.y + unitY * extensionLength
                    )
                    
                    // Create uniform width rectangle along the line
                    path.move(to: CGPoint(x: extendedStart.x + perpX, y: extendedStart.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x + perpX, y: extendedEnd.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x - perpX, y: extendedEnd.y - perpY))
                    path.addLine(to: CGPoint(x: extendedStart.x - perpX, y: extendedStart.y - perpY))
                    path.closeSubpath()
                }
                .fill(settings.backgroundColorChoice.color.opacity(0.6))
                .blur(radius: 60)
                .opacity(0.5)
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 2: Bottom Left to Center Right - Straight line halo
    private var bottomLeftToCenterRightDesign: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let startPoint = CGPoint(x: 0, y: geometry.size.height) // Bottom-left corner
                    let endPoint = CGPoint(x: geometry.size.width, y: geometry.size.height * 0.5) // Center of right border
                    let bandWidth: CGFloat = 150
                    
                    // Calculate direction vector
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let length = sqrt(dx * dx + dy * dy)
                    let unitX = dx / length
                    let unitY = dy / length
                    
                    // Calculate perpendicular vector (rotated 90 degrees)
                    let perpX = -unitY * bandWidth / 2
                    let perpY = unitX * bandWidth / 2
                    
                    // Extend line to ensure full screen coverage
                    let extensionLength: CGFloat = max(geometry.size.width, geometry.size.height)
                    let extendedStart = CGPoint(
                        x: startPoint.x - unitX * extensionLength,
                        y: startPoint.y - unitY * extensionLength
                    )
                    let extendedEnd = CGPoint(
                        x: endPoint.x + unitX * extensionLength,
                        y: endPoint.y + unitY * extensionLength
                    )
                    
                    // Create uniform width rectangle along the line
                    path.move(to: CGPoint(x: extendedStart.x + perpX, y: extendedStart.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x + perpX, y: extendedEnd.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x - perpX, y: extendedEnd.y - perpY))
                    path.addLine(to: CGPoint(x: extendedStart.x - perpX, y: extendedStart.y - perpY))
                    path.closeSubpath()
                }
                .fill(settings.backgroundColorChoice.color.opacity(0.6))
                .blur(radius: 60)
                .opacity(0.5)
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 3: Top Right to Center Left - Straight line halo
    private var topRightToCenterLeftDesign: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let startPoint = CGPoint(x: geometry.size.width, y: 0) // Top-right corner
                    let endPoint = CGPoint(x: 0, y: geometry.size.height * 0.5) // Center of left border
                    let bandWidth: CGFloat = 150
                    
                    // Calculate direction vector
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let length = sqrt(dx * dx + dy * dy)
                    let unitX = dx / length
                    let unitY = dy / length
                    
                    // Calculate perpendicular vector (rotated 90 degrees)
                    let perpX = -unitY * bandWidth / 2
                    let perpY = unitX * bandWidth / 2
                    
                    // Extend line to ensure full screen coverage
                    let extensionLength: CGFloat = max(geometry.size.width, geometry.size.height)
                    let extendedStart = CGPoint(
                        x: startPoint.x - unitX * extensionLength,
                        y: startPoint.y - unitY * extensionLength
                    )
                    let extendedEnd = CGPoint(
                        x: endPoint.x + unitX * extensionLength,
                        y: endPoint.y + unitY * extensionLength
                    )
                    
                    // Create uniform width rectangle along the line
                    path.move(to: CGPoint(x: extendedStart.x + perpX, y: extendedStart.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x + perpX, y: extendedEnd.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x - perpX, y: extendedEnd.y - perpY))
                    path.addLine(to: CGPoint(x: extendedStart.x - perpX, y: extendedStart.y - perpY))
                    path.closeSubpath()
                }
                .fill(settings.backgroundColorChoice.color.opacity(0.6))
                .blur(radius: 60)
                .opacity(0.5)
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 4: Bottom Right to Center Left - Straight line halo
    private var bottomRightToCenterLeftDesign: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let startPoint = CGPoint(x: geometry.size.width, y: geometry.size.height) // Bottom-right corner
                    let endPoint = CGPoint(x: 0, y: geometry.size.height * 0.5) // Center of left border
                    let bandWidth: CGFloat = 150
                    
                    // Calculate direction vector
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let length = sqrt(dx * dx + dy * dy)
                    let unitX = dx / length
                    let unitY = dy / length
                    
                    // Calculate perpendicular vector (rotated 90 degrees)
                    let perpX = -unitY * bandWidth / 2
                    let perpY = unitX * bandWidth / 2
                    
                    // Extend line to ensure full screen coverage
                    let extensionLength: CGFloat = max(geometry.size.width, geometry.size.height)
                    let extendedStart = CGPoint(
                        x: startPoint.x - unitX * extensionLength,
                        y: startPoint.y - unitY * extensionLength
                    )
                    let extendedEnd = CGPoint(
                        x: endPoint.x + unitX * extensionLength,
                        y: endPoint.y + unitY * extensionLength
                    )
                    
                    // Create uniform width rectangle along the line
                    path.move(to: CGPoint(x: extendedStart.x + perpX, y: extendedStart.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x + perpX, y: extendedEnd.y + perpY))
                    path.addLine(to: CGPoint(x: extendedEnd.x - perpX, y: extendedEnd.y - perpY))
                    path.addLine(to: CGPoint(x: extendedStart.x - perpX, y: extendedStart.y - perpY))
                    path.closeSubpath()
                }
                .fill(settings.backgroundColorChoice.color.opacity(0.6))
                .blur(radius: 60)
                .opacity(0.5)
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 5: Refined Geometric Gradient - Clean with subtle structure
    private var subtleRadialGradientDesign: some View {
        GeometryReader { geometry in
            ZStack {
                // Strong diagonal band - creates clear visual structure
                Path { path in
                    let startPoint = CGPoint(x: 0, y: geometry.size.height * 0.7)
                    let endPoint = CGPoint(x: geometry.size.width, y: geometry.size.height * 0.2)
                    let bandWidth: CGFloat = geometry.size.height * 0.6
                    
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let length = sqrt(dx * dx + dy * dy)
                    let unitX = dx / length
                    let unitY = dy / length
                    
                    let perpX = -unitY * bandWidth / 2
                    let perpY = unitX * bandWidth / 2
                    
                    path.move(to: CGPoint(x: startPoint.x + perpX, y: startPoint.y + perpY))
                    path.addLine(to: CGPoint(x: endPoint.x + perpX, y: endPoint.y + perpY))
                    path.addLine(to: CGPoint(x: endPoint.x - perpX, y: endPoint.y - perpY))
                    path.addLine(to: CGPoint(x: startPoint.x - perpX, y: startPoint.y - perpY))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            settings.backgroundColorChoice.color.opacity(0.15),
                            settings.backgroundColorChoice.color.opacity(0.25),
                            settings.backgroundColorChoice.color.opacity(0.15),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blur(radius: 40)
                
                // Complementary radial accent - top right
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: settings.backgroundColorChoice.color.opacity(0.2), location: 0.0),
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 0.5),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.85, y: 0.15),
                    startRadius: 0,
                    endRadius: geometry.size.width * 0.4
                )
                
                // Subtle bottom glow
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: Color.clear, location: 0.8),
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 6: Minimalist Mesh - Soft organic gradient mesh
    private var minimalistMeshDesign: some View {
        GeometryReader { geometry in
            ZStack {
                // Soft mesh-like gradient pattern
                EllipticalGradient(
                    gradient: Gradient(colors: [
                        settings.backgroundColorChoice.color.opacity(0.06),
                        Color.clear
                    ]),
                    center: UnitPoint(x: 0.2, y: 0.2),
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 0.8
                )
                
                EllipticalGradient(
                    gradient: Gradient(colors: [
                        settings.backgroundColorChoice.color.opacity(0.04),
                        Color.clear
                    ]),
                    center: UnitPoint(x: 0.8, y: 0.7),
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 0.6
                )
            }
        }
        .ignoresSafeArea(.all)
    }
    
    // Design 7: Soft Blur - Ultra-minimal with just a soft color wash
    private var softBlurDesign: some View {
        GeometryReader { geometry in
            ZStack {
                // Single soft color wash
                Rectangle()
                    .fill(settings.backgroundColorChoice.color.opacity(0.03))
                    .blur(radius: 100)
                
                // Subtle top highlight
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 0.0),
                        .init(color: Color.clear, location: 0.3)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea(.all)
    }
}
