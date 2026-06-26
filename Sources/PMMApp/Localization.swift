enum L10n {
    static func string(_ value: String) -> String { value }
    static func format(_ format: String, _ args: CVarArg...) -> String {
        String(format: format, arguments: args)
    }
}
