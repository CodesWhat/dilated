#if !MAS_CHANNEL
  import Foundation

  /// Where people can chip in. Dilated is free and open source; these two links live in the menu bar menu, the About page, the
  /// website footer and the README, and nowhere else. Nothing here prompts, nags or runs at launch.
  enum SupportLinks {
    struct Destination: Equatable {
      let title: String
      let url: URL
    }

    static let gitHubSponsors = Destination(
      title: "GitHub Sponsors", url: URL(string: "https://github.com/sponsors/CodesWhat")!)
    static let donate = Destination(
      title: "Donate", url: URL(string: "https://codeswhat.com/support")!)
    static let all = [gitHubSponsors, donate]

    static let menuTitle = "Support Dilated"

    /// The About page's credits line, split around its two links.
    static let creditsLead =
      "Dilated is free and open source. If it saves you time, you can support it on "
    static let creditsDonateText = "donate directly"

    static var credits: AttributedString {
      let lead = AttributedString(creditsLead)
      var sponsors = AttributedString(gitHubSponsors.title)
      sponsors.link = gitHubSponsors.url
      var donateLink = AttributedString(creditsDonateText)
      donateLink.link = donate.url
      return lead + sponsors + AttributedString(" or ") + donateLink + AttributedString(".")
    }
  }
#endif
