# Grokbox 0.5.1

Sweeps are safer to stop, and the Brief is more careful about what it claims.

## Fixed

- Stop now ends a sweep between senders, and ends an automatic tidy-up between steps. The macOS Sweep screen has a Stop button, and every other Stop, including ⌘., does the same thing.
- A sender's sweep rule is saved only once that sender's mail has been filed. Before, rules were saved up front for every sender in the plan, so a stopped sweep still swept those senders at the next tidy-up.
- "Swept N" counts only what the server confirmed. A sweep in which any sender failed ends as a failure and points you to Activity.
- A Gmail folder label the server refused no longer takes those messages out of the inbox.
- Grokbox won't unsubscribe you after a failed archive, or after you press Stop.
- When a large write fails partway, Activity and Undo cover exactly the messages that changed. A write the server never confirmed is shown as interrupted.
- The unsubscribe link and the one-click flag now come from the same message.
- "Where things stand" no longer calls the indexed part of a mailbox "the inbox right now". When the server holds more mail than was indexed, it says so.
- Timed tidy-ups rebuild the summary. The Brief card and the menu-bar popover rebuild a summary left over from an earlier day, including at midnight.
- The email body in the triage prompt is fenced off, and the model is told that nothing inside it is an instruction.
- Wording: hold summaries agree with their count, Activity says "Can't undo" and explains why, and Sweep promises Undo only where it works (Gmail and demo accounts).

Signed with a Developer ID Application certificate and notarized by Apple.

Built with Xcode 27.0 (27A266a) and the macOS 27.0 SDK.

SHA-256: `24f01a6f91ad53b99493986010d21162f050b4a8b58836d9bfc06137933167fc`
