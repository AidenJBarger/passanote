import SplineRuntime
import SwiftUI
import Combine
import UIKit

/// Full-screen Spline nickname setup: 3D note animates in via boolean variables.
/// Nickname is pushed to the `name` string variable in the bundled scene.
struct NicknameSetupView: View {
    /// Bundled export from Spline (`passanote/stickynote.splineswift`).
    static let sceneURL = SplineSceneWarmup.sceneURL

    private enum SplineVariable {
        static let screenOpen = "Boolean 2"
        static let name = "name"
    }

    /// 3D text mesh inside `Rectangle` that references the `name` variable.
    private static let nicknameMeshName = "Nickname Input"

    private static let variableToggleDelay: Duration = .milliseconds(40)
    /// Resting nudge when the keyboard is hidden — keep at zero so the note
    /// sits centered until the keyboard lifts it.
    private static let restingVerticalOffsetFraction: CGFloat = 0
    /// How much of the keyboard overlap lifts the scene when typing.
    private static let keyboardLiftFactor: CGFloat = 0.34

    let model: ChatViewModel
    var onComplete: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var splineController = SplineController()
    @State private var openTransitionPlayed = false
    @State private var sceneIsReady = false
    @State private var sceneVisible = false
    @State private var nickname = ""
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nicknameBinding: Binding<String> {
        Binding(
            get: { nickname },
            set: { newValue in
                let sanitized = NicknameInput.sanitized(newValue)
                nickname = sanitized
                model.updateNickname(sanitized)
                syncNicknameToSpline(sanitized)
            }
        )
    }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            splineScene

            nicknameInput
        }
        .contentShape(Rectangle())
        .onTapGesture {
            fieldFocused = true
        }
        .toolbar {
            if model.hasNickname {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        commit()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .tint(Theme.note)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            let setup = NicknameInput.sanitized(model.nicknameForSetup)
            nickname = setup
            if setup != model.nicknameForSetup {
                model.updateNickname(setup)
            }
        }
        .onChange(of: colorScheme) { _, scheme in
            guard sceneIsReady else { return }
            splineController.setBackgroundColor(Theme.paperBackgroundSIMD(for: scheme))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            let overlap = max(0, screenHeight - frame.origin.y)
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = overlap
            }
        }
    }

    private var splineScene: some View {
        GeometryReader { geo in
            Group {
                if let sceneURL = Self.sceneURL {
                    SplineView(sceneFileURL: sceneURL, controller: splineController) { phase in
                        if case .failure = phase {
                            sceneLoadError
                        } else if let content = phase.content {
                            content
                                .task {
                                    guard !openTransitionPlayed else { return }
                                    openTransitionPlayed = true
                                    await configureSceneAndPlayOpen()
                                }
                        } else {
                            Color.clear
                        }
                    }
                } else {
                    sceneLoadError
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: sceneOffset(in: geo))
            .opacity(sceneVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.35), value: sceneVisible)
    }

    /// Lifts the scene when the keyboard is up; otherwise keeps a small resting offset.
    private func sceneOffset(in geo: GeometryProxy) -> CGFloat {
        let resting = geo.size.height * Self.restingVerticalOffsetFraction
        let keyboardOverlap = max(0, keyboardHeight - geo.safeAreaInsets.bottom)
        let keyboardLift = keyboardOverlap * Self.keyboardLiftFactor
        return -(resting + keyboardLift)
    }

    private var sceneLoadError: some View {
        ContentUnavailableView(
            "Scene file missing",
            systemImage: "exclamationmark.triangle",
            description: Text("Add stickynote.splineswift to the passanote target.")
        )
    }

    private var nicknameInput: some View {
        TextField("", text: nicknameBinding)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .submitLabel(.go)
            .onSubmit(submit)
            .opacity(0.02)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Nickname")
    }

    private func configureSceneAndPlayOpen() async {
        sceneIsReady = true
        splineController.setBackgroundColor(Theme.paperBackgroundSIMD(for: colorScheme))

        if !nickname.isEmpty {
            syncNicknameToSpline(nickname)
        }

        // Let Metal finish its first frame before revealing and animating.
        try? await Task.sleep(for: .milliseconds(50))
        sceneVisible = true

        await setBoolVariable(SplineVariable.screenOpen, value: false)
        try? await Task.sleep(for: Self.variableToggleDelay)
        await setBoolVariable(SplineVariable.screenOpen, value: true)
        splineController.play()
        if !nickname.isEmpty {
            syncNicknameToSpline(nickname)
        }

        // Defer keyboard so scene lift and open animation aren't competing.
        try? await Task.sleep(for: .milliseconds(120))
        fieldFocused = true
    }

    private func syncNicknameToSpline(_ value: String) {
        guard sceneIsReady else { return }

        guard let mesh = splineController.findObject(name: Self.nicknameMeshName) else {
            return
        }

        // Spline's Metal text path crashes on zero-length strings (debug assertion).
        if value.isEmpty {
            mesh.visible = false
            splineController.play()
            return
        }

        mesh.visible = true
        splineController.setStringVariable(
            name: SplineVariable.name,
            value: value
        )

        splineController.emitEvent(.start, nameOrUUID: Self.nicknameMeshName)

        let scale = mesh.scale
        mesh.scale = SIMD3(scale.x * 1.0001, scale.y, scale.z)
        mesh.scale = scale
        mesh.emitEvent(.start)

        splineController.play()
    }

    @MainActor
    private func setBoolVariable(_ name: String, value: Bool) {
        splineController.setBoolVariable(name: name, value: value)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        commit()
        dismiss()
    }

    private func commit() {
        model.setNickname(trimmed)
    }

    private func dismiss() {
        fieldFocused = false
        onComplete?()
    }
}
