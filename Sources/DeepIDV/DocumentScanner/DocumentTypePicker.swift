// DeepIDV › DocumentScanner (UI)

import DeepIDVCore
import SwiftUI

/// The document-type selection step.
///
/// Presents the three pickable types — Passport / ID card / Driver's license
/// (`allCases` minus `.auto`) — as a card grid: the front-only-vs-front-and-back
/// capture rule must be known *before* capture, so `.auto` (which has no
/// deterministic side count) is offered only on the headless `scanDocument`
/// method, never here. The user taps a card to select it, then confirms with
/// Continue. Used as the first step of the drop-in flow and available composably;
/// themed via `@Environment(\.theme)` like every SDK view.
public struct DocumentTypePicker: View {
    @Environment(\.theme) private var theme
    @State private var selected: DocumentType?
    private let availableTypes: [DocumentType]
    private let heading: String
    private let onCancel: (() -> Void)?
    private let onSelect: (DocumentType) -> Void

    /// The capturable document types, in display order — `allCases` minus `.auto`.
    /// `nonisolated` (the enclosing `View` is `@MainActor`) so it reads as the pure
    /// data it is — usable from anywhere, including tests.
    nonisolated static let pickableTypes: [DocumentType] =
        DocumentType.allCases.filter { $0 != .auto }

    public init(onSelect: @escaping (DocumentType) -> Void) {
        self.availableTypes = Self.pickableTypes
        self.heading = "Select your verification method"
        self.onCancel = nil
        self.onSelect = onSelect
    }

    /// Internal workflow configuration that filters choices using server
    /// requirements while preserving the public composable picker's defaults.
    init(
        availableTypes: [DocumentType],
        heading: String,
        onCancel: (() -> Void)? = nil,
        onSelect: @escaping (DocumentType) -> Void
    ) {
        self.availableTypes = availableTypes
        self.heading = heading
        self.onCancel = onCancel
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            HStack {
                Text(heading)
                    .font(theme.typography.heading(size: 22))
                    .foregroundStyle(theme.colors.grey.s900)
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .font(theme.typography.button(size: 16))
                        .foregroundStyle(theme.colors.grey.s600)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: theme.spacing.md),
                    GridItem(.flexible(), spacing: theme.spacing.md),
                ],
                spacing: theme.spacing.md
            ) {
                ForEach(availableTypes, id: \.self) { type in
                    card(for: type)
                }
            }

            Spacer()

            Button {
                if let selected { onSelect(selected) }
            } label: {
                Text("Continue")
                    .font(theme.typography.button(size: 16))
                    .foregroundStyle(theme.colors.grey.s50)
                    .frame(maxWidth: .infinity)
                    .padding(theme.spacing.md)
                    .background(selected == nil ? theme.colors.grey.s300 : theme.colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: theme.spacing.sm, style: .continuous))
            }
            .disabled(selected == nil)
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.colors.grey.s50)
    }

    /// One selectable document card: an icon tile over its label, with a selected
    /// (primary border + tint) vs. unselected (neutral) treatment.
    private func card(for type: DocumentType) -> some View {
        let isSelected = selected == type
        return Button {
            selected = type
        } label: {
            VStack(spacing: theme.spacing.md) {
                Image(systemName: Self.symbolName(for: type))
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(theme.colors.primary)
                    .frame(width: 64, height: 64)
                    .background(theme.colors.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: theme.spacing.sm, style: .continuous))

                Text(Self.title(for: type))
                    .font(theme.typography.body(size: 14))
                    .foregroundStyle(theme.colors.grey.s600)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacing.lg)
            .padding(.horizontal, theme.spacing.sm)
            .background(isSelected ? theme.colors.primary.opacity(0.05) : theme.colors.grey.s100)
            .overlay(
                RoundedRectangle(cornerRadius: theme.spacing.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.colors.primary : theme.colors.grey.s300,
                        lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.spacing.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The user-facing label for each type.
    nonisolated static func title(for type: DocumentType) -> String {
        switch type {
        case .passport: return "Passport"
        case .idCard: return "ID card"
        case .driversLicense: return "Driver's license"
        case .auto: return "Automatic"
        }
    }

    /// The SF Symbol shown for each type — the SDK's stand-in for bundled
    /// illustration art. Reused by the pre-capture start screen.
    nonisolated static func symbolName(for type: DocumentType) -> String {
        switch type {
        case .passport: return "globe.americas.fill"
        case .idCard: return "person.text.rectangle"
        case .driversLicense: return "car.fill"
        case .auto: return "doc.viewfinder"
        }
    }
}

#Preview {
    DocumentTypePicker { type in
        print("selected: \(type)")
    }
}
