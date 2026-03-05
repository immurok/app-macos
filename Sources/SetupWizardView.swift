import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var setupManager = SetupManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var errorMessage: String?

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    switch currentStep {
                    case 0:
                        welcomeStep
                    case 1:
                        pamInstallStep
                    case 2:
                        accessibilityStep
                    default:
                        completeStep
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer with navigation buttons
            footerView
        }
        .frame(width: 480, height: 400)
        .onAppear {
            setupManager.refreshStatus()
            skipCompletedSteps()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text("wizard.title".localized)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("wizard.subtitle".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Progress indicator
            Text("wizard.step".localized(currentStep + 1, totalSteps))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if currentStep > 0 {
                Button("wizard.prev".localized) {
                    withAnimation {
                        currentStep -= 1
                        errorMessage = nil
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < totalSteps {
                Button(nextButtonTitle) {
                    handleNextStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            } else {
                Button("wizard.done".localized) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var nextButtonTitle: String {
        switch currentStep {
        case 1:
            return "wizard.next".localized
        case 2:
            return setupManager.hasAccessibilityPermission ? "wizard.next".localized : "alert.authorize".localized
        default:
            return "wizard.next".localized
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case 1:
            return setupManager.isPAMModuleInstalled
        case 2:
            return true // Can always try to request permission
        default:
            return true
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.wave")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("wizard.welcome".localized)
                .font(.title)
                .fontWeight(.bold)

            Text("wizard.intro".localized)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "lock.open", text: "wizard.feature.unlock".localized)
                featureRow(icon: "terminal", text: "wizard.feature.sudo".localized)
                featureRow(icon: "gearshape", text: "wizard.feature.system".localized)
            }
            .padding(.vertical)

            Text("wizard.intro.next".localized)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var pamInstallStep: some View {
        VStack(spacing: 20) {
            Image(systemName: setupManager.isPAMModuleInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(setupManager.isPAMModuleInstalled ? .green : .orange)

            Text("wizard.pam.title".localized)
                .font(.title2)
                .fontWeight(.bold)

            if setupManager.isPAMModuleInstalled {
                Text("wizard.pam.installed".localized)
                    .foregroundColor(.green)

                Text("wizard.pam.location".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("wizard.pam.needpkg".localized)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)

                Text("wizard.pam.needpkg.hint".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: setupManager.hasAccessibilityPermission ? "checkmark.circle.fill" : "hand.raised")
                .font(.system(size: 48))
                .foregroundColor(setupManager.hasAccessibilityPermission ? .green : .accentColor)

            Text("wizard.accessibility.title".localized)
                .font(.title2)
                .fontWeight(.bold)

            if setupManager.hasAccessibilityPermission {
                Text("wizard.accessibility.granted".localized)
                    .foregroundColor(.green)
            } else {
                Text("wizard.accessibility.description".localized)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("wizard.accessibility.steps".localized)
                        .font(.callout)
                        .fontWeight(.medium)

                    Text("wizard.accessibility.step1".localized)
                    Text("wizard.accessibility.step2".localized)
                    Text("wizard.accessibility.step3".localized)
                }
                .font(.callout)
                .foregroundColor(.secondary)
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
            }
        }
    }

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("wizard.complete.title".localized)
                .font(.title)
                .fontWeight(.bold)

            Text("wizard.complete.message".localized)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    icon: "puzzlepiece.extension",
                    text: "wizard.complete.pam".localized,
                    isComplete: setupManager.isPAMModuleInstalled
                )
                statusRow(
                    icon: "hand.raised",
                    text: "wizard.complete.accessibility".localized,
                    isComplete: setupManager.hasAccessibilityPermission
                )
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Text("wizard.complete.hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helper Views

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(text)
        }
    }

    private func statusRow(icon: String, text: String, isComplete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(text)
            Spacer()
            Image(systemName: isComplete ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isComplete ? .green : .red)
        }
    }

    // MARK: - Actions

    private func handleNextStep() {
        errorMessage = nil

        switch currentStep {
        case 0:
            // Welcome -> PAM Install
            withAnimation {
                currentStep = 1
            }

        case 1:
            // PAM Install step - proceed if installed
            if setupManager.isPAMModuleInstalled {
                withAnimation {
                    currentStep = 2
                }
            }

        case 2:
            // Accessibility step
            if setupManager.hasAccessibilityPermission {
                withAnimation {
                    currentStep = 3
                }
            } else {
                requestAccessibilityPermission()
            }

        default:
            break
        }
    }

    private func requestAccessibilityPermission() {
        setupManager.requestAccessibilityPermission()

        // Open settings and poll for changes
        setupManager.openAccessibilitySettings()

        // Poll for permission change
        pollAccessibilityPermission()
    }

    private func pollAccessibilityPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            setupManager.refreshStatus()

            if setupManager.hasAccessibilityPermission {
                withAnimation {
                    currentStep = 3
                }
            } else {
                // Keep polling if view is still visible
                pollAccessibilityPermission()
            }
        }
    }

    private func skipCompletedSteps() {
        // Skip to first incomplete step
        if setupManager.isPAMModuleInstalled && setupManager.hasAccessibilityPermission {
            currentStep = 3 // All done
        } else if setupManager.isPAMModuleInstalled {
            currentStep = 2 // Skip to accessibility
        } else {
            currentStep = 0 // Start from beginning
        }
    }
}
