import SwiftUI

struct CameraScreen: View {
    let onClose: () -> Void
    let onImage: (UIImage) -> Void

    @State private var showingPicker = false
    @State private var useFrontCamera = false
    @State private var captureNonce: Int = 0

    var body: some View {
        ZStack {
            CameraPreviewView(
                useFrontCamera: useFrontCamera,
                captureNonce: captureNonce,
                isPaused: showingPicker,
                onImage: onImage
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.top, 10)

                Spacer()

                HStack(alignment: .center) {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    ShutterButton {
                        captureNonce &+= 1
                    }

                    Spacer()

                    Button {
                        useFrontCamera.toggle()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
            }
        }
        .sheet(isPresented: $showingPicker) {
            PhotoPicker { image in
                onImage(image)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.95), lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 62, height: 62)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shutter")
    }
}
