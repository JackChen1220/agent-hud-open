import Foundation

public enum MoneyFormat {
    public static func amount(_ amount: Decimal, currency: String, estimated: Bool = false) -> String {
        let format = Decimal.FormatStyle.Currency(code: currency)
            .presentation(.narrow)
            .locale(Locale(identifier: L10n.resolved == .zhHans ? "zh_CN" : "en_US"))
            .precision(.fractionLength(2...(estimated ? 6 : 2)))
        let minimum = Decimal(string: "0.000001")!
        if estimated, amount > 0, amount < minimum {
            return "<" + minimum.formatted(format)
        }
        return amount.formatted(format)
    }
}
