import Foundation

// MARK: - TokenFormat
//
// Abbreviated token counts for the popover token row (PopoverView.tokenRow)
// and the plugin status line (plugin/statusline.sh fmt_tokens), which must
// agree. Thousands truncate to "k"; a million or more prints as "M" with one
// decimal only when it is not whole, so a 1M window is "1M", never "1000k"
// (issue #47). Exact counts stay in the tooltip.

public enum TokenFormat {
    public static func short(_ n: Int) -> String {
        if n >= 1_000_000 {
            let tenths = n / 100_000
            if tenths % 10 == 0 { return "\(tenths / 10)M" }
            return "\(tenths / 10).\(tenths % 10)M"
        }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return String(n)
    }
}
