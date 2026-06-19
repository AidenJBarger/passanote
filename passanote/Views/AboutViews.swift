import SwiftUI

// MARK: - Feature catalog

struct PassANoteFeature: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let details: [String]
}

enum PassANoteFeatureList {
    static let items: [PassANoteFeature] = [
        PassANoteFeature(icon: "lock.fill", text: "Securely message people nearby", details: []),
        PassANoteFeature(icon: "photo.on.rectangle.angled", text: "Share images and files", details: []),
        PassANoteFeature(icon: "clock.arrow.circlepath", text: "Messages disappear when you close the app", details: []),
        PassANoteFeature(
            icon: "dot.radiowaves.left.and.right",
            text: "Completely offline",
            details: ["Uses Bluetooth", "More people, more range"]
        ),
    ]
}

struct PassANoteFeatureRow: View {
    let feature: PassANoteFeature
    var largeStyle = false

    var body: some View {
        VStack(alignment: .leading, spacing: largeStyle ? 8 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(largeStyle ? Theme.metaFont.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: largeStyle ? 20 : 16, alignment: .center)

                Text(feature.text)
                    .font(largeStyle ? Theme.secondaryFont : Theme.metaFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(feature.details, id: \.self) { detail in
                Text(detail)
                    .font(largeStyle ? Theme.metaFont : .caption2)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, largeStyle ? 30 : 26)
            }
        }
    }
}

// MARK: - Features

/// Full feature list from the empty-room guide, laid out like other list screens.
struct FeaturesView: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(PassANoteFeatureList.items) { feature in
                        PassANoteFeatureRow(feature: feature, largeStyle: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .padding(.horizontal, Theme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .paperCanvas()
        .tint(Theme.note)
        .navigationTitle("Features")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy Policy

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerBlock

                policySection("Summary") {
                    bullet("No personal data collection. We don't collect names, emails, or phone numbers")
                    bullet("No accounts or company servers. Chat works peer-to-peer over Bluetooth")
                    bullet("No tracking. No analytics, telemetry, or user tracking")
                    bullet("Open source. You can verify these claims by reading our code")
                }

                policySection("What Pass A Note Stores") {
                    subsection("On Your Device Only") {
                        labeledItem("Cryptographic Keys", detail: "A Curve25519 keypair generated on first launch, stored in your device's secure Keychain. Private keys never leave your device; public keys are shared when needed for encrypted messaging.")
                        labeledItem("Peer ID", detail: "A random identifier generated on first launch, stored locally. Shared with peers so they can recognize you across sessions.")
                        labeledItem("Nickname", detail: "The display name you choose. Stored only on your device and shared with peers you communicate with.")
                    }
                    subsection("Temporary Session Data") {
                        bodyText("During each session, Pass A Note temporarily maintains:")
                        bullet("Active peer connections (forgotten when the app closes)")
                        bullet("Routing information for message delivery across the mesh")
                        bullet("Room and private message history in memory only")
                        bullet("Cached packets for deduplication and relay")
                    }
                }

                policySection("What Is Shared") {
                    subsection("With Other Pass A Note Users") {
                        bodyText("When you use Pass A Note, nearby peers can see:")
                        bullet("Your chosen nickname")
                        bullet("Your peer ID")
                        bullet("Messages you send to the public room or directly to them")
                        bullet("Polls, reactions, and replies you post")
                        bullet("Images and files you share")
                        bullet("Your approximate Bluetooth signal strength (for connection quality)")
                    }
                    subsection("Public Room vs. Private Messages") {
                        bodyText("The main room is a local broadcast. Messages are visible to everyone nearby and are not encrypted. Private text messages use Noise protocol encryption and are readable only by you and the recipient. Private images, files, and polls are directed to a specific peer but sent in plain text over the mesh.")
                    }
                }

                policySection("What We Don't Do") {
                    bodyText("Pass A Note never:")
                    bullet("Collects personal information")
                    bullet("Stores data on servers we operate")
                    bullet("Sells your data to advertisers or data brokers")
                    bullet("Uses analytics or telemetry")
                    bullet("Creates user profiles")
                    bullet("Requires registration")
                    bullet("Uses your location")
                }

                policySection("Encryption") {
                    bodyText("Private text messages use end-to-end encryption via the Noise protocol (Noise_XX_25519_ChaChaPoly_SHA256):")
                    bullet("Curve25519 for key exchange")
                    bullet("ChaCha20-Poly1305 for message encryption")
                    bullet("SHA-256 for handshake hashing and key derivation")
                    bodyText("Public room messages, and private images, files, and polls, are sent in plain text over the local Bluetooth mesh. Directed private packets include the destination peer ID in cleartext so the mesh can route them.")
                }

                policySection("Your Rights") {
                    bodyText("You have complete control:")
                    bullet("Delete Local State: Remove the app to wipe your keys, nickname, and preferences")
                    bullet("Leave Anytime: Close the app and your local presence stops immediately")
                    bullet("No Account: No account record exists for you to delete from us")
                    bullet("Portability: Your local state stays on your device unless you send messages to peers")
                }

                policySection("Bluetooth & Permissions") {
                    bodyText("Pass A Note requires Bluetooth permission to function:")
                    bullet("Used only for peer-to-peer communication")
                    bullet("Bluetooth is not used for tracking")
                    bullet("You can revoke this permission at any time in system settings")
                    bodyText("Optional notification permission alerts you to new private messages when the app is in the background. Notifications are generated locally on your device. We never receive them.")
                }

                policySection("Data Retention") {
                    bullet("Messages: Deleted from memory when the app closes")
                    bullet("Cryptographic keys and peer ID: Persist until you delete the app")
                    bullet("Nickname: Persists until you change it or delete the app")
                    bullet("Everything else: Exists only during active sessions")
                }

                policySection("Security Measures") {
                    bullet("Private text messages are encrypted end-to-end")
                    bullet("No accounts or company servers")
                    bullet("Open source code for public audit")
                    bullet("Replay protection on encrypted transport messages")
                }

                policySection("Changes to This Policy") {
                    bodyText("If we update this policy:")
                    bullet("The \"Last updated\" date will change")
                    bullet("The updated policy will be included in the app")
                    bullet("No retroactive changes can make us collect data already held only in your app")
                }

                policySection("Contact") {
                    bodyText("Pass A Note is an open source project. For privacy questions:")
                    bullet("View our source code: github.com/AidenJBarger/passanote")
                    bullet("Open an issue on GitHub")
                }
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .paperCanvas()
        .tint(Theme.note)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pass A Note Privacy Policy")
                .font(Theme.nameFont)
                .foregroundStyle(Theme.ink)
            Text("Last updated: June 2026")
                .font(Theme.metaFont)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private func policySection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.inkSecondary)
            content()
        }
    }

    private func subsection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.secondaryFont.weight(.semibold))
                .foregroundStyle(Theme.ink)
            content()
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(Theme.secondaryFont)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(Theme.secondaryFont)
                .foregroundStyle(Theme.inkSecondary)
            Text(text)
                .font(Theme.secondaryFont)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledItem(_ label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.secondaryFont.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.secondaryFont)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
