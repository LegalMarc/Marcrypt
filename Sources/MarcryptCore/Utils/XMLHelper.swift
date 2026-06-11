import Foundation

/// A lightweight XML DOM node for robustly modifying DOCX XML.
public class XMLNode {
    public var name: String
    public var attributes: [String: String]
    public var children: [XMLNode]
    public var content: String?
    
    public init(name: String, attributes: [String: String] = [:], content: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.children = []
        self.content = content
    }
    
    // MARK: - Traversal & Manipulation
    
    public func firstChild(named name: String) -> XMLNode? {
        return children.first { $0.name == name }
    }
    
    public func removeChildren(named name: String) {
        children.removeAll { $0.name == name }
    }
    
    /// Recursively find all descendant nodes with the given name.
    public func findAll(named name: String) -> [XMLNode] {
        var results: [XMLNode] = []
        for child in children {
            if child.name == name {
                results.append(child)
            }
            results.append(contentsOf: child.findAll(named: name))
        }
        return results
    }
    
    public func appendChild(_ node: XMLNode) {
        children.append(node)
    }
    
    public func insertChild(_ node: XMLNode, at index: Int) {
        if index >= 0 && index <= children.count {
            children.insert(node, at: index)
        } else {
            children.append(node)
        }
    }
    
    // MARK: - Serialization
    
    public func toString() -> String {
        var str = "<\(name)"
        
        // Attributes
        for (key, value) in attributes {
            str += " \(key)=\"\(value.xmlEscaped())\""
        }
        
        if children.isEmpty && content == nil {
            str += "/>"
        } else {
            str += ">"
            if let text = content {
                str += text.xmlEscaped()
            }
            for child in children {
                str += child.toString()
            }
            str += "</\(name)>"
        }
        
        return str
    }
}

// MARK: - Parser

public class XMLHelper: NSObject, XMLParserDelegate {
    private var root: XMLNode?
    private var stack: [XMLNode] = []
    private var currentText: String = ""
    
    public static func parse(xml: String) throws -> XMLNode {
        let parser = XMLHelper()
        guard let data = xml.data(using: .utf8) else { throw XMLHelperError.invalidEncoding }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        
        if xmlParser.parse(), let root = parser.root {
            return root
        } else {
            throw XMLHelperError.parsingFailed
        }
    }
    
    // MARK: - XMLParserDelegate
    
    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.appendChild(node)
        } else {
            root = node
        }
        stack.append(node)
        currentText = "" // Reset text buffer
    }
    
    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let node = stack.last, node.name == elementName {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                node.content = trimmed
            }
            stack.removeLast()
        }
    }
    
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
}

public enum XMLHelperError: Error {
    case invalidEncoding
    case parsingFailed
}

extension String {
    func xmlEscaped() -> String {
        return self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
