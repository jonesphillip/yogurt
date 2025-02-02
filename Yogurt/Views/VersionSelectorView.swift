import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
  var backgroundColor: Color
  var foregroundColor: Color = .primary

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(foregroundColor)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(backgroundColor)
          .opacity(configuration.isPressed ? 0.7 : 1.0)
      )
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

struct VersionSelectorView: View {
  let versions: [NoteVersion]
  let onVersionSelect: (NoteVersion?) -> Void
  let onApplyVersion: (NoteVersion) -> Void
  let noteId: String

  @State private var showingVersion: NoteVersion? = nil
  @State private var isShowingTooltip = false

  private let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "MMMM d, h:mm a"
    return df
  }()

  var body: some View {
    HStack(spacing: 6) {
      if let version = showingVersion {
        Button {
          onApplyVersion(version)
          showingVersion = nil
        } label: {
          HStack(spacing: 4) {
            Text("Restore")
              .font(.system(size: 12))
            Image(systemName: "arrow.counterclockwise")
              .imageScale(.small)
          }
        }
        .buttonStyle(
          CapsuleButtonStyle(
            backgroundColor: Color(nsColor: .controlAccentColor).opacity(0.2),
            foregroundColor: Color(nsColor: .controlAccentColor)
          )
        )
        .transition(.opacity)
      }

      // Menu to select a version
      Menu {
        // Current Version (always shown)
        Button {
          showingVersion = nil
          onVersionSelect(nil)
        } label: {
          HStack {
            Text("Current Version")
            Spacer()
            if showingVersion == nil {
              Image(systemName: "checkmark")
                .foregroundColor(.accentColor)
            }
          }
        }

        if !versions.isEmpty {
          Divider()

          ForEach(versions.sorted(by: { $0.timestamp > $1.timestamp })) { version in
            Button {
              showingVersion = version
              onVersionSelect(version)
            } label: {
              HStack {
                Text(dateFormatter.string(from: version.timestamp))
                Spacer()
                if showingVersion == version {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "clock.arrow.circlepath")
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .frame(width: 12, height: 12)

          if let version = showingVersion {
            Text(dateFormatter.string(from: version.timestamp))
              .font(.system(size: 12))
          } else {
            Text("Current Version")
              .font(.system(size: 12))
          }
        }
      }
      .buttonStyle(
        CapsuleButtonStyle(
          backgroundColor: Color.clear,
          foregroundColor: versions.isEmpty ? .secondary : .primary
        )
      )
      .menuStyle(BorderlessButtonMenuStyle())
      .disabled(versions.isEmpty)
      .popover(isPresented: $isShowingTooltip, arrowEdge: .bottom) {
        VersionTooltip()
      }
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.2)) {
          isShowingTooltip = hovering && versions.isEmpty
        }
      }
    }
    .frame(height: 28)
    .animation(.easeOut(duration: 0.15), value: showingVersion)
    .onChange(of: noteId) { _, _ in
      // Reset to current version when note changes
      if showingVersion != nil {
        showingVersion = nil
        onVersionSelect(nil)
      }
    }
  }
}

struct VersionTooltip: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        """
        Yogurt automatically creates a new version when notes are enhanced \
        or when you restore a past version. This ensures you never lose \
        important changes.
        """
      )
      .font(.system(size: 12))
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .lineSpacing(2)
    }
    .padding(12)
    .frame(width: 260)
  }
}
