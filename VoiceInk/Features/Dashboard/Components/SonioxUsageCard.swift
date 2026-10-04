import SwiftUI

/// One row on the dashboard: what Soniox has charged this month and last month, as
/// Soniox itself records it (so it includes use outside VoiceInk on the same key).
struct SonioxUsageCard: View {
    @ObservedObject var service: SonioxUsageService = .shared

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Soniox usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 12)

            figures

            AppIconButton(
                systemName: "arrow.clockwise",
                help: "Refresh Soniox usage",
                size: 26,
                iconSize: 11,
                cornerRadius: 13
            ) {
                Task { await service.refreshIfStale(force: true) }
            }
            .disabled(service.state == .loading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DashboardInsightCardBackground(cornerRadius: 14))
        .task { await service.refreshIfStale() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var figures: some View {
        if case let .loaded(summary, _) = service.state {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                figure(title: String(localized: "This month"), month: summary.thisMonth, isEmphasized: true)
                figure(title: String(localized: "Last month"), month: summary.lastMonth, isEmphasized: false)
            }
        } else if service.state == .loading {
            ProgressView().controlSize(.small)
        }
    }

    private func figure(title: String, month: SonioxUsage.Month, isEmphasized: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(Self.currency(month.costUSD))
                .font(.system(size: isEmphasized ? 17 : 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isEmphasized ? AppTheme.Text.primary : AppTheme.Text.secondary)
            Text("\(title) · \(Int(month.audioMinutes.rounded())) min")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
        }
    }

    private var caption: String {
        switch service.state {
        case .idle, .loading:
            return String(localized: "Reading from Soniox…")
        case let .loaded(_, fetchedAt):
            return String(
                format: String(localized: "From Soniox's billing records · updated %@"),
                fetchedAt.formatted(date: .omitted, time: .shortened))
        case let .failed(message):
            return message
        }
    }

    private static func currency(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}
