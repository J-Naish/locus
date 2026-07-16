# Terminal

The terminal is an on-demand panel for running and reviewing agent CLI
sessions (Codex, Claude Code, local tools) without leaving Locus. It is a
quiet companion below the editor, not an always-visible IDE terminal.
Decision record: ADR 0012. Emulation lives in `core/crates/terminal`
(a faithful ghostty port); PTY management in `core/crates/pty`.

## Panel and session lifecycle

- Toggle with ⌘J or Ctrl+` below the editor pane. The pane matches the
  editor pane's rounded chrome and adds no toolbar of its own.
- The session starts on first open and survives hiding the panel. When the
  shell exits, the panel shows the exit state and a fresh session can be
  started in place.
- The shell is the user's login shell (`$SHELL`, falling back to
  `/bin/zsh`), started as a login shell with a minimal environment and
  `TERM=xterm-256color`.
- The window title (OSC 0/2) or, when no title is set, the reported
  working directory (OSC 7, shown `~`-abbreviated) appears as a quiet
  caption in the panel's top-trailing corner.

## Emulation

- VT100/xterm-family emulation ported from ghostty, including bracketed
  paste, the kitty keyboard protocol, synchronized output (mode 2026),
  grapheme clustering (mode 2027, on by default) with UCD-backed widths,
  and alternate-screen mouse reporting.
- Scrollback is bounded (256 MiB cap; grid dimensions capped at 4096).
  Wheel and trackpad scrolling work in the primary screen; inside
  alternate-screen apps the wheel converts to arrow keys when the app asks
  for it (mode 1007). A jump-to-bottom pill appears while scrolled back,
  and typing returns the view to the bottom.
- Full-screen TUIs (vim, htop, less) receive mouse reports when they
  request them; holding Shift bypasses reporting for local selection.

## Rendering

- The pane renders live via Metal: glyphs are rasterized once into an
  atlas and drawn as instanced quads. `LOCUS_TERMINAL_RENDERER=cg`
  launches with the Core Graphics path instead; that path also serves as
  the offscreen oracle for the pixel-parity and differential tests.
- Wide (2-cell) CJK glyphs render with a grid-fitted Japanese font so
  kanji and kana read as continuous text; ambiguous-width symbols
  (※ ① ○ →) condense into their single cell instead of overflowing.
  Emoji render in color, including ZWJ sequences.
- Japanese input works inline: the IME preedit draws at the caret,
  occludes the cells beneath it, and places the candidate window at the
  caret position.

## Interaction

- Selection: drag, double-click (word), triple-click (line); Option drags
  a rectangle. Highlights snap to whole wide glyphs, and the highlight
  always matches exactly what ⌘C copies. Double-click hits anywhere on a
  wide glyph, and clicking either half of a glyph resolves sensibly
  (left half = before, right half = after).
- Clicking in the current command line moves the shell caret to the
  clicked character, counting characters rather than cells so it works in
  Japanese text.
- Find: ⌘F opens a quiet find bar with live highlights, Return /
  Shift+Return cycling, and a match counter; Esc returns focus to the
  terminal. The search survives alternate-screen round trips.
- URLs: holding ⌘ underlines the link under the pointer and shows the
  target; ⌘-click opens it. Only `http`/`https` URLs are recognized and
  opened.
- Paste: multi-line paste warns before sending unless the running program
  uses bracketed paste (where it is safe by construction).
- Programs can place text on the clipboard via OSC 52 (for example vim/tmux
  yanks over SSH).

## Security posture

- The terminal runs only what the user types; the app never initiates
  commands.
- Programs may write the clipboard via OSC 52 (write-allow, matching modern
  terminals), guarded by a 1 MiB cap and restricted to the system clipboard;
  clipboard READ requests are never honored.
- Link opening is restricted to `http`/`https`.
- Terminal output, titles, and reported paths are treated as untrusted
  input at the FFI boundary (dimension caps, safe-paste gating, validated
  URL schemes).

## Performance

- Feed throughput is ghostty-class (hundreds of MB/s on plain streams in
  release builds); display updates coalesce to the display refresh so
  floods stay responsive and Ctrl+C is immediate.
- The Metal draw path keeps per-frame CPU work in the low milliseconds
  (debug builds) with sub-0.1 ms GPU time; standing probes in
  `LocusTests` (`testDrawPassTimingProbe`,
  `testMetalRenderPassTimingProbe`) track regressions.
