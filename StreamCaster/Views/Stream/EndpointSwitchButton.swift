import SwiftUI

// MARK: - EndpointSwitchButton
// A 40pt circular button that opens a dropdown to select the active
// streaming endpoint profile. Displays the selected profile name
// as a small label below the button.

struct EndpointSwitchButton: View {

    @ObservedObject var viewModel: StreamViewModel

    var body: some View {
        VStack(spacing: 2) {
            Menu {
                ForEach(viewModel.endpointProfiles) { profile in
                    Button {
                        viewModel.selectEndpoint(profileId: profile.id)
                    } label: {
                        if profile.id == viewModel.selectedProfileId {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                    )
            }
            // Ensure minimum 44pt tap target per Apple HIG.
            .frame(width: 44, height: 44)

            if let name = viewModel.selectedProfileName {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 64)
            }
        }
    }
}
