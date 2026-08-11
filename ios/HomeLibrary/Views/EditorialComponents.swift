import SwiftUI

struct LibraryMasthead: View {
    let title: String
    var eyebrow: String?
    var subtitle: String?
    var compact = false

    @ScaledMetric(relativeTo: .largeTitle) private var regularTitleSize = 48.0
    @ScaledMetric(relativeTo: .title) private var compactTitleSize = 31.0

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(LibraryPalette.mutedInk)
            }

            HStack(alignment: .top, spacing: 7) {
                Text(title)
                    .font(.system(
                        size: compact ? compactTitleSize : regularTitleSize,
                        weight: .bold,
                        design: .serif
                    ))
                    .fontWidth(.condensed)
                    .tracking(compact ? -1.2 : -1.8)
                    .lineLimit(compact ? 2 : 3)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)

                Circle()
                    .fill(LibraryPalette.orange)
                    .frame(width: compact ? 8 : 12, height: compact ? 8 : 12)
                    .padding(.top, compact ? 5 : 8)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(LibraryPalette.ink)
                .frame(height: compact ? 1 : 2)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(LibraryPalette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EditorialSectionHeader: View {
    let title: String
    var value: String?
    var accent: Color? = LibraryPalette.orange

    var body: some View {
        HStack(alignment: .center, spacing: LibrarySpacing.small) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.8)

            if let accent {
                Rectangle()
                    .fill(accent)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: LibrarySpacing.small)
            }

            if let value, !value.isEmpty {
                Text(value.uppercased())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.mutedInk)
            }
        }
        .foregroundStyle(LibraryPalette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EditorialPrimaryButton: View {
    let title: String
    var icon = "arrow.right"
    var accent: Color = LibraryPalette.orangeAction
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LibrarySpacing.small) {
                Text(title.uppercased())
                    .font(.subheadline.weight(.bold))
                    .tracking(1.2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: LibrarySpacing.small)
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: icon)
                        .font(.headline)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, LibrarySpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
            .contentShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "Trwa" : "")
    }
}

struct EditorialSecondaryButton: View {
    let title: String
    var icon = "arrow.right"
    var accent: Color = LibraryPalette.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LibrarySpacing.small) {
                Text(title.uppercased())
                    .font(.subheadline.weight(.bold))
                    .tracking(1.2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: LibrarySpacing.small)
                Image(systemName: icon)
                    .font(.headline)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, LibrarySpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(LibraryPalette.paper.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: LibraryRadius.small)
                    .stroke(accent, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct EditorialActionRow: View {
    let title: String
    var detail: String?
    var icon = "arrow.right"
    var accent: Color = LibraryPalette.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: LibrarySpacing.medium) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .multilineTextAlignment(.leading)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(LibraryPalette.mutedInk)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: LibrarySpacing.small)

                Image(systemName: icon)
                    .font(.body.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(LibraryPalette.ink)
            .padding(.vertical, LibrarySpacing.small)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LibraryPalette.rule)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct EditorialMetric: Hashable {
    let value: String
    let label: String

    init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

struct EditorialMetricStrip: View {
    let metrics: [EditorialMetric]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    metricViews
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: LibrarySpacing.small) {
                        metricViews
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: LibrarySpacing.medium),
                            GridItem(.flexible(), spacing: LibrarySpacing.medium)
                        ],
                        alignment: .leading,
                        spacing: 0
                    ) {
                        metricViews
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryPalette.ink).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(LibraryPalette.ink).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var metricViews: some View {
        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.value)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .minimumScaleFactor(0.8)
                Text(metric.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
            }
            .frame(minWidth: 76, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
    }
}

struct EditorialLabeledTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .next

    var body: some View {
        EditorialFieldFrame(label: label) {
            TextField(prompt, text: $text)
                .font(.body)
                .foregroundStyle(LibraryPalette.ink)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .submitLabel(submitLabel)
                .frame(minHeight: 44)
                .accessibilityLabel(label)
        }
    }
}

struct EditorialAxisField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var lineLimit: ClosedRange<Int> = 3...7

    var body: some View {
        EditorialFieldFrame(label: label) {
            TextField(prompt, text: $text, axis: .vertical)
                .font(.body)
                .foregroundStyle(LibraryPalette.ink)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                .accessibilityLabel(label)
        }
    }
}

struct EditorialStatusBand: View {
    let title: String
    var message: String?
    var icon: String?
    var accent: Color = LibraryPalette.orangeText

    var body: some View {
        HStack(alignment: .top, spacing: LibrarySpacing.small) {
            if let icon {
                Image(systemName: icon)
                    .font(.body.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.35)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(.footnote, design: .serif))
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(LibrarySpacing.medium)
        .background(LibraryPalette.ink.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EditorialSelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String?

    var id: Value { value }

    init(value: Value, title: String, symbol: String? = nil) {
        self.value = value
        self.title = title
        self.symbol = symbol
    }
}

struct EditorialPublicationTypeSelector<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [EditorialSelectionOption<Value>]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            EditorialFieldLabel(label)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: LibrarySpacing.small) {
                    optionViews
                }

                VStack(spacing: LibrarySpacing.small) {
                    optionViews
                }
            }
        }
    }

    @ViewBuilder
    private var optionViews: some View {
        ForEach(options) { option in
            let isSelected = selection == option.value
            Button {
                selection = option.value
            } label: {
                HStack(spacing: 8) {
                    if let symbol = option.symbol {
                        Image(systemName: symbol)
                            .accessibilityHidden(true)
                    }
                    Text(option.title.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.05)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(isSelected ? Color.white : LibraryPalette.ink)
                .padding(.horizontal, LibrarySpacing.small)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(isSelected ? LibraryPalette.ink : LibraryPalette.warmPaper.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryRadius.small)
                        .stroke(LibraryPalette.ink.opacity(isSelected ? 1 : 0.34), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
                .contentShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

private struct EditorialFieldFrame<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            EditorialFieldLabel(label)

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(LibraryPalette.warmPaper.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryRadius.small)
                        .stroke(LibraryPalette.rule, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        }
    }
}

private struct EditorialFieldLabel: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.35)
            .foregroundStyle(LibraryPalette.mutedInk)
    }
}
