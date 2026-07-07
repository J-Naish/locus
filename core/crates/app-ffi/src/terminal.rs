//! C ABI for the terminal emulator core.
//!
//! The ABI owns a parser-backed terminal stream plus a reusable render frame.
//! Callers feed PTY bytes, render the current viewport into a stable C view,
//! and copy any response bytes before freeing the Rust-owned buffers.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::time::{Duration, Instant};

use terminal::color::Rgb;
use terminal::input::{self, Action, Key, KeyEvent, Mods, OptionAsAlt};
use terminal::modes::Mode;
use terminal::page::CellWide;
use terminal::page_list::Scroll;
use terminal::render::{DirtyState, RenderState};
use terminal::screen::CursorStyle;
use terminal::stream::Stream;
use terminal::stream_terminal::{CapturedEffects, TerminalHandler};
use terminal::style::{FgOptions, Style};
use terminal::terminal::{Options as TerminalOptions, Terminal};

use crate::{clear_last_error_message, set_last_error_message, LOCUS_STATUS_OK};

pub const LOCUS_TERM_ABI_VERSION: u32 = 1;

pub const LOCUS_TERM_STATUS_INVALID_ARGUMENT: u32 = 300;
pub const LOCUS_TERM_STATUS_PANIC: u32 = 301;
pub const LOCUS_TERM_STATUS_UNSAFE_PASTE: u32 = 302;

pub const LOCUS_TERM_DIRTY_NONE: u32 = 0;
pub const LOCUS_TERM_DIRTY_PARTIAL: u32 = 1;
pub const LOCUS_TERM_DIRTY_FULL: u32 = 2;

pub const LOCUS_TERM_ACTION_RELEASE: u32 = 0;
pub const LOCUS_TERM_ACTION_PRESS: u32 = 1;
pub const LOCUS_TERM_ACTION_REPEAT: u32 = 2;

pub const LOCUS_TERM_MOD_SHIFT: u16 = 1 << 0;
pub const LOCUS_TERM_MOD_CTRL: u16 = 1 << 1;
pub const LOCUS_TERM_MOD_ALT: u16 = 1 << 2;
pub const LOCUS_TERM_MOD_SUPER: u16 = 1 << 3;
pub const LOCUS_TERM_MOD_CAPS_LOCK: u16 = 1 << 4;
pub const LOCUS_TERM_MOD_NUM_LOCK: u16 = 1 << 5;

pub const LOCUS_TERM_KEY_UNIDENTIFIED: u32 = 0;
pub const LOCUS_TERM_KEY_ENTER: u32 = 1;
pub const LOCUS_TERM_KEY_BACKSPACE: u32 = 2;
pub const LOCUS_TERM_KEY_TAB: u32 = 3;
pub const LOCUS_TERM_KEY_ESCAPE: u32 = 4;
pub const LOCUS_TERM_KEY_ARROW_UP: u32 = 10;
pub const LOCUS_TERM_KEY_ARROW_DOWN: u32 = 11;
pub const LOCUS_TERM_KEY_ARROW_LEFT: u32 = 12;
pub const LOCUS_TERM_KEY_ARROW_RIGHT: u32 = 13;
pub const LOCUS_TERM_KEY_HOME: u32 = 14;
pub const LOCUS_TERM_KEY_END: u32 = 15;
pub const LOCUS_TERM_KEY_PAGE_UP: u32 = 16;
pub const LOCUS_TERM_KEY_PAGE_DOWN: u32 = 17;
pub const LOCUS_TERM_KEY_DELETE: u32 = 18;
pub const LOCUS_TERM_KEY_INSERT: u32 = 19;
pub const LOCUS_TERM_KEY_F1: u32 = 101;
pub const LOCUS_TERM_KEY_F2: u32 = 102;
pub const LOCUS_TERM_KEY_F3: u32 = 103;
pub const LOCUS_TERM_KEY_F4: u32 = 104;
pub const LOCUS_TERM_KEY_F5: u32 = 105;
pub const LOCUS_TERM_KEY_F6: u32 = 106;
pub const LOCUS_TERM_KEY_F7: u32 = 107;
pub const LOCUS_TERM_KEY_F8: u32 = 108;
pub const LOCUS_TERM_KEY_F9: u32 = 109;
pub const LOCUS_TERM_KEY_F10: u32 = 110;
pub const LOCUS_TERM_KEY_F11: u32 = 111;
pub const LOCUS_TERM_KEY_F12: u32 = 112;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermBytes {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<Rgb> for LocusTermRgb {
    fn from(value: Rgb) -> Self {
        Self {
            r: value.r,
            g: value.g,
            b: value.b,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermCursor {
    pub x: u16,
    pub y: u16,
    pub visible: bool,
    pub blinking: bool,
    pub wide_tail: bool,
    pub style: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermCell {
    pub codepoint: u32,
    pub raw: u64,
    pub fg: LocusTermRgb,
    pub bg: LocusTermRgb,
    pub flags: u32,
    pub wide: u8,
    pub grapheme_start: usize,
    pub grapheme_len: usize,
    pub hyperlink_id: u16,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermRow {
    pub y: u16,
    pub cell_start: usize,
    pub cell_count: usize,
    pub dirty: bool,
    pub wrapped: bool,
}

/// Reusable Rust-owned render frame. Public fields form the C-readable prefix;
/// private buffers keep the pointed-to memory alive until the next render/free.
#[repr(C)]
pub struct LocusTermFrame {
    pub abi_version: u32,
    pub cols: u16,
    pub rows: u16,
    pub dirty_state: u32,
    pub row_count: usize,
    pub rows_ptr: *const LocusTermRow,
    pub cell_count: usize,
    pub cells_ptr: *const LocusTermCell,
    pub grapheme_count: usize,
    pub graphemes_ptr: *const u32,
    pub cursor: LocusTermCursor,
    storage: *mut LocusTermFrameStorage,
}

struct LocusTermFrameStorage {
    row_storage: Vec<LocusTermRow>,
    cell_storage: Vec<LocusTermCell>,
    grapheme_storage: Vec<u32>,
}

impl LocusTermFrame {
    fn new() -> Self {
        let storage = Box::into_raw(Box::new(LocusTermFrameStorage {
            row_storage: Vec::new(),
            cell_storage: Vec::new(),
            grapheme_storage: Vec::new(),
        }));
        let mut frame = Self {
            abi_version: LOCUS_TERM_ABI_VERSION,
            cols: 0,
            rows: 0,
            dirty_state: LOCUS_TERM_DIRTY_FULL,
            row_count: 0,
            rows_ptr: ptr::null(),
            cell_count: 0,
            cells_ptr: ptr::null(),
            grapheme_count: 0,
            graphemes_ptr: ptr::null(),
            cursor: LocusTermCursor::default(),
            storage,
        };
        frame.refresh_pointers();
        frame
    }

    fn storage_mut(&mut self) -> &mut LocusTermFrameStorage {
        debug_assert!(!self.storage.is_null());
        // SAFETY: LocusTermFrame::new installs a Box-owned storage pointer,
        // and frame_free drops it exactly once after all public pointers are
        // no longer used.
        unsafe { &mut *self.storage }
    }

    fn storage_ref(&self) -> &LocusTermFrameStorage {
        debug_assert!(!self.storage.is_null());
        // SAFETY: same storage ownership invariant as storage_mut.
        unsafe { &*self.storage }
    }

    fn refresh_pointers(&mut self) {
        let (row_count, rows_ptr, cell_count, cells_ptr, grapheme_count, graphemes_ptr) = {
            let storage = self.storage_ref();
            let row_count = storage.row_storage.len();
            let rows_ptr = if storage.row_storage.is_empty() {
                ptr::null()
            } else {
                storage.row_storage.as_ptr()
            };
            let cell_count = storage.cell_storage.len();
            let cells_ptr = if storage.cell_storage.is_empty() {
                ptr::null()
            } else {
                storage.cell_storage.as_ptr()
            };
            let grapheme_count = storage.grapheme_storage.len();
            let graphemes_ptr = if storage.grapheme_storage.is_empty() {
                ptr::null()
            } else {
                storage.grapheme_storage.as_ptr()
            };
            (
                row_count,
                rows_ptr,
                cell_count,
                cells_ptr,
                grapheme_count,
                graphemes_ptr,
            )
        };
        self.row_count = row_count;
        self.rows_ptr = rows_ptr;
        self.cell_count = cell_count;
        self.cells_ptr = cells_ptr;
        self.grapheme_count = grapheme_count;
        self.graphemes_ptr = graphemes_ptr;
    }
}

impl Drop for LocusTermFrame {
    fn drop(&mut self) {
        if self.storage.is_null() {
            return;
        }
        // SAFETY: storage was created by Box::into_raw in LocusTermFrame::new
        // and is owned by this frame until drop.
        unsafe {
            drop(Box::from_raw(self.storage));
        }
        self.storage = ptr::null_mut();
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermKeyEvent {
    pub action: u32,
    pub key: u32,
    pub mods: u16,
    pub consumed_mods: u16,
    pub composing: bool,
    pub utf8: *const u8,
    pub utf8_len: usize,
    pub unshifted_codepoint: u32,
}

pub struct LocusTerm {
    stream: Stream<TerminalHandler<CapturedEffects>>,
    render_state: RenderState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TermReplayDump {
    Plain,
    Vt,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TermReplayOutput {
    pub text: String,
    pub bytes: usize,
    pub feed: Duration,
    pub render: Duration,
}

pub fn replay_bytes(
    bytes: &[u8],
    cols: u16,
    rows: u16,
    dump: TermReplayDump,
) -> Result<TermReplayOutput, u32> {
    let term = locus_term_new(cols, rows, 10_000_000);
    if term.is_null() {
        return Err(LOCUS_TERM_STATUS_INVALID_ARGUMENT);
    }

    let feed_start = Instant::now();
    // SAFETY: term is a live handle from locus_term_new, and bytes.as_ptr()
    // points to bytes.len() readable bytes for this synchronous call.
    let feed_status = unsafe { locus_term_feed(term, bytes.as_ptr(), bytes.len()) };
    let feed = feed_start.elapsed();
    if feed_status != LOCUS_STATUS_OK {
        // SAFETY: term is still a live handle and has not been freed.
        unsafe {
            locus_term_free(term);
        }
        return Err(feed_status);
    }

    let frame = locus_term_frame_new();
    if frame.is_null() {
        // SAFETY: term is still a live handle and has not been freed.
        unsafe {
            locus_term_free(term);
        }
        return Err(LOCUS_TERM_STATUS_PANIC);
    }

    let render_start = Instant::now();
    // SAFETY: term and frame are live handles created above.
    let render_status = unsafe { locus_term_render(term, frame, true) };
    let render = render_start.elapsed();
    if render_status != LOCUS_STATUS_OK {
        // SAFETY: both handles are still live and have not been freed.
        unsafe {
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
        return Err(render_status);
    }

    // SAFETY: frame is live and immutable for this synchronous read.
    let text = unsafe { dump_frame(frame, dump) };
    // SAFETY: both handles are still live and have not been freed.
    unsafe {
        locus_term_frame_free(frame);
        locus_term_free(term);
    }
    Ok(TermReplayOutput {
        text,
        bytes: bytes.len(),
        feed,
        render,
    })
}

#[no_mangle]
pub extern "C" fn locus_term_abi_version() -> u32 {
    LOCUS_TERM_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn locus_term_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut LocusTerm {
    match catch_unwind(AssertUnwindSafe(|| {
        clear_last_error_message();
        if cols == 0 || rows == 0 {
            set_last_error_message("terminal dimensions must be greater than zero");
            return ptr::null_mut();
        }
        let terminal = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback,
            width_px: 0,
            height_px: 0,
        });
        let stream = Stream::new(TerminalHandler::new(terminal, CapturedEffects::default()));
        let render_state = RenderState::new(rows, cols);
        Box::into_raw(Box::new(LocusTerm {
            stream,
            render_state,
        }))
    })) {
        Ok(term) => term,
        Err(_) => {
            set_last_error_message("terminal creation panicked");
            ptr::null_mut()
        }
    }
}

/// # Safety
///
/// `term` must be NULL or a live handle returned by `locus_term_new` that has
/// not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_term_free(term: *mut LocusTerm) {
    if term.is_null() {
        return;
    }
    // SAFETY: the caller promises `term` came from Box::into_raw in
    // locus_term_new and has not been freed yet.
    unsafe {
        drop(Box::from_raw(term));
    }
}

/// # Safety
///
/// `term` must be a live terminal handle. `bytes` must point to `len` readable
/// bytes, or may be NULL when `len == 0`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_feed(
    term: *mut LocusTerm,
    bytes: *const u8,
    len: usize,
) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Some(bytes) = bytes_slice(bytes, len) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        term.stream.next_slice(bytes);
        LOCUS_STATUS_OK
    })
}

/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_take_responses(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe {
            *out = LocusTermBytes::default();
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let bytes = std::mem::take(&mut term.stream.handler.effects.pty);
        // SAFETY: out is still valid for this synchronous call.
        unsafe {
            *out = bytes_from_vec(bytes);
        }
        LOCUS_STATUS_OK
    })
}

/// # Safety
///
/// `bytes` must be NULL or a live `LocusTermBytes` previously returned by this
/// ABI. The struct is reset, so calling this function again with the same
/// struct is safe and a no-op.
#[no_mangle]
pub unsafe extern "C" fn locus_term_bytes_free(bytes: *mut LocusTermBytes) {
    if bytes.is_null() {
        return;
    }
    // SAFETY: bytes is non-null. We immediately copy the value and reset the
    // caller's struct so a second free of the same struct is a no-op.
    let owned = unsafe {
        let owned = *bytes;
        *bytes = LocusTermBytes::default();
        owned
    };
    if owned.ptr.is_null() || owned.cap == 0 {
        return;
    }
    // SAFETY: ptr/len/cap came from Vec::into_raw_parts emulation in
    // bytes_from_vec, and this path runs at most once per struct reset above.
    unsafe {
        drop(Vec::from_raw_parts(owned.ptr, owned.len, owned.cap));
    }
}

/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_resize(term: *mut LocusTerm, cols: u16, rows: u16) -> u32 {
    term_status(|| {
        if cols == 0 || rows == 0 {
            set_last_error_message("terminal dimensions must be greater than zero");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        term.stream.handler.terminal.resize(cols, rows);
        LOCUS_STATUS_OK
    })
}

/// # Safety
///
/// `term` and `frame` must be live handles returned by this ABI.
#[no_mangle]
pub unsafe extern "C" fn locus_term_render(
    term: *mut LocusTerm,
    frame: *mut LocusTermFrame,
    full: bool,
) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Some(frame) = frame_mut(frame) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        render_into_frame(term, frame, full);
        LOCUS_STATUS_OK
    })
}

#[no_mangle]
pub extern "C" fn locus_term_frame_new() -> *mut LocusTermFrame {
    match catch_unwind(AssertUnwindSafe(|| {
        clear_last_error_message();
        Box::into_raw(Box::new(LocusTermFrame::new()))
    })) {
        Ok(frame) => frame,
        Err(_) => {
            set_last_error_message("terminal frame creation panicked");
            ptr::null_mut()
        }
    }
}

/// # Safety
///
/// `frame` must be NULL or a live handle returned by `locus_term_frame_new`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_frame_free(frame: *mut LocusTermFrame) {
    if frame.is_null() {
        return;
    }
    // SAFETY: the caller promises `frame` came from Box::into_raw in
    // locus_term_frame_new and has not been freed yet.
    unsafe {
        drop(Box::from_raw(frame));
    }
}

/// # Safety
///
/// `term` must be a live terminal handle. `event` and `out` must be non-null.
#[no_mangle]
pub unsafe extern "C" fn locus_term_key(
    term: *mut LocusTerm,
    event: *const LocusTermKeyEvent,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() || event.is_null() {
            set_last_error_message("event and out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out is non-null and caller-provided writable storage.
        unsafe {
            *out = LocusTermBytes::default();
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        // SAFETY: event is non-null and valid for this synchronous call.
        let event = unsafe { *event };
        let Some(utf8) = bytes_slice(event.utf8, event.utf8_len) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let key_event = KeyEvent {
            action: action_from_u32(event.action),
            key: key_from_u32(event.key),
            mods: mods_from_bits(event.mods),
            consumed_mods: mods_from_bits(event.consumed_mods),
            composing: event.composing,
            utf8,
            unshifted_codepoint: event.unshifted_codepoint,
        };
        let opts = key_options(&term.stream.handler.terminal);
        let bytes = input::encode(key_event, opts);
        // SAFETY: out is still valid for this synchronous call.
        unsafe {
            *out = bytes_from_vec(bytes);
        }
        LOCUS_STATUS_OK
    })
}

/// # Safety
///
/// `term` must be a live terminal handle. `bytes` must point to `len` readable
/// bytes, or may be NULL when `len == 0`. `out` must be non-null.
#[no_mangle]
pub unsafe extern "C" fn locus_term_paste(
    term: *mut LocusTerm,
    bytes: *const u8,
    len: usize,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out is non-null and caller-provided writable storage.
        unsafe {
            *out = LocusTermBytes::default();
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Some(bytes) = bytes_slice(bytes, len) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if !input::paste::is_safe(bytes) {
            set_last_error_message("paste contains unsafe control or newline data");
            return LOCUS_TERM_STATUS_UNSAFE_PASTE;
        }
        let mut owned = bytes.to_vec();
        let encoded = input::paste::encode(
            &mut owned,
            input::paste::Options {
                bracketed: term.stream.handler.terminal.modes.get(Mode::BracketedPaste),
            },
        );
        let result = [encoded.prefix, encoded.body, encoded.suffix].concat();
        // SAFETY: out is still valid for this synchronous call.
        unsafe {
            *out = bytes_from_vec(result);
        }
        LOCUS_STATUS_OK
    })
}

/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_scroll(term: *mut LocusTerm, delta: isize) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        term.stream
            .handler
            .terminal
            .active_screen_mut()
            .scroll(Scroll::DeltaRow(delta));
        LOCUS_STATUS_OK
    })
}

fn term_status(action: impl FnOnce() -> u32) -> u32 {
    clear_last_error_message();
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(status) => status,
        Err(_) => {
            set_last_error_message("terminal FFI call panicked");
            LOCUS_TERM_STATUS_PANIC
        }
    }
}

fn bytes_slice<'a>(bytes: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if bytes.is_null() {
        set_last_error_message("bytes must not be NULL when len > 0");
        return None;
    }
    // SAFETY: the caller guarantees bytes points to len readable bytes for the
    // duration of the synchronous FFI call; we only borrow the slice.
    Some(unsafe { std::slice::from_raw_parts(bytes, len) })
}

fn bytes_from_vec(mut bytes: Vec<u8>) -> LocusTermBytes {
    let result = LocusTermBytes {
        ptr: bytes.as_mut_ptr(),
        len: bytes.len(),
        cap: bytes.capacity(),
    };
    std::mem::forget(bytes);
    result
}

fn term_mut<'a>(term: *mut LocusTerm) -> Option<&'a mut LocusTerm> {
    if term.is_null() {
        set_last_error_message("term must not be NULL");
        return None;
    }
    // SAFETY: the caller guarantees this is a live unique terminal handle for
    // the duration of the synchronous FFI call.
    Some(unsafe { &mut *term })
}

fn frame_mut<'a>(frame: *mut LocusTermFrame) -> Option<&'a mut LocusTermFrame> {
    if frame.is_null() {
        set_last_error_message("frame must not be NULL");
        return None;
    }
    // SAFETY: the caller guarantees this is a live unique frame handle for the
    // duration of the synchronous FFI call.
    Some(unsafe { &mut *frame })
}

fn render_into_frame(term: &mut LocusTerm, frame: &mut LocusTermFrame, full: bool) {
    term.render_state.update(&mut term.stream.handler.terminal);
    frame.abi_version = LOCUS_TERM_ABI_VERSION;
    frame.cols = term.render_state.cols;
    frame.rows = term.render_state.rows;
    frame.dirty_state = dirty_state_code(term.render_state.dirty);
    frame.cursor = cursor_from_render(&term.render_state);
    let storage = frame.storage_mut();
    storage.row_storage.clear();
    storage.cell_storage.clear();
    storage.grapheme_storage.clear();

    let palette = &term.render_state.colors.palette;
    let default_fg = term.render_state.colors.foreground;
    let default_bg = term.render_state.colors.background;
    for (row_index, row) in term.render_state.row_data.iter().enumerate() {
        if !full && !row.dirty {
            continue;
        }
        let cell_start = storage.cell_storage.len();
        for cell in &row.cells {
            let grapheme_start = storage.grapheme_storage.len();
            storage
                .grapheme_storage
                .extend(cell.grapheme.iter().copied());
            let style = cell.style;
            storage.cell_storage.push(LocusTermCell {
                codepoint: cell.raw.codepoint(),
                raw: cell.raw.raw(),
                fg: style
                    .fg(FgOptions {
                        default: default_fg,
                        palette,
                        bold: None,
                    })
                    .into(),
                bg: style.bg(&cell.raw, palette).unwrap_or(default_bg).into(),
                flags: style_flags(style),
                wide: cell_wide_code(cell.raw.wide()),
                grapheme_start,
                grapheme_len: cell.grapheme.len(),
                hyperlink_id: cell.hyperlink.unwrap_or(0),
            });
        }
        storage.row_storage.push(LocusTermRow {
            y: row_index as u16,
            cell_start,
            cell_count: row.cells.len(),
            dirty: row.dirty,
            wrapped: row.raw.wrap(),
        });
    }
    frame.refresh_pointers();
}

fn cursor_from_render(render: &RenderState) -> LocusTermCursor {
    let Some(viewport) = render.cursor.viewport else {
        return LocusTermCursor {
            x: render.cursor.active.x,
            y: render.cursor.active.y as u16,
            visible: render.cursor.visible,
            blinking: render.cursor.blinking,
            wide_tail: false,
            style: cursor_style_code(render.cursor.visual_style),
        };
    };
    LocusTermCursor {
        x: viewport.coord.x,
        y: viewport.coord.y as u16,
        visible: render.cursor.visible,
        blinking: render.cursor.blinking,
        wide_tail: viewport.wide_tail,
        style: cursor_style_code(render.cursor.visual_style),
    }
}

fn dirty_state_code(dirty: DirtyState) -> u32 {
    match dirty {
        DirtyState::False => LOCUS_TERM_DIRTY_NONE,
        DirtyState::Partial => LOCUS_TERM_DIRTY_PARTIAL,
        DirtyState::Full => LOCUS_TERM_DIRTY_FULL,
    }
}

fn cursor_style_code(style: CursorStyle) -> u32 {
    match style {
        CursorStyle::Block => 1,
        CursorStyle::Underline => 2,
        CursorStyle::Bar => 3,
    }
}

fn style_flags(style: Style) -> u32 {
    let flags = style.flags;
    let mut result = 0u32;
    if flags.bold {
        result |= 1 << 0;
    }
    if flags.italic {
        result |= 1 << 1;
    }
    if flags.faint {
        result |= 1 << 2;
    }
    if flags.blink {
        result |= 1 << 3;
    }
    if flags.inverse {
        result |= 1 << 4;
    }
    if flags.invisible {
        result |= 1 << 5;
    }
    if flags.strikethrough {
        result |= 1 << 6;
    }
    if flags.overline {
        result |= 1 << 7;
    }
    if !matches!(flags.underline, terminal::sgr::Underline::None) {
        result |= 1 << 8;
    }
    result
}

fn cell_wide_code(wide: CellWide) -> u8 {
    match wide {
        CellWide::Narrow => 0,
        CellWide::Wide => 1,
        CellWide::SpacerHead => 2,
        CellWide::SpacerTail => 3,
    }
}

/// # Safety
///
/// `frame` must be a live frame returned by this module and not mutated while
/// this function reads its borrowed row/cell slices.
unsafe fn dump_frame(frame: *const LocusTermFrame, dump: TermReplayDump) -> String {
    if frame.is_null() {
        return String::new();
    }
    // SAFETY: caller guarantees `frame` is live for this synchronous read.
    let frame = unsafe { &*frame };
    if frame.row_count == 0 || frame.rows_ptr.is_null() || frame.cells_ptr.is_null() {
        return String::new();
    }
    // SAFETY: the frame owns these buffers and exposes valid pointer/count
    // pairs until the next render or free.
    let rows = unsafe { std::slice::from_raw_parts(frame.rows_ptr, frame.row_count) };
    // SAFETY: same ownership contract as rows above.
    let cells = unsafe { std::slice::from_raw_parts(frame.cells_ptr, frame.cell_count) };
    let mut out = String::new();
    for row in rows {
        if !out.is_empty() {
            out.push('\n');
        }
        let end = row
            .cell_start
            .saturating_add(row.cell_count)
            .min(cells.len());
        for cell in &cells[row.cell_start..end] {
            let ch = char::from_u32(cell.codepoint).unwrap_or(' ');
            out.push(if ch == '\0' { ' ' } else { ch });
        }
    }
    match dump {
        TermReplayDump::Plain => trim_terminal_dump(out),
        // The frame carries style metadata; a richer VT formatter can be
        // layered here without changing CLI parsing or FFI ownership.
        TermReplayDump::Vt => trim_terminal_dump(out),
    }
}

fn trim_terminal_dump(text: String) -> String {
    let mut lines: Vec<String> = text
        .lines()
        .map(|line| line.trim_end().to_string())
        .collect();
    while lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    lines.join("\n")
}

fn key_options(terminal: &Terminal) -> input::Options {
    input::Options {
        cursor_key_application: terminal.modes.get(Mode::CursorKeys),
        keypad_key_application: terminal.modes.get(Mode::KeypadKeys),
        backarrow_key_mode: terminal.modes.get(Mode::BackarrowKeyMode),
        ignore_keypad_with_numlock: terminal.modes.get(Mode::IgnoreKeypadWithNumlock),
        alt_esc_prefix: terminal.modes.get(Mode::AltEscPrefix)
            || terminal.modes.get(Mode::AltSendsEscape),
        modify_other_keys_state_2: terminal.flags.modify_other_keys_2,
        kitty_flags: terminal::input::KittyFlags::DISABLED,
        macos_option_as_alt: OptionAsAlt::False,
        is_macos: cfg!(target_os = "macos"),
    }
}

fn action_from_u32(action: u32) -> Action {
    match action {
        LOCUS_TERM_ACTION_RELEASE => Action::Release,
        LOCUS_TERM_ACTION_REPEAT => Action::Repeat,
        _ => Action::Press,
    }
}

fn key_from_u32(key: u32) -> Key {
    match key {
        LOCUS_TERM_KEY_ENTER => Key::Enter,
        LOCUS_TERM_KEY_BACKSPACE => Key::Backspace,
        LOCUS_TERM_KEY_TAB => Key::Tab,
        LOCUS_TERM_KEY_ESCAPE => Key::Escape,
        LOCUS_TERM_KEY_ARROW_UP => Key::ArrowUp,
        LOCUS_TERM_KEY_ARROW_DOWN => Key::ArrowDown,
        LOCUS_TERM_KEY_ARROW_LEFT => Key::ArrowLeft,
        LOCUS_TERM_KEY_ARROW_RIGHT => Key::ArrowRight,
        LOCUS_TERM_KEY_HOME => Key::Home,
        LOCUS_TERM_KEY_END => Key::End,
        LOCUS_TERM_KEY_PAGE_UP => Key::PageUp,
        LOCUS_TERM_KEY_PAGE_DOWN => Key::PageDown,
        LOCUS_TERM_KEY_DELETE => Key::Delete,
        LOCUS_TERM_KEY_INSERT => Key::Insert,
        LOCUS_TERM_KEY_F1 => Key::F1,
        LOCUS_TERM_KEY_F2 => Key::F2,
        LOCUS_TERM_KEY_F3 => Key::F3,
        LOCUS_TERM_KEY_F4 => Key::F4,
        LOCUS_TERM_KEY_F5 => Key::F5,
        LOCUS_TERM_KEY_F6 => Key::F6,
        LOCUS_TERM_KEY_F7 => Key::F7,
        LOCUS_TERM_KEY_F8 => Key::F8,
        LOCUS_TERM_KEY_F9 => Key::F9,
        LOCUS_TERM_KEY_F10 => Key::F10,
        LOCUS_TERM_KEY_F11 => Key::F11,
        LOCUS_TERM_KEY_F12 => Key::F12,
        _ => Key::Unidentified,
    }
}

fn mods_from_bits(bits: u16) -> Mods {
    Mods::from_bits(bits)
}

#[cfg(test)]
mod tests {
    use std::mem::{align_of, offset_of, size_of};

    use super::*;

    fn render_plain(term: *mut LocusTerm) -> String {
        let frame = locus_term_frame_new();
        assert!(!frame.is_null());
        unsafe {
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let frame_ref = &*frame;
            let rows = std::slice::from_raw_parts(frame_ref.rows_ptr, frame_ref.row_count);
            let cells = std::slice::from_raw_parts(frame_ref.cells_ptr, frame_ref.cell_count);
            let mut out = String::new();
            for row in rows {
                if !out.is_empty() {
                    out.push('\n');
                }
                let row_cells = &cells[row.cell_start..row.cell_start + row.cell_count];
                for cell in row_cells {
                    out.push(char::from_u32(cell.codepoint).unwrap_or(' '));
                }
            }
            locus_term_frame_free(frame);
            out
        }
    }

    fn new_term() -> *mut LocusTerm {
        let term = locus_term_new(12, 4, 1024);
        assert!(!term.is_null());
        term
    }

    #[test]
    fn abi_version_is_nonzero() {
        assert_eq!(locus_term_abi_version(), LOCUS_TERM_ABI_VERSION);
    }

    #[test]
    fn bytes_layout_is_stable() {
        assert_eq!(align_of::<LocusTermBytes>(), align_of::<usize>());
        assert_eq!(size_of::<LocusTermBytes>(), size_of::<usize>() * 3);
        assert_eq!(offset_of!(LocusTermBytes, ptr), 0);
        assert_eq!(offset_of!(LocusTermBytes, len), size_of::<usize>());
    }

    #[test]
    fn rgb_layout_is_stable() {
        assert_eq!(size_of::<LocusTermRgb>(), 3);
        assert_eq!(offset_of!(LocusTermRgb, r), 0);
        assert_eq!(offset_of!(LocusTermRgb, g), 1);
        assert_eq!(offset_of!(LocusTermRgb, b), 2);
    }

    #[test]
    fn cursor_layout_exposes_coordinates_first() {
        assert_eq!(offset_of!(LocusTermCursor, x), 0);
        assert_eq!(offset_of!(LocusTermCursor, y), 2);
        assert!(size_of::<LocusTermCursor>() >= 8);
    }

    #[test]
    fn cell_layout_starts_with_codepoint_and_raw() {
        assert_eq!(offset_of!(LocusTermCell, codepoint), 0);
        assert!(offset_of!(LocusTermCell, raw) >= 8);
        assert!(size_of::<LocusTermCell>() >= 48);
    }

    #[test]
    fn row_layout_starts_with_y() {
        assert_eq!(offset_of!(LocusTermRow, y), 0);
        assert!(size_of::<LocusTermRow>() >= 32);
    }

    #[test]
    fn key_event_layout_starts_with_action_and_key() {
        assert_eq!(offset_of!(LocusTermKeyEvent, action), 0);
        assert_eq!(offset_of!(LocusTermKeyEvent, key), 4);
    }

    #[test]
    fn frame_prefix_layout_exposes_version_first() {
        assert_eq!(offset_of!(LocusTermFrame, abi_version), 0);
        assert!(offset_of!(LocusTermFrame, rows_ptr) > offset_of!(LocusTermFrame, row_count));
    }

    #[test]
    fn new_rejects_zero_dimensions() {
        assert!(locus_term_new(0, 24, 0).is_null());
        assert!(locus_term_new(80, 0, 0).is_null());
    }

    #[test]
    fn free_accepts_null() {
        unsafe {
            locus_term_free(ptr::null_mut());
            locus_term_frame_free(ptr::null_mut());
            locus_term_bytes_free(ptr::null_mut());
        }
    }

    #[test]
    fn feed_null_term_is_invalid() {
        unsafe {
            assert_eq!(
                locus_term_feed(ptr::null_mut(), ptr::null(), 0),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
        }
    }

    #[test]
    fn feed_zero_len_null_bytes_is_ok() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_feed(term, ptr::null(), 0), LOCUS_STATUS_OK);
            locus_term_free(term);
        }
    }

    #[test]
    fn feed_nonzero_null_bytes_is_invalid() {
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_feed(term, ptr::null(), 1),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn render_shows_fed_text() {
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"hello".as_ptr(), b"hello".len()),
                LOCUS_STATUS_OK
            );
            assert!(render_plain(term).contains("hello"));
            locus_term_free(term);
        }
    }

    #[test]
    fn render_dirty_only_becomes_empty_after_full_render() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_eq!((*frame).row_count, 0);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn render_reuses_frame_storage() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let first_cells = (*frame).cells_ptr;
            assert_eq!(locus_term_feed(term, b"x".as_ptr(), 1), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert_eq!((*frame).cells_ptr, first_cells);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn resize_one_by_one_does_not_panic() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_resize(term, 1, 1), LOCUS_STATUS_OK);
            let frame = locus_term_frame_new();
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert_eq!((*frame).cols, 1);
            assert_eq!((*frame).rows, 1);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn resize_zero_is_invalid() {
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_resize(term, 0, 1),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_resize(term, 1, 0),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn responses_are_drained() {
        let term = new_term();
        let mut bytes = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"\x1b[6n".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_take_responses(term, &mut bytes), LOCUS_STATUS_OK);
            assert!(bytes.len > 0);
            locus_term_bytes_free(&mut bytes);
            assert_eq!(locus_term_take_responses(term, &mut bytes), LOCUS_STATUS_OK);
            assert_eq!(bytes.len, 0);
            locus_term_bytes_free(&mut bytes);
            locus_term_free(term);
        }
    }

    #[test]
    fn bytes_free_is_idempotent_for_same_struct() {
        let mut bytes = bytes_from_vec(b"abc".to_vec());
        unsafe {
            locus_term_bytes_free(&mut bytes);
            locus_term_bytes_free(&mut bytes);
        }
        assert!(bytes.ptr.is_null());
    }

    #[test]
    fn key_enter_encodes_carriage_return() {
        let term = new_term();
        let event = LocusTermKeyEvent {
            action: LOCUS_TERM_ACTION_PRESS,
            key: LOCUS_TERM_KEY_ENTER,
            ..LocusTermKeyEvent::default()
        };
        let mut bytes = LocusTermBytes::default();
        unsafe {
            assert_eq!(locus_term_key(term, &event, &mut bytes), LOCUS_STATUS_OK);
            assert_eq!(std::slice::from_raw_parts(bytes.ptr, bytes.len), b"\r");
            locus_term_bytes_free(&mut bytes);
            locus_term_free(term);
        }
    }

    #[test]
    fn key_printable_utf8_passes_through() {
        let term = new_term();
        let event = LocusTermKeyEvent {
            action: LOCUS_TERM_ACTION_PRESS,
            utf8: b"a".as_ptr(),
            utf8_len: 1,
            ..LocusTermKeyEvent::default()
        };
        let mut bytes = LocusTermBytes::default();
        unsafe {
            assert_eq!(locus_term_key(term, &event, &mut bytes), LOCUS_STATUS_OK);
            assert_eq!(std::slice::from_raw_parts(bytes.ptr, bytes.len), b"a");
            locus_term_bytes_free(&mut bytes);
            locus_term_free(term);
        }
    }

    #[test]
    fn paste_rejects_newline() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_paste(term, b"a\nb".as_ptr(), 3, &mut out),
                LOCUS_TERM_STATUS_UNSAFE_PASTE
            );
            assert!(out.ptr.is_null());
            locus_term_free(term);
        }
    }

    #[test]
    fn paste_encodes_safe_text() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_paste(term, b"paste".as_ptr(), 5, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(std::slice::from_raw_parts(out.ptr, out.len), b"paste");
            locus_term_bytes_free(&mut out);
            locus_term_free(term);
        }
    }

    #[test]
    fn paste_wraps_when_bracketed_mode_is_set() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"\x1b[?2004h".as_ptr(), 8),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_paste(term, b"paste".as_ptr(), 5, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                std::slice::from_raw_parts(out.ptr, out.len),
                b"\x1b[200~paste\x1b[201~"
            );
            locus_term_bytes_free(&mut out);
            locus_term_free(term);
        }
    }

    #[test]
    fn scroll_accepts_large_delta() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_scroll(term, -1000), LOCUS_STATUS_OK);
            assert_eq!(locus_term_scroll(term, 1000), LOCUS_STATUS_OK);
            locus_term_free(term);
        }
    }

    #[test]
    fn truncated_escape_is_deterministic() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_feed(term, b"\x1b[".as_ptr(), 2), LOCUS_STATUS_OK);
            assert_eq!(locus_term_feed(term, b"A".as_ptr(), 1), LOCUS_STATUS_OK);
            locus_term_free(term);
        }
    }

    #[test]
    fn random_control_bytes_do_not_panic() {
        let term = new_term();
        let data = [0, 1, 2, 3, 0x1b, b'[', b'9', b'9', b'9', b'Z'];
        unsafe {
            assert_eq!(
                locus_term_feed(term, data.as_ptr(), data.len()),
                LOCUS_STATUS_OK
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn frame_render_rejects_nulls() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(
                locus_term_render(ptr::null_mut(), frame, true),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_render(term, ptr::null_mut(), true),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn key_rejects_nulls() {
        let term = new_term();
        let event = LocusTermKeyEvent::default();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_key(ptr::null_mut(), &event, &mut out),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_key(term, ptr::null(), &mut out),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_key(term, &event, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            locus_term_free(term);
        }
    }
}
