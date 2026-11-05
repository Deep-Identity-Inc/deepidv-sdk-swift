// DeepIDV › DocumentScanner (UI)

import DeepIDVCore
import SwiftUI

/// The document-type selection step.
///
/// Presents the three pickable types — Passport / ID card / Driver's license
/// (`allCases` minus `.auto`) — as a list of tappable rows: the front-only-vs-front-and-back
/// capture rule must be known *before* capture, so `.auto` (which has no
/// deterministic side count) is offered only on the headless `scanDocument`
/// method, never here. A tap on a document picks it. Used as the first step of the drop-in flow and available composably;
/// themed via `@Environment(\.theme)` like every SDK view.
public struct DocumentTypePicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
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
        self.heading = L("Which ID will you use?")
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
        let palette = CaptureScreens.Palette(theme, scheme)
        ScrollView { content(palette: palette) }
        .overlay(alignment: .topLeading) {
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(palette.card))
                        .overlay(Circle().strokeBorder(palette.cardLine, lineWidth: 1))
                }
                .buttonStyle(CaptureLayout.PressStyle())
                .accessibilityLabel(L("Cancel"))
                .padding(theme.spacing.md)
            }
        }
        .background(palette.background.ignoresSafeArea())
    }

    /// The heading, the rows and the encryption note, without the scrolling.
    func content(palette: CaptureScreens.Palette) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                Text(heading)
                    .font(theme.typography.heading(size: 28).weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(L("Choose the document you have with you"))
                    .font(theme.typography.body(size: 16))
                    .foregroundStyle(palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: theme.spacing.md) {
                ForEach(availableTypes, id: \.self) { type in
                    row(for: type, palette: palette)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
                Text(CaptureCopy.encryption)
                    .font(theme.typography.body(size: 13).weight(.medium))
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, theme.spacing.sm)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, theme.spacing.lg)
        .padding(.top, onCancel == nil ? theme.spacing.xl : 72)
        .padding(.bottom, theme.spacing.xl)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    /// One document: a small drawing of it, its name and a line about it. A tap
    /// picks it.
    private func row(for type: DocumentType, palette: CaptureScreens.Palette) -> some View {
        Button {
            selected = type
            onSelect(type)
        } label: {
            HStack(spacing: theme.spacing.md) {
                DocumentThumbnail(type: type, palette: palette)
                    .frame(width: 76, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(for: type))
                        .font(theme.typography.body(size: 18).weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(Self.detail(for: type))
                        .font(theme.typography.body(size: 14))
                        .foregroundStyle(palette.secondaryText)
                }
                // Longer languages wrap instead of cutting off.
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(theme.spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.card)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        selected == type ? theme.colors.primary : palette.cardLine,
                        lineWidth: selected == type ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(CaptureLayout.PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == type ? [.isButton, .isSelected] : .isButton)
    }

    /// A line under each type's name.
    nonisolated static func detail(for type: DocumentType) -> String {
        switch type {
        case .passport: return L("Scan the photo page")
        case .idCard: return L("Government-issued photo ID")
        case .driversLicense: return L("Issued by a province or state")
        case .auto: return L("Any photo ID")
        }
    }

    /// The user-facing label for each type.
    nonisolated static func title(for type: DocumentType) -> String {
        switch type {
        case .passport: return L("Passport")
        case .idCard: return L("ID card")
        case .driversLicense: return L("Driver's license")
        case .auto: return L("Automatic")
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

/// A small drawing of a document for the picker: a card, or a passport booklet.
struct DocumentThumbnail: View {
    @Environment(\.theme) private var theme
    let type: DocumentType
    let palette: CaptureScreens.Palette

    var body: some View {
        Group {
            if type == .passport {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.colors.primary)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 18, weight: .medium))
                            Capsule().frame(width: 18, height: 2.5)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    )
                    .frame(width: 40, height: 54)
            } else {
                CaptureScreens.CardFace(back: false, palette: palette)
                    .frame(width: 190, height: 120)
                    .scaleEffect(0.4)
                    .frame(width: 76, height: 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
