# Pass A Note Privacy Policy

Last updated: June 2026

## Summary

- **No personal data collection.** We don't collect names, emails, or phone numbers
- **No accounts or company servers.** Chat works peer-to-peer over Bluetooth
- **No tracking.** No analytics, telemetry, or user tracking
- **Open source.** You can verify these claims by reading our code

## What Pass A Note Stores

### On Your Device Only

**Cryptographic Keys**

A Curve25519 keypair generated on first launch, stored in your device's secure Keychain. Private keys never leave your device; public keys are shared when needed for encrypted messaging.

**Peer ID**

A random identifier generated on first launch, stored locally. Shared with peers so they can recognize you across sessions.

**Nickname**

The display name you choose. Stored only on your device and shared with peers you communicate with.

### Temporary Session Data

During each session, Pass A Note temporarily maintains:

- Active peer connections (forgotten when the app closes)
- Routing information for message delivery across the mesh
- Room and private message history in memory only
- Cached packets for deduplication and relay

## What Is Shared

### With Other Pass A Note Users

When you use Pass A Note, nearby peers can see:

- Your chosen nickname
- Your peer ID
- Messages you send to the public room or directly to them
- Polls, reactions, and replies you post
- Images and files you share
- Your approximate Bluetooth signal strength (for connection quality)

### Public Room vs. Private Messages

The main room is a local broadcast. Messages are visible to everyone nearby and are not encrypted. Private text messages use Noise protocol encryption and are readable only by you and the recipient. Private images, files, and polls are directed to a specific peer but sent in plain text over the mesh.

## What We Don't Do

Pass A Note never:

- Collects personal information
- Stores data on servers we operate
- Sells your data to advertisers or data brokers
- Uses analytics or telemetry
- Creates user profiles
- Requires registration
- Uses your location

## Encryption

Private text messages use end-to-end encryption via the Noise protocol (`Noise_XX_25519_ChaChaPoly_SHA256`):

- Curve25519 for key exchange
- ChaCha20-Poly1305 for message encryption
- SHA-256 for handshake hashing and key derivation

Public room messages, and private images, files, and polls, are sent in plain text over the local Bluetooth mesh. Directed private packets include the destination peer ID in cleartext so the mesh can route them.

## Your Rights

You have complete control:

- **Delete Local State:** Remove the app to wipe your keys, nickname, and preferences
- **Leave Anytime:** Close the app and your local presence stops immediately
- **No Account:** No account record exists for you to delete from us
- **Portability:** Your local state stays on your device unless you send messages to peers

## Bluetooth & Permissions

Pass A Note requires Bluetooth permission to function:

- Used only for peer-to-peer communication
- Bluetooth is not used for tracking
- You can revoke this permission at any time in system settings

Optional notification permission alerts you to new private messages when the app is in the background. Notifications are generated locally on your device. We never receive them.

## Data Retention

- **Messages:** Deleted from memory when the app closes
- **Cryptographic keys and peer ID:** Persist until you delete the app
- **Nickname:** Persists until you change it or delete the app
- **Everything else:** Exists only during active sessions

## Security Measures

- Private text messages are encrypted end-to-end
- No accounts or company servers
- Open source code for public audit
- Replay protection on encrypted transport messages

## Changes to This Policy

If we update this policy:

- The "Last updated" date will change
- The updated policy will be included in the app
- No retroactive changes can make us collect data already held only in your app

## Contact

Pass A Note is an open source project. For privacy questions:

- View our source code: https://github.com/AidenJBarger/passanote
- Open an issue on GitHub
