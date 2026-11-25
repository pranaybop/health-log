import SwiftUI
import LogCore

/// The daily check-in form (web: renderCheckinForm in forms.js): how you ate, moved, felt and slept
/// for one day, saved with the same log-write action the web uses.
///
/// Owned by the Meds & Log stage, which replaces this placeholder body. Today presents it in a sheet
/// from its check-in prompt; Log shows it in its "Today's check-in" card. Keep this init signature.
public struct CheckinForm: View {
    /// The day it's for (yyyy-MM-dd, Central time).
    public var day: String
    /// Called after a successful save (Today closes its sheet).
    public var onSaved: (() -> Void)?

    public init(day: String, onSaved: (() -> Void)? = nil) {
        self.day = day
        self.onSaved = onSaved
    }

    public var body: some View {
        EmptyNote("The check-in form is on its way.")
    }
}
