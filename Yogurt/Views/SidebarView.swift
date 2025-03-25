import OSLog
import SwiftUI

struct SidebarView: View {
  @Binding var selectedNote: Note?
  @StateObject private var noteManager = NoteManager.shared
  let combinedAmplitude: Float

  private let logger = Logger(subsystem: kAppSubsystem, category: "SidebarView")

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 1) {
          ForEach(noteManager.notes) { note in
            NoteRow(
              note: note,
              isSelected: selectedNote?.id == note.id,
              combinedAmplitude: combinedAmplitude
            )
            .id("\(note.id)-\(note.title)")
            .onTapGesture {
              selectedNote = note
            }
            .contextMenu {
              Button("Reveal in Finder") {
                revealInFinder(note)
              }
              Divider()
              Button("Delete") {
                deleteNote(note)
              }
              .foregroundColor(.red)
            }
          }
        }
        .padding(.vertical, 4)
      }
    }
    .background(Color(NSColor.controlBackgroundColor))
    .onAppear {
      if noteManager.notes.isEmpty {
        createFirstNote()
      }
    }
  }

  private func createFirstNote() {
    let note = noteManager.createNote()
    selectedNote = note
  }

  private func deleteNote(_ note: Note) {
    do {
      try noteManager.deleteNote(withId: note.id)
      if selectedNote == note {
        selectedNote = noteManager.notes.first
      }
    } catch {
      logger.error("Failed to delete note: \(error.localizedDescription)")
    }
  }

  private func revealInFinder(_ note: Note) {
    if let url = noteManager.getFileUrl(forId: note.id) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
}

struct NoteRow: View {
  let note: Note
  let isSelected: Bool
  let combinedAmplitude: Float

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(note.displayTitle)
              .font(.system(size: 13))
              .lineLimit(1)
              .foregroundColor(isSelected ? .white : .primary)

            if note.hasPendingTranscript {
              Text("•")
                .foregroundColor(.red)
                .font(.system(size: 14))
            }
          }

          Text(formattedDate(note.lastModified))
            .font(.system(size: 11))
            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
        }

        Spacer()

        if note.isRecording {
          // Show live amplitude meter if recording
          AudioWaveformIndicator(
            amplitude: combinedAmplitude,
            isSelected: isSelected
          )
          .frame(width: 24, height: 16)
        }
        if note.isEnhancing {
          // Enhancing spinner/indicator
          EnhancingIndicator(isSelected: isSelected)
            .frame(width: 16, height: 16)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(backgroundColor)
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color(NSColor.selectedContentBackgroundColor).opacity(0.7)
    }
    return isHovering ? Color.gray.opacity(0.1) : Color.clear
  }

  private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

struct EnhancingIndicator: View {
  @State private var rotation: Double = 0
  @State private var scale: CGFloat = 1.0
  let isSelected: Bool

  var body: some View {
    ZStack {
      Image(systemName: "sparkles")
        .font(.system(size: 12))
        .foregroundColor(isSelected ? .white : .orange)
        .rotationEffect(.degrees(rotation))
        .scaleEffect(scale)
    }
    .onAppear {
      withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
        rotation = 360
      }
      withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
        scale = 1.2
      }
    }
  }
}
