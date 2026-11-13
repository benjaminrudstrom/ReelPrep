import Foundation

/// Validates FCPXML against the DTD Final Cut Pro ships inside its app bundle (read in place).
public enum FCPXMLValidator {
    public static let defaultAppURL = URL(fileURLWithPath: "/Applications/Final Cut Pro.app")

    /// The DTD for a FCPXML version ("1.14" -> FCPXMLv1_14.dtd), or nil when FCP isn't installed.
    public static func dtdURL(version: String = FCPXMLWriter.version, app: URL = defaultAppURL) -> URL? {
        let file = "FCPXMLv" + version.replacingOccurrences(of: ".", with: "_") + ".dtd"
        let url = app.appendingPathComponent("Contents/Frameworks/Interchange.framework/Versions/A/Resources/\(file)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Throws with the validator's message when `xml` does not match the DTD.
    public static func validate(_ xml: String, dtd: URL) throws {
        let doc = try XMLDocument(xmlString: xml, options: [])
        let d = try XMLDTD(contentsOf: dtd, options: [])
        d.name = "fcpxml"
        doc.dtd = d
        try doc.validate()
    }
}
