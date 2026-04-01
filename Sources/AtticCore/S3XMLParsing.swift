import Foundation

/// Parsed result from an S3 ListObjectsV2 response.
struct ListObjectsV2Result {
    var objects: [S3ListObject] = []
    var isTruncated: Bool = false
    var nextContinuationToken: String?
}

/// Parse an S3 ListObjectsV2 XML response.
func parseListObjectsV2(data: Data) -> ListObjectsV2Result {
    let parser = ListObjectsV2Parser()
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    xmlParser.parse()
    return parser.result
}

/// Parse an S3 error XML response, returning (code, message).
func parseS3Error(data: Data) -> (code: String, message: String)? {
    let parser = S3ErrorParser()
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    xmlParser.parse()
    guard !parser.code.isEmpty else { return nil }
    return (parser.code, parser.message)
}

// MARK: - ListObjectsV2 Parser

private class ListObjectsV2Parser: NSObject, XMLParserDelegate {
    var result = ListObjectsV2Result()
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false
    private var currentKey = ""
    private var currentSize = 0

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:],
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            inContents = true
            currentKey = ""
            currentSize = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inContents {
            switch elementName {
            case "Key": currentKey = text
            case "Size": currentSize = Int(text) ?? 0
            case "Contents":
                if !currentKey.isEmpty {
                    result.objects.append(S3ListObject(key: currentKey, size: currentSize))
                }
                inContents = false
            default: break
            }
        } else {
            switch elementName {
            case "IsTruncated": result.isTruncated = (text == "true")
            case "NextContinuationToken": result.nextContinuationToken = text
            default: break
            }
        }
    }
}

// MARK: - S3 Error Parser

private class S3ErrorParser: NSObject, XMLParserDelegate {
    var code = ""
    var message = ""
    private var currentElement = ""
    private var currentText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:],
    ) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Code": code = text
        case "Message": message = text
        default: break
        }
    }
}
