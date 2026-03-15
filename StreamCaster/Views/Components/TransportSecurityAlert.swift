import SwiftUI

// MARK: - TransportSecurityAlert

/// TransportSecurityAlert shows security warnings about RTMP connections.
///
/// When a user tries to stream with credentials over plain rtmp://,
/// this alert blocks them and explains why RTMPS is required.
/// When using plain rtmp:// without credentials, it shows a softer
/// warning and lets the user proceed if they want to.
struct TransportSecurityAlert: View {

    /// The validation result that determines which alert to show.
    let validationResult: TransportSecurityValidator.ValidationResult

    /// Called when the user dismisses the alert (taps "Dismiss" or "Cancel").
    let onDismiss: () -> Void

    /// Called when the user taps "Proceed Anyway" on the plaintext warning.
    /// Only used for `.warningPlaintext` — blocked alerts have no proceed option.
    let onProceedAnyway: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            // Pick the right alert content based on the validation result.
            switch validationResult {
            case .blockedPlaintextWithCredentials:
                blockedAlertContent
            case .warningPlaintext:
                warningAlertContent
            case .allowed:
                // This case shouldn't be shown, but handle it gracefully.
                EmptyView()
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
        .padding(32)
    }

    // MARK: - Blocked Alert (rtmp:// + credentials)

    /// Shows a hard-block alert when credentials would be sent in plaintext.
    /// There is NO "proceed anyway" option — this is a security requirement.
    private var blockedAlertContent: some View {
        VStack(spacing: 16) {
            // Red shield icon to signal danger
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)

            // Title
            Text("Security Error")
                .font(.title2)
                .fontWeight(.bold)

            // Explanation of why we're blocking
            Text("Your stream key and credentials would be sent in plaintext over an unencrypted connection. This is not allowed.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // Tell the user how to fix it
            Text("Change your URL to rtmps:// to continue.")
                .font(.callout)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            // Only a dismiss button — no way to proceed
            Button(action: onDismiss) {
                Text("Dismiss")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    // MARK: - Warning Alert (rtmp:// without credentials)

    /// Shows a warning when using plain rtmp:// without credentials.
    /// The user can choose to proceed anyway or cancel.
    private var warningAlertContent: some View {
        VStack(spacing: 16) {
            // Yellow warning icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.yellow)

            // Title
            Text("Security Warning")
                .font(.title2)
                .fontWeight(.bold)

            // Explanation of the risk
            Text("This connection is not encrypted. Your stream data will be sent in plaintext and could be intercepted.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // Two buttons: proceed or cancel
            HStack(spacing: 12) {
                // Cancel button — dismisses the alert
                Button(action: onDismiss) {
                    Text("Cancel")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                // Proceed button — lets the user continue at their own risk
                if let proceedAction = onProceedAnyway {
                    Button(action: proceedAction) {
                        Text("Proceed Anyway")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
    }
}
