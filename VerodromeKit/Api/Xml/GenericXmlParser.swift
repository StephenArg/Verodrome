import Foundation

/// Lightweight XML tree node used by parser delegates.
public struct XmlNode: Sendable {
    public var name: String
    public var attributes: [String: String]
    public var text: String
    public var children: [XmlNode]

    public init(name: String, attributes: [String: String] = [:], text: String = "", children: [XmlNode] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    public func firstChild(named name: String) -> XmlNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [XmlNode] {
        children.filter { $0.name == name }
    }

    public func descendants(named name: String) -> [XmlNode] {
        var results: [XmlNode] = []
        for child in children {
            if child.name == name { results.append(child) }
            results.append(contentsOf: child.descendants(named: name))
        }
        return results
    }
}

/// Base `XMLParserDelegate` that builds an element tree with attributes and text content.
open class GenericXmlParser: NSObject, XMLParserDelegate {
    private var stack: [XmlNode] = []
    private var currentText = ""
    public private(set) var root: XmlNode?
    public private(set) var parseError: Error?

    public override init() {
        super.init()
    }

    public func parse(data: Data) throws -> XmlNode {
        stack.removeAll()
        currentText = ""
        root = nil
        parseError = nil

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            if let parseError {
                throw parseError
            }
            throw XmlParseError.parserFailed(parser.parserError?.localizedDescription ?? "Unknown parser error")
        }

        guard let root else {
            throw XmlParseError.missingRootElement("root")
        }
        return root
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        stack.append(XmlNode(name: elementName, attributes: attributeDict))
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    /// `XMLParser` reports CDATA through its own callback rather than `foundCharacters`.
    /// Ampache wraps nearly every text value — names, titles, urls, descriptions — in
    /// CDATA, so without this every one of them parses as an empty string.
    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        currentText += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var node = stack.popLast() else { return }
        node.text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if var parent = stack.popLast() {
            parent.children.append(node)
            stack.append(parent)
        } else {
            root = node
        }

        currentText = ""
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = XmlParseError.parserFailed(parseError.localizedDescription)
    }
}
