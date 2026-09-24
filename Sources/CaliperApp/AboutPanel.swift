import AppKit

/// The standard About panel, the one every Mac app opens from its app menu.
/// Caliper has no app menu, so the status item menu opens it instead.
///
/// AppKit fills in the icon, the name, the version with its build and the
/// copyright line (`NSHumanReadableCopyright`) from the bundle; only the credits
/// under them are written here. That version line is the point: it is the one
/// place a user can read which build they are running, which is the first thing
/// anyone needs to know about a bug report.
@MainActor
enum AboutPanel {
    static let developer = "Hossain Alhaidari"
    static let sourceCode = URL(string: "https://github.com/hossainalhaidari/caliper")!
    /// The documentation's statement, which is short enough that one place is
    /// enough and public enough that anyone can check it before installing.
    static let privacy = URL(string: "https://hossainalhaidari.github.io/caliper/docs/privacy/")!

    static func show() {
        // An agent app is never frontmost on its own, so without this the panel
        // opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        func text(_ string: String, _ colour: NSColor = .labelColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: centred,
            ])
        }
        func link(_ title: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .font: font, .link: url, .paragraphStyle: centred,
            ])
        }

        // The licences are the copies bundle.sh puts inside the bundle, so they
        // open offline and always match the version that is running. A binary
        // run straight from .build has none, and gets the repository's copy of
        // Caliper's instead.
        func bundledLicense(_ name: String) -> URL? {
            Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
        }
        let ownLicense = bundledLicense("Caliper") ?? sourceCode.appendingPathComponent("blob/main/LICENSE")
        let sparkleLicense = bundledLicense("Sparkle")

        var links = [
            link(
                String(localized: "Source Code", comment: "About window: link to Caliper's repository"),
                sourceCode),
            link(
                String(localized: "Privacy", comment: "About window: link to what Caliper does and does not do with your data"),
                privacy),
        ]
        if let sparkleLicense {
            links.append(link(
                String(
                    localized: "Acknowledgements",
                    comment: "About window: link to the licences of the software Caliper includes"),
                sparkleLicense))
        }

        let credits = NSMutableAttributedString()
        credits.append(text(String(
            localized: "Developed by \(developer)",
            comment: "About window. The argument is the developer's name") + "\n"))

        // The licence's name is its title, so it is passed in untranslated and
        // becomes the link.
        let licenseName = "MIT License"
        let licenseLine = NSMutableAttributedString(attributedString: text(
            String(
                localized: "Free and open source under the \(licenseName).",
                comment: "About window. The argument is the licence's name, \u{201C}MIT License\u{201D}") + "\n",
            .secondaryLabelColor))
        let nameRange = (licenseLine.string as NSString).range(of: licenseName)
        if nameRange.location != NSNotFound {
            licenseLine.addAttribute(.link, value: ownLicense, range: nameRange)
        }
        credits.append(licenseLine)

        for (index, link) in links.enumerated() {
            if index > 0 { credits.append(text(" \u{00B7} ", .tertiaryLabelColor)) }
            credits.append(link)
        }
        return credits
    }
}
