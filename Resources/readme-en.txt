ScreenBlur — blur part of your screen while sharing it
══════════════════════════════════════════════════════

You are sharing your screen and part of it is nobody's business: a conversation,
a dashboard, a client name, your revenue. ScreenBlur puts a mask over it, and
the mask stays during the screen share.

macOS 15 Sequoia or later. The interface is in French for now.


INSTALLING
──────────
1. Drag ScreenBlur into the Applications folder (the shortcut is right there).
2. FIRST LAUNCH — double-click. macOS will refuse: "cannot verify the
   developer". That is expected: the app has not been through Apple's
   notarisation. Dismiss the message, then:

       System Settings → Privacy & Security → scroll to the bottom
       → "ScreenBlur was blocked…" → "Open Anyway"

   (The old right-click → Open trick no longer works: Apple removed it in
   Sequoia.)

   One-line alternative in Terminal:
       xattr -dr com.apple.quarantine /Applications/ScreenBlur.app

3. No permission is needed to get started. The "Flou réglable" (adjustable
   blur) and "Mosaïque" (pixelate) styles ask for Screen Recording; the other
   two, frosted glass and opaque, ask for nothing.


THE TWO GESTURES
────────────────
⌥⇧N  create or edit zones. Drag on empty space to draw one; drag inside to
     move it; the handles resize it; ⌫ deletes; ⏎ is done.
⌥⇧B  lift or drop every mask at once, without losing them.

Outside edit mode the masks are click-through: you keep working underneath.


THREE WAYS TO HIDE
──────────────────
• A ZONE fixed on screen, always masked.
• A ZONE ATTACHED TO AN APP: it hides only that part, only on that app, and
  follows the window when you move it. Menu: Zones → Zone N → Appliquer…
• A WHOLE APP, every window of it.


WHAT TO KNOW BEFORE A MEETING
─────────────────────────────
Sharing your WHOLE SCREEN shows the masks: they are part of the image macOS
composes, like any other window.

Sharing a SINGLE WINDOW does not. The call then captures only that window, and
no tool can insert itself into that capture — the content you believe is hidden
goes on air. Share the whole screen instead.

The "Aperçu de ce que voient les autres…" menu item grabs an image through the
exact same path a screen share uses, and opens it in Preview. Three seconds
before a meeting.


PRIVACY
───────
Nothing leaves your machine. No account, no network, no telemetry. The
recapture styles read the screen locally to redraw it blurred, and keep nothing.


UNINSTALLING
────────────
Move ScreenBlur.app to the Trash, then, for the settings:
    rm -rf ~/Library/Application\ Support/ScreenBlur
    defaults delete design.axolo.screenblur


─────────────────────────────────────────
Arnaud Morvan — axolo.design
