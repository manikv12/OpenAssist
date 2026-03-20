import AppKit

enum AssistantSyntaxHighlighter {

    // MARK: - Public

    static func highlight(
        code: String,
        language: String?,
        font: NSFont,
        baseColor: NSColor
    ) -> NSAttributedString {
        let lang = normalizedLanguage(language)
        let output = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: baseColor
            ]
        )
        let fullRange = NSRange(location: 0, length: output.length)

        // Apply tokens from most general to most specific so that later
        // matches (strings, comments) can override earlier ones.
        applyNumbers(to: output, in: fullRange)
        applyKeywords(to: output, language: lang, font: font, in: fullRange)
        applyTypes(to: output, in: fullRange)
        applyProperties(to: output, in: fullRange)
        applyStrings(to: output, in: fullRange, font: font)
        applyComments(to: output, language: lang, in: fullRange, font: font)

        return output
    }

    // MARK: - Language Detection

    private static func normalizedLanguage(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return "text"
        }
        switch raw {
        case "js", "jsx", "mjs", "cjs":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "py", "python3":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "sh", "bash", "zsh", "shell", "fish":
            return "shell"
        case "yml":
            return "yaml"
        case "md":
            return "markdown"
        case "objc", "objective-c", "objectivec":
            return "objc"
        case "cs", "c#", "csharp":
            return "csharp"
        case "jsonc":
            return "json"
        case "dockerfile":
            return "docker"
        case "tf", "hcl":
            return "terraform"
        default:
            return raw
        }
    }

    // MARK: - Colors

    private static let keywordColor = NSColor(calibratedRed: 0.78, green: 0.46, blue: 0.86, alpha: 1.0)
    private static let stringColor = NSColor(calibratedRed: 0.58, green: 0.82, blue: 0.56, alpha: 1.0)
    private static let numberColor = NSColor(calibratedRed: 0.82, green: 0.68, blue: 0.46, alpha: 1.0)
    private static let commentColor = NSColor(calibratedRed: 0.50, green: 0.54, blue: 0.58, alpha: 1.0)
    private static let typeColor = NSColor(calibratedRed: 0.56, green: 0.78, blue: 0.90, alpha: 1.0)
    private static let propertyColor = NSColor(calibratedRed: 0.56, green: 0.78, blue: 0.90, alpha: 1.0)

    // MARK: - Keywords

    private static let keywordSets: [String: Set<String>] = [
        "swift": ["import", "func", "var", "let", "class", "struct", "enum", "protocol",
                  "extension", "if", "else", "guard", "switch", "case", "default",
                  "for", "while", "repeat", "return", "throw", "throws", "try",
                  "catch", "do", "in", "where", "is", "as", "self", "Self",
                  "super", "init", "deinit", "nil", "true", "false", "static",
                  "private", "public", "internal", "fileprivate", "open", "override",
                  "mutating", "nonmutating", "final", "lazy", "weak", "unowned",
                  "optional", "required", "convenience", "typealias", "associatedtype",
                  "async", "await", "actor", "some", "any", "inout", "defer",
                  "break", "continue", "fallthrough", "@Published", "@State",
                  "@Binding", "@ObservedObject", "@Environment", "@MainActor",
                  "@ViewBuilder", "@escaping", "@autoclosure", "@available",
                  "@discardableResult", "@objc", "willSet", "didSet", "get", "set"],
        "javascript": ["const", "let", "var", "function", "return", "if", "else",
                       "for", "while", "do", "switch", "case", "default", "break",
                       "continue", "class", "extends", "new", "this", "super",
                       "import", "export", "from", "async", "await", "try", "catch",
                       "throw", "finally", "typeof", "instanceof", "in", "of",
                       "null", "undefined", "true", "false", "yield", "delete",
                       "void", "static", "get", "set", "constructor"],
        "typescript": ["const", "let", "var", "function", "return", "if", "else",
                       "for", "while", "do", "switch", "case", "default", "break",
                       "continue", "class", "extends", "new", "this", "super",
                       "import", "export", "from", "async", "await", "try", "catch",
                       "throw", "finally", "typeof", "instanceof", "in", "of",
                       "null", "undefined", "true", "false", "yield", "delete",
                       "void", "static", "get", "set", "constructor",
                       "interface", "type", "enum", "implements", "abstract",
                       "private", "public", "protected", "readonly", "as", "is",
                       "keyof", "infer", "never", "unknown", "any", "declare",
                       "namespace", "module"],
        "python": ["def", "class", "return", "if", "elif", "else", "for", "while",
                   "break", "continue", "pass", "import", "from", "as", "try",
                   "except", "finally", "raise", "with", "yield", "lambda",
                   "and", "or", "not", "in", "is", "None", "True", "False",
                   "global", "nonlocal", "del", "assert", "async", "await",
                   "self", "cls", "print", "range", "len", "type", "isinstance"],
        "rust": ["fn", "let", "mut", "const", "static", "struct", "enum", "impl",
                 "trait", "type", "use", "mod", "pub", "crate", "self", "super",
                 "if", "else", "match", "for", "while", "loop", "break", "continue",
                 "return", "as", "in", "ref", "move", "async", "await", "unsafe",
                 "where", "true", "false", "Some", "None", "Ok", "Err"],
        "go": ["func", "var", "const", "type", "struct", "interface", "map",
               "chan", "package", "import", "return", "if", "else", "for",
               "range", "switch", "case", "default", "break", "continue",
               "go", "defer", "select", "fallthrough", "nil", "true", "false",
               "make", "new", "len", "cap", "append", "copy", "delete"],
        "java": ["public", "private", "protected", "static", "final", "abstract",
                 "class", "interface", "extends", "implements", "new", "this",
                 "super", "return", "if", "else", "for", "while", "do", "switch",
                 "case", "default", "break", "continue", "try", "catch", "finally",
                 "throw", "throws", "import", "package", "void", "int", "long",
                 "double", "float", "boolean", "char", "byte", "short",
                 "null", "true", "false", "instanceof", "enum", "synchronized",
                 "volatile", "transient", "native", "strictfp", "assert"],
        "c": ["if", "else", "for", "while", "do", "switch", "case", "default",
              "break", "continue", "return", "typedef", "struct", "union", "enum",
              "sizeof", "static", "extern", "const", "volatile", "register",
              "auto", "void", "int", "long", "short", "char", "float", "double",
              "unsigned", "signed", "NULL", "true", "false", "#include", "#define",
              "#ifdef", "#ifndef", "#endif", "#if", "#else", "#pragma"],
        "cpp": ["if", "else", "for", "while", "do", "switch", "case", "default",
                "break", "continue", "return", "typedef", "struct", "union", "enum",
                "sizeof", "static", "extern", "const", "volatile", "register",
                "auto", "void", "int", "long", "short", "char", "float", "double",
                "unsigned", "signed", "NULL", "nullptr", "true", "false",
                "#include", "#define", "#ifdef", "#ifndef", "#endif", "#if", "#else",
                "#pragma", "class", "namespace", "using", "template", "typename",
                "public", "private", "protected", "virtual", "override", "final",
                "new", "delete", "this", "throw", "try", "catch", "noexcept",
                "constexpr", "inline", "explicit", "friend", "operator",
                "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast"],
        "ruby": ["def", "end", "class", "module", "if", "elsif", "else", "unless",
                 "while", "until", "for", "do", "begin", "rescue", "ensure",
                 "raise", "return", "yield", "block_given?", "require", "include",
                 "extend", "attr_reader", "attr_writer", "attr_accessor",
                 "self", "super", "nil", "true", "false", "and", "or", "not",
                 "in", "then", "when", "case", "break", "next", "redo", "retry",
                 "lambda", "proc", "puts", "print"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                  "case", "esac", "in", "function", "return", "exit", "echo",
                  "export", "local", "readonly", "shift", "set", "unset",
                  "source", "alias", "cd", "pwd", "ls", "grep", "sed", "awk",
                  "cat", "mkdir", "rm", "cp", "mv", "chmod", "chown", "curl",
                  "wget", "git", "docker", "npm", "yarn", "pip", "brew",
                  "sudo", "apt", "yum", "true", "false"],
        "html": ["html", "head", "body", "div", "span", "p", "a", "img", "ul",
                 "ol", "li", "table", "tr", "td", "th", "form", "input", "button",
                 "select", "option", "textarea", "label", "script", "style", "link",
                 "meta", "title", "header", "footer", "nav", "main", "section",
                 "article", "aside", "h1", "h2", "h3", "h4", "h5", "h6",
                 "br", "hr", "pre", "code", "strong", "em", "class", "id",
                 "src", "href", "type", "name", "value", "placeholder"],
        "css": ["color", "background", "background-color", "font-size", "font-weight",
                "font-family", "margin", "padding", "border", "display", "position",
                "width", "height", "top", "right", "bottom", "left", "flex",
                "grid", "align-items", "justify-content", "text-align", "overflow",
                "opacity", "z-index", "transition", "transform", "animation",
                "box-shadow", "border-radius", "cursor", "content",
                "!important", "@media", "@keyframes", "@import", "@font-face"],
        "sql": ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
                "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX",
                "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR",
                "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "ORDER", "BY",
                "GROUP", "HAVING", "LIMIT", "OFFSET", "AS", "DISTINCT", "COUNT",
                "SUM", "AVG", "MAX", "MIN", "CASE", "WHEN", "THEN", "ELSE", "END",
                "EXISTS", "UNION", "ALL", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
                "VARCHAR", "INT", "TEXT", "BOOLEAN", "DATE", "TIMESTAMP",
                "select", "from", "where", "insert", "into", "values", "update",
                "set", "delete", "create", "table", "alter", "drop", "index",
                "join", "left", "right", "inner", "outer", "on", "and", "or",
                "not", "null", "is", "in", "like", "between", "order", "by",
                "group", "having", "limit", "offset", "as", "distinct"],
        "json": [],
        "yaml": ["true", "false", "null", "yes", "no", "on", "off"],
        "docker": ["FROM", "RUN", "CMD", "ENTRYPOINT", "COPY", "ADD", "ENV",
                   "ARG", "EXPOSE", "VOLUME", "WORKDIR", "USER", "LABEL",
                   "MAINTAINER", "HEALTHCHECK", "SHELL", "STOPSIGNAL",
                   "ONBUILD", "AS"],
        "terraform": ["resource", "data", "variable", "output", "module",
                      "provider", "terraform", "locals", "dynamic", "for_each",
                      "count", "depends_on", "lifecycle", "provisioner",
                      "true", "false", "null"],
    ]

    private static func keywords(for language: String) -> Set<String> {
        if let set = keywordSets[language] {
            return set
        }
        // Fallback: common programming keywords
        return ["if", "else", "for", "while", "return", "function", "class",
                "var", "let", "const", "import", "export", "from", "true",
                "false", "null", "nil", "None", "try", "catch", "throw",
                "new", "this", "self", "def", "do", "end", "in", "is",
                "as", "break", "continue", "switch", "case", "default",
                "public", "private", "static", "void", "int", "string",
                "async", "await", "yield", "type", "interface", "struct",
                "enum", "impl", "trait", "fn", "mut", "use", "mod", "pub"]
    }

    // MARK: - Comment Styles

    private enum CommentStyle {
        case cStyle          // // and /* */
        case hash            // #
        case doubleDash      // --
        case htmlStyle       // <!-- -->
    }

    private static func commentStyle(for language: String) -> CommentStyle {
        switch language {
        case "python", "ruby", "shell", "yaml", "docker", "terraform":
            return .hash
        case "sql":
            return .doubleDash
        case "html", "xml", "svg":
            return .htmlStyle
        default:
            return .cStyle
        }
    }

    // MARK: - Tokenizers

    private static func applyKeywords(
        to output: NSMutableAttributedString,
        language: String,
        font: NSFont,
        in range: NSRange
    ) {
        let text = output.string
        let kws = keywords(for: language)
        guard !kws.isEmpty else { return }

        // For languages where keywords start with special chars (Swift attrs, C preprocessor)
        let specialPrefixPattern = #"(?:@\w+|#\w+)"#
        if let specialRegex = cachedRegex(specialPrefixPattern) {
            let matches = specialRegex.matches(in: text, range: range)
            for match in matches {
                let matchStr = (text as NSString).substring(with: match.range)
                if kws.contains(matchStr) {
                    output.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                }
            }
        }

        // Word-boundary keyword matching
        let wordPattern = #"(?<![.\w])(\w+)(?!\w)"#
        guard let regex = cachedRegex(wordPattern) else { return }
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            let wordRange = match.range(at: 1)
            let word = (text as NSString).substring(with: wordRange)
            if kws.contains(word) {
                output.addAttribute(.foregroundColor, value: keywordColor, range: wordRange)
            }
        }
    }

    private static func applyTypes(
        to output: NSMutableAttributedString,
        in range: NSRange
    ) {
        // Capitalized identifiers (likely types/classes): String, Int, MyClass, etc.
        let pattern = #"(?<![.\w])([A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*)(?!\w)"#
        guard let regex = cachedRegex(pattern) else { return }
        let text = output.string
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            let matchRange = match.range(at: 1)
            // Only color if it wasn't already colored (keyword takes precedence)
            let existingColor = output.attribute(.foregroundColor, at: matchRange.location, effectiveRange: nil) as? NSColor
            if existingColor == nil || existingColor == output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                output.addAttribute(.foregroundColor, value: typeColor, range: matchRange)
            }
        }
    }

    private static func applyProperties(
        to output: NSMutableAttributedString,
        in range: NSRange
    ) {
        // Object properties: .property or obj.property
        let pattern = #"\.([a-zA-Z_]\w*)"#
        guard let regex = cachedRegex(pattern) else { return }
        let text = output.string
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            let propRange = match.range(at: 1)
            output.addAttribute(.foregroundColor, value: propertyColor, range: propRange)
        }
    }

    private static func applyStrings(
        to output: NSMutableAttributedString,
        in range: NSRange,
        font: NSFont
    ) {
        let text = output.string

        // Double-quoted strings (handling escaped quotes)
        applyPattern(#""(?:[^"\\]|\\.)*""#, color: stringColor, to: output, text: text, in: range)

        // Single-quoted strings
        applyPattern(#"'(?:[^'\\]|\\.)*'"#, color: stringColor, to: output, text: text, in: range)

        // Template literals / backtick strings
        applyPattern(#"`(?:[^`\\]|\\.)*`"#, color: stringColor, to: output, text: text, in: range)

        // Triple-quoted strings (Python)
        applyPattern(#""{3}[\s\S]*?"{3}"#, color: stringColor, to: output, text: text, in: range)
    }

    private static func applyNumbers(
        to output: NSMutableAttributedString,
        in range: NSRange
    ) {
        let text = output.string
        // Hex, float, integer literals
        let pattern = #"(?<![.\w])(0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*\.?\d*(?:[eE][+-]?\d+)?)(?![.\w])"#
        applyPattern(pattern, color: numberColor, to: output, text: text, in: range)
    }

    private static func applyComments(
        to output: NSMutableAttributedString,
        language: String,
        in range: NSRange,
        font: NSFont
    ) {
        let text = output.string
        let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

        switch commentStyle(for: language) {
        case .cStyle:
            // Block comments /* */
            applyPattern(#"/\*[\s\S]*?\*/"#, color: commentColor, font: commentFont, to: output, text: text, in: range)
            // Line comments //
            applyPattern(#"//[^\n]*"#, color: commentColor, font: commentFont, to: output, text: text, in: range)

        case .hash:
            applyPattern(#"#[^\n]*"#, color: commentColor, font: commentFont, to: output, text: text, in: range)

        case .doubleDash:
            applyPattern(#"--[^\n]*"#, color: commentColor, font: commentFont, to: output, text: text, in: range)

        case .htmlStyle:
            applyPattern(#"<!--[\s\S]*?-->"#, color: commentColor, font: commentFont, to: output, text: text, in: range)
        }
    }

    // MARK: - JSON / YAML special handling

    static func highlightJSON(
        code: String,
        font: NSFont,
        baseColor: NSColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: baseColor
            ]
        )
        let text = output.string
        let range = NSRange(location: 0, length: output.length)

        // JSON keys (quoted strings before colon)
        applyPattern(#""[^"]*"\s*(?=:)"#, color: typeColor, to: output, text: text, in: range)

        // JSON string values
        applyPattern(#":\s*("[^"]*")"#, color: stringColor, to: output, text: text, in: range, captureGroup: 1)

        // Numbers
        applyNumbers(to: output, in: range)

        // true/false/null
        applyPattern(#"\b(true|false|null)\b"#, color: keywordColor, to: output, text: text, in: range)

        return output
    }

    static func highlightYAML(
        code: String,
        font: NSFont,
        baseColor: NSColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: baseColor
            ]
        )
        let text = output.string
        let range = NSRange(location: 0, length: output.length)

        // YAML keys (word before colon at start of line)
        applyPattern(#"(?m)^[\s-]*([A-Za-z_][\w.-]*)(?=\s*:)"#, color: typeColor, to: output, text: text, in: range, captureGroup: 1)

        // Strings
        applyStrings(to: output, in: range, font: font)

        // Numbers
        applyNumbers(to: output, in: range)

        // true/false/null/yes/no
        applyPattern(#"\b(true|false|null|yes|no)\b"#, color: keywordColor, to: output, text: text, in: range)

        // Comments
        let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        applyPattern(#"#[^\n]*"#, color: commentColor, font: commentFont, to: output, text: text, in: range)

        return output
    }

    // MARK: - Regex Cache

    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 64
        return cache
    }()

    private static func cachedRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(pattern)-\(options.rawValue)" as NSString
        if let cached = regexCache.object(forKey: key) {
            return cached
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    // MARK: - Helpers

    private static func applyPattern(
        _ pattern: String,
        color: NSColor,
        font: NSFont? = nil,
        to output: NSMutableAttributedString,
        text: String,
        in range: NSRange,
        captureGroup: Int = 0
    ) {
        guard let regex = cachedRegex(pattern, options: [.dotMatchesLineSeparators]) else { return }
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            let targetRange = match.range(at: captureGroup)
            guard targetRange.location != NSNotFound else { continue }
            output.addAttribute(.foregroundColor, value: color, range: targetRange)
            if let font {
                output.addAttribute(.font, value: font, range: targetRange)
            }
        }
    }
}
