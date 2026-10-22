import SwiftUI
import Markdown

/// GFM structure rendered with native text and grids. HTML and images never execute or fetch content.
struct MessageBodyView: View {
    private let document: Markdown.Document
    init(text: String) { document = Markdown.Document(parsing: text) }
    var body: some View {
        MarkdownBlocks(nodes: Array(document.children)).font(.system(size: 14)).textSelection(.enabled)
    }
}

private struct MarkdownBlocks: View {
    let nodes: [any Markup]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(nodes.indices, id: \.self) { index in block(nodes[index]) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func block(_ node: any Markup) -> AnyView {
        switch node {
        case let heading as Heading:
            return AnyView(SwiftUI.Text(MarkdownText.inline(heading)).font(heading.level <= 2 ? .title3.weight(.semibold) : .headline).padding(.top, 6))
        case let code as CodeBlock:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SwiftUI.Text(code.language ?? "Code").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { DesktopActions.copy(code.code) }.buttonStyle(.borderless).font(.caption)
                }
                ScrollView(.horizontal) {
                    SwiftUI.Text(code.code.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced)).lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)))
        case let quote as BlockQuote:
            return AnyView(HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                MarkdownBlocks(nodes: Array(quote.children))
            }.fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary))
        case let table as Markdown.Table: return AnyView(MarkdownTableView(table: table))
        case let list as OrderedList: return AnyView(listView(Array(list.listItems), start: Int(list.startIndex)))
        case let list as UnorderedList: return AnyView(listView(Array(list.listItems), start: nil))
        case is ThematicBreak: return AnyView(Divider())
        case let html as HTMLBlock:
            return AnyView(SwiftUI.Text(html.rawHTML).font(.system(.callout, design: .monospaced)))
        default: return AnyView(SwiftUI.Text(MarkdownText.inline(node)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading))
        }
    }
    private func listView(_ items: [ListItem], start: Int?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 9) {
                    if let checkbox = items[index].checkbox {
                        Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.secondary).accessibilityLabel(checkbox == .checked ? "Checked" : "Unchecked")
                            .frame(width: 22)
                    } else {
                        SwiftUI.Text(start.map { "\($0 + index)." } ?? "•").monospacedDigit().frame(minWidth: 22, alignment: .trailing)
                    }
                    MarkdownBlocks(nodes: Array(items[index].children))
                }
            }
        }
    }
}

private struct MarkdownTableView: View {
    let table: Markdown.Table
    private var rows: [[Markdown.Table.Cell]] { [Array(table.head.cells)] + table.body.rows.map { Array($0.cells) } }
    private func alignment(_ column: Int) -> Alignment {
        guard column < table.columnAlignments.count else { return .leading }
        switch table.columnAlignments[column] { case .right: return .trailing; case .center: return .center; default: return .leading }
    }
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(rows[row].indices, id: \.self) { column in
                            SwiftUI.Text(MarkdownText.inline(rows[row][column]))
                                .fontWeight(row == 0 ? .semibold : .regular)
                                .multilineTextAlignment(alignment(column) == .trailing ? .trailing : alignment(column) == .center ? .center : .leading)
                                .frame(maxWidth: .infinity, alignment: alignment(column))
                                .containerRelativeFrame(.horizontal) { width, _ in max(140, width / CGFloat(max(1, table.maxColumnCount)) - 24) }
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(row == 0 ? Color.primary.opacity(0.07) : row.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5) }
        }.accessibilityLabel("Table, \(table.maxColumnCount) columns, \(table.body.childCount) data rows")
    }
}

/// Inline rendering is shared by paragraphs, headings, list items and table cells.
enum MarkdownText {
    static func inline(_ node: any Markup) -> AttributedString {
        switch node {
        case let text as Markdown.Text: return AttributedString(text.string)
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let code as InlineCode:
            var result = AttributedString(code.code); result.font = .system(.callout, design: .monospaced); return result
        case let html as InlineHTML: return AttributedString(html.rawHTML)
        case let image as Markdown.Image:
            var result = AttributedString("[Image: \(image.plainText.isEmpty ? "attachment" : image.plainText)]")
            result.link = safeLink(image.source); return result
        default:
            var result = node.children.reduce(into: AttributedString()) { $0 += inline($1) }
            if node is Strong {
                for run in result.runs { result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
            }
            if node is Emphasis {
                for run in result.runs { result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized) }
            }
            if node is Strikethrough { result.strikethroughStyle = .single }
            if let link = node as? Markdown.Link { result.link = safeLink(link.destination) }
            return result
        }
    }
    static func preview(_ text: String) -> String {
        func plain(_ node: any Markup) -> String {
            if let inline = node as? any PlainTextConvertibleMarkup { return inline.plainText }
            if let code = node as? CodeBlock { return code.code }
            return node.children.map { plain($0) }.joined(separator: " ")
        }
        return plain(Markdown.Document(parsing: String(text.prefix(2_000)))).replacingOccurrences(of: "\n", with: " ")
    }
    static func safeLink(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
