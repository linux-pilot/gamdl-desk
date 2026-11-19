import AppKit
import SwiftUI

/// gamdl's output in a read-only NSTextView. New lines are appended to the text storage instead of
/// re-rendering the whole log, and it only auto-scrolls when you're already at the bottom.
struct LogView: NSViewRepresentable {
    let store: LogStore

    final class Coordinator {
        var generation = -1
        var shown = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        tv.textColor = .labelColor
        tv.setAccessibilityLabel("gamdl output")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading these here registers the view for Observation updates.
        let generation = store.generation, total = store.total, lines = store.lines
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator

        let atBottom = scroll.documentVisibleRect.maxY >= tv.bounds.maxY - 24
        let attrs: [NSAttributedString.Key: Any] = [.font: tv.font as Any, .foregroundColor: NSColor.labelColor]
        let newCount = total - c.shown

        if generation != c.generation {
            storage.setAttributedString(NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs))
        } else if newCount > 0 {
            let text = (storage.length > 0 ? "\n" : "") + lines.suffix(newCount).joined(separator: "\n")
            storage.append(NSAttributedString(string: text, attributes: attrs))
        }
        c.generation = generation
        c.shown = total
        if atBottom && newCount != 0 { tv.scrollToEndOfDocument(nil) }
    }
}
