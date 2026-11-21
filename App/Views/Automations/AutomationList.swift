import Automation
import Persistence
import SwiftData
import SwiftUI

struct AutomationList: View {
    @Binding var selection: Automation?
    @Query(sort: \Automation.createdAt) private var automations: [Automation]
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if automations.isEmpty {
                    Text("No automations yet. Use + to schedule a command or prompt, e.g. a morning summary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(automations) { automation in
                    Button { selection = automation } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(statusColor(automation))
                                .frame(width: 7, height: 7)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(automation.name).lineLimit(1)
                                Text(automation.enabled ? Schedule.describe(automation.trigger) : "Off")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.scheduler?.runningAutomation == automation.id {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(automation == selection ? Theme.selection : .clear)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(automation.name)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusColor(_ automation: Automation) -> Color {
        guard automation.enabled else { return .gray.opacity(0.5) }
        switch automation.orderedRuns.first?.status {
        case .failed?: return .orange
        case .needsApproval?: return Theme.accent
        default: return .green
        }
    }
}
