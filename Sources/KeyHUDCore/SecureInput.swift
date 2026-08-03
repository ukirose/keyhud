import Carbon

/// Whether macOS is currently hiding keystrokes from event taps.
///
/// An application turns this on to keep a password out of reach of anything watching the
/// keyboard; a terminal turns it on whenever it believes one is being typed, and Ghostty
/// offers it as a permanent setting. While it is on, this app's tap receives nothing at
/// all — no modifier press, so no panel, and no keystroke, so no usage recorded.
///
/// From the outside that is indistinguishable from being broken, and it cost several
/// rounds of investigation before the cause was found. The state is one call away and
/// needs no permission, so there is no excuse for the app to stay silent about it.
///
/// The report cannot live on the panel. Under secure input there *is* no panel: the tap is
/// the only source of the modifier events that raise one. It goes on the menu bar, which
/// does not depend on the tap.
///
/// Not something to work around. Reading keystrokes the system has deliberately hidden is
/// the one thing this feature exists to prevent.
enum SecureInput {
    static var isActive: Bool { IsSecureEventInputEnabled() }
}
