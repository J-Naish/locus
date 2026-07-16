//! C ABI for the terminal emulator core.
//!
//! The ABI owns a parser-backed terminal stream plus a reusable render frame.
//! Callers feed PTY bytes, render the current viewport into a stable C view,
//! and copy any response bytes before freeing the Rust-owned buffers.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::time::{Duration, Instant};

use terminal::color::Rgb;
use terminal::formatter::{Format, TerminalFormatter};
use terminal::input::mouse_encode::{
    self, Action as MouseAction, Button as MouseButton, Event as MouseInputEvent,
};
use terminal::input::{self, Action, Key, KeyEvent, Mods, OptionAsAlt};
use terminal::modes::Mode;
use terminal::page::CellWide;
use terminal::page_list::{Pin, Scroll};
use terminal::point::{Coordinate, Point, Tag};
use terminal::render::{DirtyState, RenderState};
use terminal::screen::{CursorStyle, SelectionStringOptions};
use terminal::screen_set::ScreenKey;
use terminal::search::{ScreenSearch, Select, ViewportSearch};
use terminal::selection_codepoints::DEFAULT_WORD_BOUNDARIES;
use terminal::selection_gesture::{
    Autoscroll, AutoscrollTick, Behavior as SelectionBehavior, Drag as SelectionDrag,
    Geometry as SelectionGeometry, Press as SelectionPress, Release as SelectionRelease,
    SelectionGesture, Time as SelectionTime,
};
use terminal::stream::Stream;
use terminal::stream_terminal::{Effects, TerminalHandler};
use terminal::style::{FgOptions, Style};
use terminal::terminal::{Options as TerminalOptions, Terminal};
use terminal::url;

use crate::{clear_last_error_message, set_last_error_message, LOCUS_STATUS_OK};

pub const LOCUS_TERM_ABI_VERSION: u32 = 4;
const SYNCHRONIZED_OUTPUT_TIMEOUT: Duration = Duration::from_millis(150);
const MAX_WHEEL_ROWS_PER_EVENT: u32 = 4_096;
const SELECTION_CELL_WIDTH: f64 = 10.0;
const SELECTION_BEHAVIORS: [SelectionBehavior; 3] = [
    SelectionBehavior::Cell,
    SelectionBehavior::Word,
    SelectionBehavior::Line,
];
pub const LOCUS_TERM_SEARCH_MAX_NEEDLE_BYTES: usize = 1_024;
const SEARCH_MATCHES_PER_VIEWPORT_ROW_LIMIT: usize = 64;
/// Clipboard writes are bounded to prevent untrusted terminal output from
/// allocating an unbounded pasteboard payload.
const OSC52_MAX_DECODED_BYTES: usize = 1 << 20;
const OSC52_MAX_ENCODED_BYTES: usize = OSC52_MAX_DECODED_BYTES * 4 / 3 + 4;

pub const LOCUS_TERM_STATUS_INVALID_ARGUMENT: u32 = 300;
pub const LOCUS_TERM_STATUS_PANIC: u32 = 301;
pub const LOCUS_TERM_STATUS_UNSAFE_PASTE: u32 = 302;

pub const LOCUS_TERM_SEARCH_SELECT_NEXT: u32 = 0;
pub const LOCUS_TERM_SEARCH_SELECT_PREV: u32 = 1;
pub const LOCUS_TERM_SEARCH_NO_SELECTION: u32 = u32::MAX;
pub const LOCUS_TERM_SEARCH_MATCH_SELECTED: u16 = 1 << 0;

/// Upper bounds for terminal dimensions accepted over the ABI. These are
/// generous for real displays while keeping hostile sizes from allocating
/// billions of cells.
pub const LOCUS_TERM_MAX_COLS: u16 = 4096;
pub const LOCUS_TERM_MAX_ROWS: u16 = 4096;
/// Upper bound for the scrollback budget accepted over the ABI.
pub const LOCUS_TERM_MAX_SCROLLBACK: usize = 256 * 1024 * 1024;

pub const LOCUS_TERM_DIRTY_NONE: u32 = 0;
pub const LOCUS_TERM_DIRTY_PARTIAL: u32 = 1;
pub const LOCUS_TERM_DIRTY_FULL: u32 = 2;

pub const LOCUS_TERM_ACTION_RELEASE: u32 = 0;
pub const LOCUS_TERM_ACTION_PRESS: u32 = 1;
pub const LOCUS_TERM_ACTION_REPEAT: u32 = 2;

pub const LOCUS_TERM_SELECTION_PRESS: u32 = 0;
pub const LOCUS_TERM_SELECTION_DRAG: u32 = 1;
pub const LOCUS_TERM_SELECTION_RELEASE: u32 = 2;
pub const LOCUS_TERM_SELECTION_PRESS_REPEAT: u32 = 3;

pub const LOCUS_TERM_MOUSE_PRESS: u32 = 0;
pub const LOCUS_TERM_MOUSE_RELEASE: u32 = 1;
pub const LOCUS_TERM_MOUSE_MOTION: u32 = 2;
pub const LOCUS_TERM_MOUSE_BUTTON_LEFT: u32 = 0;
pub const LOCUS_TERM_MOUSE_BUTTON_MIDDLE: u32 = 1;
pub const LOCUS_TERM_MOUSE_BUTTON_RIGHT: u32 = 2;
pub const LOCUS_TERM_MOUSE_BUTTON_WHEEL_UP: u32 = 3;
pub const LOCUS_TERM_MOUSE_BUTTON_WHEEL_DOWN: u32 = 4;
pub const LOCUS_TERM_MOUSE_BUTTON_WHEEL_LEFT: u32 = 5;
pub const LOCUS_TERM_MOUSE_BUTTON_WHEEL_RIGHT: u32 = 6;
pub const LOCUS_TERM_MOUSE_BUTTON_NONE: u32 = u32::MAX;

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
pub const LOCUS_TERM_KEY_F13: u32 = 113;
pub const LOCUS_TERM_KEY_F14: u32 = 114;
pub const LOCUS_TERM_KEY_F15: u32 = 115;
pub const LOCUS_TERM_KEY_F16: u32 = 116;
pub const LOCUS_TERM_KEY_F17: u32 = 117;
pub const LOCUS_TERM_KEY_F18: u32 = 118;
pub const LOCUS_TERM_KEY_F19: u32 = 119;
pub const LOCUS_TERM_KEY_F20: u32 = 120;

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
    pub sel_start: u16,
    pub sel_end: u16,
}

/// Reusable Rust-owned render frame. Public fields form the C-readable prefix;
/// private buffers keep the pointed-to memory alive until the next render/free.
#[repr(C)]
pub struct LocusTermFrame {
    pub abi_version: u32,
    pub cols: u16,
    pub rows: u16,
    pub dirty_state: u32,
    pub scroll_delta: i32,
    pub viewport_offset_rows: u32,
    pub total_rows: u32,
    pub at_bottom: bool,
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
            scroll_delta: 0,
            viewport_offset_rows: 0,
            total_rows: 0,
            at_bottom: true,
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

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermSearchStatus {
    pub active: bool,
    pub complete: bool,
    pub total: u32,
    pub selected: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermSearchMatch {
    pub y: u16,
    pub x_start: u16,
    pub x_end: u16,
    pub flags: u16,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocusTermLinkMatch {
    pub y: u16,
    pub x_start: u16,
    pub x_end: u16,
    pub link_id: u16,
}

struct LocusTermSearch {
    screen_key: ScreenKey,
    screen: ScreenSearch,
    viewport: ViewportSearch,
}

pub struct LocusTerm {
    stream: Stream<TerminalHandler<FfiEffects>>,
    render_state: RenderState,
    selection_gesture: SelectionGesture,
    selection_clock: u64,
    last_mouse_cell: Option<Coordinate>,
    synchronized_output_started_at: Option<Instant>,
    // Search pins belong to screens inside the terminal. Plain handle drop is
    // safe because those screens and all pin storage are destroyed together.
    search: Option<LocusTermSearch>,
    // Link IDs are indices into this per-query snapshot and remain valid only
    // until the next viewport-links scan.
    last_viewport_links: Vec<String>,
}

impl LocusTerm {
    #[cfg(test)]
    fn expire_synchronized_output_for_test(&mut self) {
        self.synchronized_output_started_at = Some(Instant::now() - SYNCHRONIZED_OUTPUT_TIMEOUT);
    }

    #[cfg(test)]
    fn age_synchronized_output_for_test(&mut self, duration: Duration) {
        self.synchronized_output_started_at = self
            .synchronized_output_started_at
            .and_then(|started| started.checked_sub(duration));
    }
}

#[derive(Debug, Default)]
struct FfiEffects {
    pty: Vec<u8>,
    clipboard_write: Option<Vec<u8>>,
    latest_title: Option<String>,
    latest_pwd: Option<String>,
    latest_mouse_shape: Option<String>,
}

impl Effects for FfiEffects {
    fn write_pty(&mut self, bytes: &[u8]) {
        self.pty.extend_from_slice(bytes);
    }

    fn clipboard_contents(&mut self, kind: u8, data: &[u8]) {
        if kind != b'c' || data == b"?" || data.len() > OSC52_MAX_ENCODED_BYTES {
            return;
        }
        let Some(decoded) = decode_osc52_base64(data) else {
            return;
        };
        if decoded.len() <= OSC52_MAX_DECODED_BYTES {
            self.clipboard_write = Some(decoded);
        }
    }

    fn title_changed(&mut self, title: Option<&str>) {
        self.latest_title = title.map(ToOwned::to_owned);
    }

    fn pwd_changed(&mut self, pwd: Option<&str>) {
        self.latest_pwd = pwd.map(ToOwned::to_owned);
    }

    fn mouse_shape_changed(&mut self, shape: Option<&str>) {
        self.latest_mouse_shape = shape.map(ToOwned::to_owned);
    }
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

    // SAFETY: both handles are live and immutable for this synchronous read.
    let text = unsafe { dump_frame(&*term, frame, dump) };
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

/// Reports the active keyboard protocol without changing the frame ABI.
/// Bit 0 is xterm modifyOtherKeys state 2; bit 1 is any active kitty flag.
///
/// # Safety
///
/// `term` must be NULL or a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_key_protocol_active(term: *const LocusTerm) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        if term.is_null() {
            return 0;
        }
        // SAFETY: the caller guarantees a live handle for this synchronous read.
        let term = unsafe { &*term };
        let terminal = &term.stream.handler.terminal;
        let mut result = u32::from(terminal.flags.modify_other_keys_2);
        if terminal.active_screen().kitty_keyboard.current().int() != 0 {
            result |= 1 << 1;
        }
        result
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn locus_term_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut LocusTerm {
    match catch_unwind(AssertUnwindSafe(|| {
        clear_last_error_message();
        if !validate_terminal_dimensions(cols, rows)
            || !validate_terminal_scrollback(max_scrollback)
        {
            return ptr::null_mut();
        }
        let terminal = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback,
            width_px: 0,
            height_px: 0,
        });
        let stream = Stream::new(TerminalHandler::new(terminal, FfiEffects::default()));
        let render_state = RenderState::new(rows, cols);
        Box::into_raw(Box::new(LocusTerm {
            stream,
            render_state,
            selection_gesture: SelectionGesture::new(),
            selection_clock: 0,
            last_mouse_cell: None,
            synchronized_output_started_at: None,
            search: None,
            last_viewport_links: Vec::new(),
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
        let synchronized_output_epoch = term.stream.handler.terminal.synchronized_output_epoch();
        term.stream.next_slice(bytes);
        let terminal = &term.stream.handler.terminal;
        let is_synchronized = terminal.modes.get(Mode::SynchronizedOutput);
        if !is_synchronized {
            term.synchronized_output_started_at = None;
        } else if terminal.synchronized_output_epoch() != synchronized_output_epoch {
            term.synchronized_output_started_at = Some(Instant::now());
        }
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

/// Copies out and clears the most recent honored OSC 52 clipboard write.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_take_clipboard_write(
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
        let bytes = term
            .stream
            .handler
            .effects
            .clipboard_write
            .take()
            .unwrap_or_default();
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
        if !validate_terminal_dimensions(cols, rows) {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        // ghostty: termio/Termio.zig:490-492 -- resize must not leave a
        // renderer blocked behind synchronized output.
        term.stream
            .handler
            .terminal
            .reset_mode(Mode::SynchronizedOutput);
        term.synchronized_output_started_at = None;
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
        if synchronized_output_blocks_render(term) {
            frame.abi_version = LOCUS_TERM_ABI_VERSION;
            frame.cols = term.stream.handler.terminal.cols;
            frame.rows = term.stream.handler.terminal.rows;
            frame.dirty_state = LOCUS_TERM_DIRTY_NONE;
            frame.scroll_delta = 0;
            update_viewport_metadata(term, frame);
            return LOCUS_STATUS_OK;
        }
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
    allow_unsafe: bool,
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
        let bracketed = term.stream.handler.terminal.modes.get(Mode::BracketedPaste);
        // Bracketed paste is safe by construction: encode replaces every ESC
        // byte, so an embedded end sentinel cannot survive in the payload.
        // Unbracketed multiline paste can execute each line and therefore
        // requires explicit caller confirmation. This deliberately improves
        // on the pre-R1 port, which rejected all unsafe paste permanently.
        if !bracketed && !allow_unsafe && !input::paste::is_safe(bytes) {
            set_last_error_message("paste contains unsafe control or newline data");
            return LOCUS_TERM_STATUS_UNSAFE_PASTE;
        }
        let mut owned = bytes.to_vec();
        let encoded = input::paste::encode(&mut owned, input::paste::Options { bracketed });
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

/// Applies a local text-selection gesture using viewport cell coordinates.
///
/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_selection_gesture(
    term: *mut LocusTerm,
    kind: u32,
    x: u16,
    y: u16,
    cell_fraction_x: f32,
    rectangle: bool,
) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if !valid_cell_fraction(cell_fraction_x) {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let LocusTerm {
            stream,
            selection_gesture,
            selection_clock,
            ..
        } = term;
        let terminal = &mut stream.handler.terminal;
        let Some(pin) = viewport_pin(terminal, x, y) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let xpos = (f64::from(x) + f64::from(cell_fraction_x)) * SELECTION_CELL_WIDTH;
        let ypos = f64::from(y) + 0.5;
        let geometry = selection_geometry(terminal);
        match kind {
            LOCUS_TERM_SELECTION_PRESS => {
                selection_gesture.reset(terminal);
                *selection_clock = selection_clock.wrapping_add(2);
                selection_gesture.press(
                    terminal,
                    SelectionPress {
                        time: Some(SelectionTime(*selection_clock)),
                        pin,
                        xpos,
                        ypos,
                        max_distance: f64::MAX,
                        repeat_interval: 1,
                        word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                        behaviors: &SELECTION_BEHAVIORS,
                    },
                );
            }
            LOCUS_TERM_SELECTION_DRAG => {
                selection_gesture.drag(
                    terminal,
                    SelectionDrag {
                        pin: Some(pin),
                        xpos,
                        ypos,
                        rectangle,
                        word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                        geometry,
                    },
                );
            }
            LOCUS_TERM_SELECTION_RELEASE => {
                selection_gesture.release(terminal, SelectionRelease { pin: Some(pin) });
            }
            LOCUS_TERM_SELECTION_PRESS_REPEAT => {
                *selection_clock = selection_clock.wrapping_add(1);
                selection_gesture.press(
                    terminal,
                    SelectionPress {
                        time: Some(SelectionTime(*selection_clock)),
                        pin,
                        xpos,
                        ypos,
                        max_distance: f64::MAX,
                        repeat_interval: 1,
                        word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                        behaviors: &SELECTION_BEHAVIORS,
                    },
                );
            }
            _ => return LOCUS_TERM_STATUS_INVALID_ARGUMENT,
        }
        LOCUS_STATUS_OK
    })
}

/// Clears both the active selection and any in-progress gesture.
///
/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_selection_clear(term: *mut LocusTerm) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let LocusTerm {
            stream,
            selection_gesture,
            ..
        } = term;
        let terminal = &mut stream.handler.terminal;
        selection_gesture.reset(terminal);
        terminal.active_screen_mut().clear_selection();
        LOCUS_STATUS_OK
    })
}

/// Copies the active selection as UTF-8 text.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_selection_string(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let screen = term.stream.handler.terminal.active_screen();
        let text = screen.selection.map_or_else(String::new, |selection| {
            screen.selection_string(SelectionStringOptions {
                selection,
                trim: true,
            })
        });
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(text.into_bytes()) };
        LOCUS_STATUS_OK
    })
}

/// Copies the most recent window title into `out`; empty when unset.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_latest_title(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let bytes = term
            .stream
            .handler
            .terminal
            .title()
            .map_or_else(Vec::new, |title| title.to_owned().into_bytes());
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Copies the most recent OSC 7 working-directory report verbatim into `out`.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_latest_pwd(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let bytes = term
            .stream
            .handler
            .terminal
            .pwd()
            .map_or_else(Vec::new, |pwd| pwd.to_owned().into_bytes());
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Advances a selection gesture while the pointer remains beyond a viewport edge.
///
/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_autoscroll_tick(
    term: *mut LocusTerm,
    direction: i32,
    x: u16,
    cell_fraction_x: f32,
    rectangle: bool,
) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if direction == 0 || !valid_cell_fraction(cell_fraction_x) {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let LocusTerm {
            stream,
            selection_gesture,
            ..
        } = term;
        if selection_gesture.count() == 0 {
            return LOCUS_STATUS_OK;
        }
        let terminal = &mut stream.handler.terminal;
        if x >= terminal.cols {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let down = direction > 0;
        selection_gesture.set_autoscroll(if down {
            Autoscroll::Down
        } else {
            Autoscroll::Up
        });
        let viewport = Coordinate {
            x,
            y: if down {
                u32::from(terminal.rows.saturating_sub(1))
            } else {
                0
            },
        };
        let geometry = selection_geometry(terminal);
        selection_gesture.autoscroll_tick(
            terminal,
            AutoscrollTick {
                viewport,
                xpos: (f64::from(x) + f64::from(cell_fraction_x)) * SELECTION_CELL_WIDTH,
                ypos: if down { geometry.screen_height } else { 0.0 },
                rectangle,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry,
            },
        );
        LOCUS_STATUS_OK
    })
}

/// Encodes a mouse event according to the terminal's active reporting modes.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_mouse(
    term: *mut LocusTerm,
    kind: u32,
    button: u32,
    x: u16,
    y: u16,
    mods: u16,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Some(action) = mouse_action(kind) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Some(button) = mouse_button(button) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let terminal = &mut term.stream.handler.terminal;
        if x >= terminal.cols || y >= terminal.rows {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        if mods & LOCUS_TERM_MOD_SHIFT != 0 && !terminal.flags.mouse_shift_capture {
            return LOCUS_STATUS_OK;
        }
        let mode = terminal.flags.mouse_event;
        let format = terminal.flags.mouse_format;
        if action == MouseAction::Motion
            && format != terminal::terminal::MouseFormat::SgrPixels
            && term.last_mouse_cell == Some(Coordinate { x, y: u32::from(y) })
        {
            return LOCUS_STATUS_OK;
        }
        let bytes = mouse_encode::encode(
            MouseInputEvent {
                action,
                button,
                mods: mods_from_bits(mods),
                x,
                y,
            },
            mode,
            format,
        );
        if !bytes.is_empty() {
            terminal.active_screen_mut().clear_selection();
            term.selection_gesture.reset(terminal);
            term.last_mouse_cell = Some(Coordinate { x, y: u32::from(y) });
        }
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Applies wheel policy: mouse reports, alternate-scroll arrows, or local scrollback.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_scroll_wheel(
    term: *mut LocusTerm,
    delta_rows: i32,
    x: u16,
    y: u16,
    mods: u16,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if delta_rows.unsigned_abs() > MAX_WHEEL_ROWS_PER_EVENT {
            set_last_error_message("wheel delta is too large");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let terminal = &mut term.stream.handler.terminal;
        if x >= terminal.cols || y >= terminal.rows {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        if mods & LOCUS_TERM_MOD_SHIFT != 0 && !terminal.flags.mouse_shift_capture {
            return LOCUS_STATUS_OK;
        }
        let mut bytes = Vec::new();
        if terminal.flags.mouse_event != terminal::terminal::MouseEvent::None {
            let button = if delta_rows < 0 {
                MouseButton::Four
            } else {
                MouseButton::Five
            };
            for _ in 0..delta_rows.unsigned_abs() {
                bytes.extend(mouse_encode::encode(
                    MouseInputEvent {
                        action: MouseAction::Press,
                        button: Some(button),
                        mods: mods_from_bits(mods),
                        x,
                        y,
                    },
                    terminal.flags.mouse_event,
                    terminal.flags.mouse_format,
                ));
            }
        } else if terminal.screens.active_key() == ScreenKey::Alternate
            && terminal.modes.get(Mode::MouseAlternateScroll)
        {
            let sequence: &[u8] = match (delta_rows < 0, terminal.modes.get(Mode::CursorKeys)) {
                (true, true) => b"\x1bOA",
                (true, false) => b"\x1b[A",
                (false, true) => b"\x1bOB",
                (false, false) => b"\x1b[B",
            };
            for _ in 0..delta_rows.unsigned_abs() {
                bytes.extend_from_slice(sequence);
            }
        } else if terminal.screens.active_key() == ScreenKey::Primary {
            terminal.scroll_viewport(Scroll::DeltaRow(delta_rows as isize));
        }
        if !bytes.is_empty() {
            terminal.active_screen_mut().clear_selection();
            term.selection_gesture.reset(terminal);
        }
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Starts a synchronous search on the currently active terminal screen.
///
/// # Safety
///
/// `term` must be a live terminal handle. `needle` must point to `len`
/// readable bytes, or may be NULL when `len == 0`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_search_start(
    term: *mut LocusTerm,
    needle: *const u8,
    len: usize,
) -> u32 {
    term_status(|| {
        let Some(needle) = bytes_slice(needle, len) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if needle.is_empty() || needle.len() > LOCUS_TERM_SEARCH_MAX_NEEDLE_BYTES {
            set_last_error_message("search needle must contain 1 to 1024 bytes");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };

        search_end_internal(term);
        let terminal = &mut term.stream.handler.terminal;
        let screen_key = terminal.screens.active_key();
        let Some(screen) = terminal.screens.get_mut(screen_key) else {
            set_last_error_message("active terminal screen is unavailable");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let Ok(mut screen_search) = ScreenSearch::new(screen, needle) else {
            set_last_error_message("terminal search could not be initialized");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        if screen_search.search_all(screen).is_err() {
            screen_search.deinit(screen);
            set_last_error_message("terminal search could not scan the screen");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        term.search = Some(LocusTermSearch {
            screen_key,
            screen: screen_search,
            viewport: ViewportSearch::new(needle),
        });
        LOCUS_STATUS_OK
    })
}

/// Ends the current terminal search. Calling this without a search is valid.
///
/// # Safety
///
/// `term` must be a live terminal handle.
#[no_mangle]
pub unsafe extern "C" fn locus_term_search_end(term: *mut LocusTerm) -> u32 {
    term_status(|| {
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        search_end_internal(term);
        LOCUS_STATUS_OK
    })
}

/// Reads the current terminal search status.
///
/// # Safety
///
/// `term` must be a live terminal handle and `out` must point to writable
/// storage for one `LocusTermSearchStatus`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_search_status(
    term: *mut LocusTerm,
    out: *mut LocusTermSearchStatus,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermSearchStatus::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        search_refresh(term);
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = search_status_value(term) };
        LOCUS_STATUS_OK
    })
}

/// Selects the next older or previous newer search match and scrolls it into
/// view.
///
/// # Safety
///
/// `term` must be a live terminal handle and `out` must point to writable
/// storage for one `LocusTermSearchStatus`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_search_select(
    term: *mut LocusTerm,
    direction: u32,
    out: *mut LocusTermSearchStatus,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermSearchStatus::default() };
        let direction = match direction {
            LOCUS_TERM_SEARCH_SELECT_NEXT => Select::Next,
            LOCUS_TERM_SEARCH_SELECT_PREV => Select::Prev,
            _ => {
                set_last_error_message("unknown search selection direction");
                return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
            }
        };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        search_refresh(term);
        let active_key = term.stream.handler.terminal.screens.active_key();
        if term.search.as_ref().map(|search| search.screen_key) != Some(active_key) {
            return LOCUS_STATUS_OK;
        }

        let Some(mut search) = term.search.take() else {
            return LOCUS_STATUS_OK;
        };
        let terminal = &mut term.stream.handler.terminal;
        let Some(screen) = terminal.screens.get_mut(search.screen_key) else {
            return LOCUS_STATUS_OK;
        };
        if search.screen.select(screen, direction).is_err() {
            search.screen.deinit(screen);
            return LOCUS_STATUS_OK;
        }
        if let Some((start, _)) = search.screen.selected_match().and_then(search_match_pins) {
            screen.pages.scroll(Scroll::Pin(start));
        }
        term.search = Some(search);
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = search_status_value(term) };
        LOCUS_STATUS_OK
    })
}

/// Returns packed `LocusTermSearchMatch` records for visible match rows.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_search_viewport_matches(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        search_refresh(term);
        let active_key = term.stream.handler.terminal.screens.active_key();
        if term.search.as_ref().map(|search| search.screen_key) != Some(active_key) {
            return LOCUS_STATUS_OK;
        }

        let Some(mut search) = term.search.take() else {
            return LOCUS_STATUS_OK;
        };
        let terminal = &mut term.stream.handler.terminal;
        let Some(screen) = terminal.screens.get_mut(search.screen_key) else {
            return LOCUS_STATUS_OK;
        };

        // The ABI returns a complete snapshot rather than a change signal, so
        // rebuild an exhausted viewport iterator even when its fingerprint is
        // unchanged from the preceding call.
        search.viewport.reset();
        if search.viewport.update(&screen.pages).is_err() {
            search.screen.deinit(screen);
            return LOCUS_STATUS_OK;
        }
        let selected = search.screen.selected_match().and_then(search_match_pins);
        let mut matches = Vec::new();
        while let Some(found) = search.viewport.next(&screen.pages) {
            append_viewport_search_rows(&screen.pages, &found, selected, &mut matches);
        }
        let limit = usize::from(screen.pages.rows) * SEARCH_MATCHES_PER_VIEWPORT_ROW_LIMIT;
        matches.sort_unstable_by_key(|item| (item.y, item.x_start));
        matches.truncate(limit);
        term.search = Some(search);

        let mut bytes = Vec::with_capacity(matches.len() * size_of::<LocusTermSearchMatch>());
        for item in matches {
            bytes.extend_from_slice(&item.y.to_ne_bytes());
            bytes.extend_from_slice(&item.x_start.to_ne_bytes());
            bytes.extend_from_slice(&item.x_end.to_ne_bytes());
            bytes.extend_from_slice(&item.flags.to_ne_bytes());
        }
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Returns packed `LocusTermLinkMatch` records for visible link rows.
///
/// Link IDs index the URI snapshot retained until the next call to this
/// function.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_viewport_links(
    term: *mut LocusTerm,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };

        term.last_viewport_links.clear();
        let screen = term.stream.handler.terminal.active_screen();
        let links = url::viewport_links(screen);
        let mut matches = Vec::new();
        for link in links {
            let Ok(link_id) = u16::try_from(term.last_viewport_links.len()) else {
                break;
            };
            append_viewport_link_rows(&screen.pages, link.selection, link_id, &mut matches);
            term.last_viewport_links.push(link.uri);
        }
        let limit = usize::from(screen.pages.rows) * SEARCH_MATCHES_PER_VIEWPORT_ROW_LIMIT;
        matches.sort_unstable_by_key(|item| (item.y, item.x_start));
        matches.truncate(limit);

        let mut bytes = Vec::with_capacity(matches.len() * size_of::<LocusTermLinkMatch>());
        for item in matches {
            bytes.extend_from_slice(&item.y.to_ne_bytes());
            bytes.extend_from_slice(&item.x_start.to_ne_bytes());
            bytes.extend_from_slice(&item.x_end.to_ne_bytes());
            bytes.extend_from_slice(&item.link_id.to_ne_bytes());
        }
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
        LOCUS_STATUS_OK
    })
}

/// Copies the URI associated with a link ID from the last viewport scan.
///
/// # Safety
///
/// `term` must be a live terminal handle. `out` must point to writable storage
/// for a `LocusTermBytes`, later freed with `locus_term_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_term_link_uri(
    term: *mut LocusTerm,
    link_id: u32,
    out: *mut LocusTermBytes,
) -> u32 {
    term_status(|| {
        if out.is_null() {
            set_last_error_message("out must not be NULL");
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: `out` is non-null and caller-provided writable storage.
        unsafe { *out = LocusTermBytes::default() };
        let Some(term) = term_mut(term) else {
            return LOCUS_TERM_STATUS_INVALID_ARGUMENT;
        };
        let bytes = usize::try_from(link_id)
            .ok()
            .and_then(|index| term.last_viewport_links.get(index))
            .map_or_else(Vec::new, |uri| uri.as_bytes().to_vec());
        // SAFETY: `out` remains valid for this synchronous call.
        unsafe { *out = bytes_from_vec(bytes) };
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

fn search_end_internal(term: &mut LocusTerm) {
    let Some(mut search) = term.search.take() else {
        return;
    };
    if let Some(screen) = term
        .stream
        .handler
        .terminal
        .screens
        .get_mut(search.screen_key)
    {
        search.screen.deinit(screen);
    }
}

fn search_refresh(term: &mut LocusTerm) {
    let Some(screen_key) = term.search.as_ref().map(|search| search.screen_key) else {
        return;
    };
    let terminal = &mut term.stream.handler.terminal;
    if terminal.screens.active_key() != screen_key {
        return;
    }
    let Some(mut search) = term.search.take() else {
        return;
    };
    let Some(screen) = terminal.screens.get_mut(screen_key) else {
        return;
    };
    if search.screen.reload_active(screen).is_err() || search.screen.search_all(screen).is_err() {
        search.screen.deinit(screen);
        return;
    }
    term.search = Some(search);
}

fn search_status_value(term: &LocusTerm) -> LocusTermSearchStatus {
    let active_key = term.stream.handler.terminal.screens.active_key();
    let Some(search) = term
        .search
        .as_ref()
        .filter(|search| search.screen_key == active_key)
    else {
        return LocusTermSearchStatus::default();
    };
    let matches = search.screen.matches();
    let selected = search
        .screen
        .selected_match()
        .and_then(|selected| matches.iter().position(|found| found == selected))
        .map(saturating_u32)
        .unwrap_or(LOCUS_TERM_SEARCH_NO_SELECTION);
    LocusTermSearchStatus {
        active: true,
        // The FFI starts and refreshes with search_all synchronously, so an
        // observable active search is always complete.
        complete: true,
        total: saturating_u32(search.screen.matches_len()),
        selected,
    }
}

fn search_match_pins(found: &terminal::highlight::Flattened) -> Option<(Pin, Pin)> {
    let first = found.chunks.first()?;
    let last = found.chunks.last()?;
    Some((
        Pin {
            node: first.node,
            x: found.top_x,
            y: first.start,
            garbage: false,
        },
        Pin {
            node: last.node,
            x: found.bot_x,
            y: last.end.checked_sub(1)?,
            garbage: false,
        },
    ))
}

fn append_viewport_search_rows(
    pages: &terminal::page_list::PageList,
    found: &terminal::highlight::Flattened,
    selected: Option<(Pin, Pin)>,
    output: &mut Vec<LocusTermSearchMatch>,
) {
    let Some(found_pins) = search_match_pins(found) else {
        return;
    };
    let selected_flag = if selected
        .is_some_and(|selected| selected.0.eql(found_pins.0) && selected.1.eql(found_pins.1))
    {
        LOCUS_TERM_SEARCH_MATCH_SELECTED
    } else {
        0
    };
    let Some(last_chunk_index) = found.chunks.len().checked_sub(1) else {
        return;
    };
    for (chunk_index, chunk) in found.chunks.iter().enumerate() {
        for y in chunk.start..chunk.end {
            let first_row = chunk_index == 0 && y == chunk.start;
            let last_row = chunk_index == last_chunk_index && y + 1 == chunk.end;
            let x_start = if first_row { found.top_x } else { 0 };
            let x_end = if last_row {
                found.bot_x
            } else {
                pages.cols.saturating_sub(1)
            };
            let start = Pin {
                node: chunk.node,
                x: x_start,
                y,
                garbage: false,
            };
            let end = Pin {
                node: chunk.node,
                x: x_end,
                y,
                garbage: false,
            };
            let (Some(start_point), Some(end_point)) = (
                pages.point_from_pin(Tag::Viewport, start),
                pages.point_from_pin(Tag::Viewport, end),
            ) else {
                continue;
            };
            let start = start_point.coord();
            let end = end_point.coord();
            if start.y != end.y || start.y >= u32::from(pages.rows) {
                continue;
            }
            output.push(LocusTermSearchMatch {
                y: start.y as u16,
                x_start: start.x,
                x_end: end.x,
                flags: selected_flag,
            });
        }
    }
}

fn append_viewport_link_rows(
    pages: &terminal::page_list::PageList,
    selection: terminal::selection::Selection,
    link_id: u16,
    output: &mut Vec<LocusTermLinkMatch>,
) {
    let (Some(start_pin), Some(end_pin)) =
        (selection.top_left(pages), selection.bottom_right(pages))
    else {
        return;
    };
    let (Some(start), Some(end)) = (
        pages.point_from_pin(Tag::Screen, start_pin),
        pages.point_from_pin(Tag::Screen, end_pin),
    ) else {
        return;
    };
    let start = start.coord();
    let end = end.coord();
    let bottom = u32::from(pages.rows.saturating_sub(1));
    let mut rows = pages.row_iterator(
        terminal::page_list::Direction::RightDown,
        Point::viewport(0, 0),
        Some(Point::viewport(0, bottom)),
    );

    while let Some(row) = rows.next(pages) {
        let Some(screen_row) = pages
            .point_from_pin(Tag::Screen, row)
            .map(|point| point.coord())
        else {
            continue;
        };
        if screen_row.y < start.y || screen_row.y > end.y {
            continue;
        }
        let x_start = if screen_row.y == start.y { start.x } else { 0 };
        let x_end = if screen_row.y == end.y {
            end.x
        } else {
            pages.cols.saturating_sub(1)
        };
        let start_pin = Pin { x: x_start, ..row };
        let end_pin = Pin { x: x_end, ..row };
        let (Some(view_start), Some(view_end)) = (
            pages.point_from_pin(Tag::Viewport, start_pin),
            pages.point_from_pin(Tag::Viewport, end_pin),
        ) else {
            continue;
        };
        let view_start = view_start.coord();
        let view_end = view_end.coord();
        if view_start.y != view_end.y || view_start.y >= u32::from(pages.rows) {
            continue;
        }
        output.push(LocusTermLinkMatch {
            y: view_start.y as u16,
            x_start: view_start.x,
            x_end: view_end.x,
            link_id,
        });
    }
}

fn validate_terminal_dimensions(cols: u16, rows: u16) -> bool {
    if cols == 0 || rows == 0 {
        set_last_error_message("terminal dimensions must be greater than zero");
        return false;
    }
    if cols > LOCUS_TERM_MAX_COLS || rows > LOCUS_TERM_MAX_ROWS {
        set_last_error_message(format!(
            "terminal dimensions must be at most {} cols by {} rows",
            LOCUS_TERM_MAX_COLS, LOCUS_TERM_MAX_ROWS
        ));
        return false;
    }
    true
}

fn validate_terminal_scrollback(max_scrollback: usize) -> bool {
    if max_scrollback > LOCUS_TERM_MAX_SCROLLBACK {
        set_last_error_message(format!(
            "terminal scrollback budget must be at most {} bytes",
            LOCUS_TERM_MAX_SCROLLBACK
        ));
        return false;
    }
    true
}

fn valid_cell_fraction(value: f32) -> bool {
    if value.is_finite() && (0.0..=1.0).contains(&value) {
        return true;
    }
    set_last_error_message("cell_fraction_x must be finite and between zero and one");
    false
}

fn selection_geometry(terminal: &Terminal) -> SelectionGeometry {
    SelectionGeometry {
        columns: terminal.cols,
        cell_width: SELECTION_CELL_WIDTH,
        padding_left: 0.0,
        screen_height: f64::from(terminal.rows),
    }
}

fn viewport_pin(terminal: &Terminal, x: u16, y: u16) -> Option<terminal::page_list::Pin> {
    if x >= terminal.cols || y >= terminal.rows {
        set_last_error_message("selection coordinate is outside the viewport");
        return None;
    }
    terminal
        .active_screen()
        .pages
        .pin(Point::viewport(x, u32::from(y)))
}

fn mouse_action(kind: u32) -> Option<MouseAction> {
    match kind {
        LOCUS_TERM_MOUSE_PRESS => Some(MouseAction::Press),
        LOCUS_TERM_MOUSE_RELEASE => Some(MouseAction::Release),
        LOCUS_TERM_MOUSE_MOTION => Some(MouseAction::Motion),
        _ => {
            set_last_error_message("unknown mouse event kind");
            None
        }
    }
}

fn mouse_button(button: u32) -> Option<Option<MouseButton>> {
    let value = match button {
        LOCUS_TERM_MOUSE_BUTTON_LEFT => Some(MouseButton::Left),
        LOCUS_TERM_MOUSE_BUTTON_MIDDLE => Some(MouseButton::Middle),
        LOCUS_TERM_MOUSE_BUTTON_RIGHT => Some(MouseButton::Right),
        LOCUS_TERM_MOUSE_BUTTON_WHEEL_UP => Some(MouseButton::Four),
        LOCUS_TERM_MOUSE_BUTTON_WHEEL_DOWN => Some(MouseButton::Five),
        LOCUS_TERM_MOUSE_BUTTON_WHEEL_LEFT => Some(MouseButton::Six),
        LOCUS_TERM_MOUSE_BUTTON_WHEEL_RIGHT => Some(MouseButton::Seven),
        LOCUS_TERM_MOUSE_BUTTON_NONE => None,
        _ => {
            set_last_error_message("unknown mouse button");
            return None;
        }
    };
    Some(value)
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

fn decode_osc52_base64(encoded: &[u8]) -> Option<Vec<u8>> {
    if !encoded.len().is_multiple_of(4) {
        return None;
    }

    let padding = match encoded {
        [.., b'=', b'='] => 2,
        [.., b'='] => 1,
        _ => 0,
    };
    let decoded_len = encoded.len().checked_div(4)?.checked_mul(3)? - padding;
    if decoded_len > OSC52_MAX_DECODED_BYTES {
        return None;
    }

    let mut decoded = Vec::with_capacity(decoded_len);
    let chunk_count = encoded.len() / 4;
    for (index, chunk) in encoded.chunks_exact(4).enumerate() {
        let is_last = index + 1 == chunk_count;
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        decoded.push((a << 2) | (b >> 4));

        if chunk[2] == b'=' {
            if !is_last || chunk[3] != b'=' || b & 0x0f != 0 {
                return None;
            }
            continue;
        }

        let c = base64_value(chunk[2])?;
        decoded.push((b << 4) | (c >> 2));
        if chunk[3] == b'=' {
            if !is_last || c & 0x03 != 0 {
                return None;
            }
            continue;
        }

        let d = base64_value(chunk[3])?;
        decoded.push((c << 6) | d);
    }

    (decoded.len() == decoded_len).then_some(decoded)
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
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
    frame.scroll_delta = if term.render_state.dirty == DirtyState::Full {
        0
    } else {
        term.render_state.scroll_delta
    };
    frame.cursor = cursor_from_render(&term.render_state);
    update_viewport_metadata(term, frame);
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
        let selection = row.selection.and_then(|value| {
            snap_selection_to_wide_boundaries(
                value.start,
                value.end,
                &storage.cell_storage[cell_start..],
            )
        });
        storage.row_storage.push(LocusTermRow {
            y: row_index as u16,
            cell_start,
            cell_count: row.cells.len(),
            dirty: row.dirty,
            wrapped: row.raw.wrap(),
            sel_start: selection.map(|value| value.0).unwrap_or(u16::MAX),
            sel_end: selection.map(|value| value.1).unwrap_or(u16::MAX),
        });
    }
    frame.refresh_pointers();
}

/// Presentation policy (not part of the ghostty port): the painted range must
/// match what `selection_string` copies. A wide head includes its tail, while
/// a range starting on a spacer tail drops that unselected half glyph.
fn snap_selection_to_wide_boundaries(
    start: u16,
    end: u16,
    cells: &[LocusTermCell],
) -> Option<(u16, u16)> {
    let mut start = start;
    let mut end = end;

    if cells
        .get(usize::from(start))
        .is_some_and(|cell| cell.wide == 3)
    {
        start = start.saturating_add(1);
    }

    if cells
        .get(usize::from(end))
        .is_some_and(|cell| cell.wide == 1)
    {
        let next_index = usize::from(end).saturating_add(1);
        if let Some(next) = cells.get(next_index) {
            debug_assert_eq!(next.wide, 3, "wide head must be followed by a spacer tail");
            end = end.saturating_add(1);
        }
    }

    (start <= end).then_some((start, end))
}

fn synchronized_output_blocks_render(term: &mut LocusTerm) -> bool {
    if !term
        .stream
        .handler
        .terminal
        .modes
        .get(Mode::SynchronizedOutput)
    {
        term.synchronized_output_started_at = None;
        return false;
    }

    if term
        .synchronized_output_started_at
        .is_some_and(|started| started.elapsed() < SYNCHRONIZED_OUTPUT_TIMEOUT)
    {
        return true;
    }

    // ghostty: termio/Thread.zig:35-37,364-374 -- upstream uses a timer;
    // this serialized ABI checks the same deadline at presentation time.
    term.stream
        .handler
        .terminal
        .reset_mode(Mode::SynchronizedOutput);
    term.synchronized_output_started_at = None;
    false
}

fn update_viewport_metadata(term: &mut LocusTerm, frame: &mut LocusTermFrame) {
    let screen = term.stream.handler.terminal.active_screen_mut();
    let scrollbar = screen.pages.scrollbar();
    let bottom_offset = scrollbar.total.saturating_sub(scrollbar.len);
    let viewport_offset = bottom_offset.saturating_sub(scrollbar.offset);
    frame.viewport_offset_rows = saturating_u32(viewport_offset);
    frame.total_rows = saturating_u32(scrollbar.total);
    frame.at_bottom = viewport_offset == 0;
}

fn saturating_u32(value: usize) -> u32 {
    value.min(u32::MAX as usize) as u32
}

fn cursor_from_render(render: &RenderState) -> LocusTermCursor {
    let Some(viewport) = render.cursor.viewport else {
        return LocusTermCursor {
            x: render.cursor.active.x,
            y: render.cursor.active.y as u16,
            visible: false,
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
unsafe fn dump_frame(
    term: &LocusTerm,
    frame: *const LocusTermFrame,
    dump: TermReplayDump,
) -> String {
    if dump == TermReplayDump::Vt {
        let mut formatter = TerminalFormatter::new(&term.stream.handler.terminal);
        formatter.opts.emit = Format::Vt;
        return formatter.format().text;
    }
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
    let graphemes = if frame.grapheme_count == 0 || frame.graphemes_ptr.is_null() {
        &[]
    } else {
        // SAFETY: same ownership contract as cells above.
        unsafe { std::slice::from_raw_parts(frame.graphemes_ptr, frame.grapheme_count) }
    };
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
            if matches!(cell.wide, 2 | 3) {
                continue;
            }
            let ch = char::from_u32(cell.codepoint).unwrap_or(' ');
            out.push(if ch == '\0' { ' ' } else { ch });
            let grapheme_end = cell
                .grapheme_start
                .saturating_add(cell.grapheme_len)
                .min(graphemes.len());
            for codepoint in &graphemes[cell.grapheme_start.min(grapheme_end)..grapheme_end] {
                if let Some(ch) = char::from_u32(*codepoint) {
                    out.push(ch);
                }
            }
        }
    }
    trim_terminal_dump(out)
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
        kitty_flags: terminal.active_screen().kitty_keyboard.current(),
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
        LOCUS_TERM_KEY_F13 => Key::F13,
        LOCUS_TERM_KEY_F14 => Key::F14,
        LOCUS_TERM_KEY_F15 => Key::F15,
        LOCUS_TERM_KEY_F16 => Key::F16,
        LOCUS_TERM_KEY_F17 => Key::F17,
        LOCUS_TERM_KEY_F18 => Key::F18,
        LOCUS_TERM_KEY_F19 => Key::F19,
        LOCUS_TERM_KEY_F20 => Key::F20,
        _ => Key::Unidentified,
    }
}

fn mods_from_bits(bits: u16) -> Mods {
    Mods::from_bits(bits)
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;
    use std::mem::{align_of, offset_of, size_of};
    use std::time::Instant;

    use super::*;
    use ::terminal::input::Side;

    fn last_error_text() -> String {
        // SAFETY: locus_last_error_message returns a non-null thread-local
        // NUL-terminated pointer valid until the next FFI call on this thread.
        unsafe { CStr::from_ptr(crate::locus_last_error_message()) }
            .to_string_lossy()
            .into_owned()
    }

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

    unsafe fn owned_bytes(bytes: &mut LocusTermBytes) -> Vec<u8> {
        let result = if bytes.len == 0 {
            Vec::new()
        } else {
            // SAFETY: test callers pass bytes returned by this ABI, which owns
            // a readable allocation until locus_term_bytes_free below.
            unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) }.to_vec()
        };
        // SAFETY: the allocation belongs to this byte handle and is freed once.
        unsafe { locus_term_bytes_free(bytes) };
        result
    }

    unsafe fn take_clipboard_write(term: *mut LocusTerm) -> Vec<u8> {
        let mut bytes = LocusTermBytes::default();
        // SAFETY: test callers pass a live terminal handle and writable output.
        assert_eq!(
            unsafe { locus_term_take_clipboard_write(term, &mut bytes) },
            LOCUS_STATUS_OK
        );
        // SAFETY: the ABI returned ownership of this byte handle.
        unsafe { owned_bytes(&mut bytes) }
    }

    unsafe fn search_status(term: *mut LocusTerm) -> LocusTermSearchStatus {
        let mut status = LocusTermSearchStatus::default();
        // SAFETY: test callers pass a live terminal handle and a writable out value.
        assert_eq!(
            unsafe { locus_term_search_status(term, &mut status) },
            LOCUS_STATUS_OK
        );
        status
    }

    unsafe fn search_matches(term: *mut LocusTerm) -> Vec<LocusTermSearchMatch> {
        let mut bytes = LocusTermBytes::default();
        // SAFETY: test callers pass a live terminal handle and a writable byte handle.
        assert_eq!(
            unsafe { locus_term_search_viewport_matches(term, &mut bytes) },
            LOCUS_STATUS_OK
        );
        // SAFETY: bytes is returned by the ABI and is consumed exactly once.
        let bytes = unsafe { owned_bytes(&mut bytes) };
        assert_eq!(bytes.len() % size_of::<LocusTermSearchMatch>(), 0);
        bytes
            .chunks_exact(size_of::<LocusTermSearchMatch>())
            .map(|record| LocusTermSearchMatch {
                y: u16::from_ne_bytes([record[0], record[1]]),
                x_start: u16::from_ne_bytes([record[2], record[3]]),
                x_end: u16::from_ne_bytes([record[4], record[5]]),
                flags: u16::from_ne_bytes([record[6], record[7]]),
            })
            .collect()
    }

    unsafe fn link_matches(term: *mut LocusTerm) -> Vec<LocusTermLinkMatch> {
        let mut bytes = LocusTermBytes::default();
        // SAFETY: test callers pass a live terminal handle and writable output.
        assert_eq!(
            unsafe { locus_term_viewport_links(term, &mut bytes) },
            LOCUS_STATUS_OK
        );
        // SAFETY: bytes is returned by this ABI and consumed exactly once.
        let bytes = unsafe { owned_bytes(&mut bytes) };
        assert_eq!(bytes.len() % size_of::<LocusTermLinkMatch>(), 0);
        bytes
            .chunks_exact(size_of::<LocusTermLinkMatch>())
            .map(|record| LocusTermLinkMatch {
                y: u16::from_ne_bytes([record[0], record[1]]),
                x_start: u16::from_ne_bytes([record[2], record[3]]),
                x_end: u16::from_ne_bytes([record[4], record[5]]),
                link_id: u16::from_ne_bytes([record[6], record[7]]),
            })
            .collect()
    }

    unsafe fn link_uri(term: *mut LocusTerm, id: u32) -> Vec<u8> {
        let mut bytes = LocusTermBytes::default();
        // SAFETY: test callers pass a live terminal handle and writable output.
        assert_eq!(
            unsafe { locus_term_link_uri(term, id, &mut bytes) },
            LOCUS_STATUS_OK
        );
        // SAFETY: bytes is returned by this ABI and consumed exactly once.
        unsafe { owned_bytes(&mut bytes) }
    }

    #[test]
    fn abi_version_is_nonzero() {
        assert_eq!(locus_term_abi_version(), LOCUS_TERM_ABI_VERSION);
    }

    #[test]
    fn search_status_layout_is_stable() {
        assert_eq!(size_of::<LocusTermSearchStatus>(), 12);
        assert_eq!(align_of::<LocusTermSearchStatus>(), 4);
        assert_eq!(offset_of!(LocusTermSearchStatus, active), 0);
        assert_eq!(offset_of!(LocusTermSearchStatus, complete), 1);
        assert_eq!(offset_of!(LocusTermSearchStatus, total), 4);
        assert_eq!(offset_of!(LocusTermSearchStatus, selected), 8);
    }

    #[test]
    fn search_match_layout_is_stable() {
        assert_eq!(size_of::<LocusTermSearchMatch>(), 8);
        assert_eq!(align_of::<LocusTermSearchMatch>(), 2);
        assert_eq!(offset_of!(LocusTermSearchMatch, y), 0);
        assert_eq!(offset_of!(LocusTermSearchMatch, x_start), 2);
        assert_eq!(offset_of!(LocusTermSearchMatch, x_end), 4);
        assert_eq!(offset_of!(LocusTermSearchMatch, flags), 6);
    }

    #[test]
    fn link_match_layout_is_stable() {
        assert_eq!(size_of::<LocusTermLinkMatch>(), 8);
        assert_eq!(align_of::<LocusTermLinkMatch>(), 2);
        assert_eq!(offset_of!(LocusTermLinkMatch, y), 0);
        assert_eq!(offset_of!(LocusTermLinkMatch, x_start), 2);
        assert_eq!(offset_of!(LocusTermLinkMatch, x_end), 4);
        assert_eq!(offset_of!(LocusTermLinkMatch, link_id), 6);
    }

    #[test]
    fn viewport_links_detect_plain_url_and_round_trip_uri() {
        let term = locus_term_new(40, 4, 1024);
        let input = b"visit https://example.test";
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                link_matches(term),
                vec![LocusTermLinkMatch {
                    y: 0,
                    x_start: 6,
                    x_end: 25,
                    link_id: 0,
                }]
            );
            assert_eq!(link_uri(term, 0), b"https://example.test");
            locus_term_free(term);
        }
    }

    #[test]
    fn viewport_links_preserve_osc8_target_uri() {
        let term = locus_term_new(30, 3, 1024);
        let input = b"\x1b]8;;https://target.test\x1b\\label\x1b]8;;\x1b\\";
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                link_matches(term),
                vec![LocusTermLinkMatch {
                    y: 0,
                    x_start: 0,
                    x_end: 4,
                    link_id: 0,
                }]
            );
            assert_eq!(link_uri(term, 0), b"https://target.test");
            locus_term_free(term);
        }
    }

    #[test]
    fn viewport_link_id_is_empty_after_refresh_removes_it() {
        let term = locus_term_new(30, 3, 1024);
        let input = b"https://example.test";
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(link_matches(term).len(), 1);
            assert_eq!(link_uri(term, 0), input);
            let clear = b"\x1b[2J";
            assert_eq!(
                locus_term_feed(term, clear.as_ptr(), clear.len()),
                LOCUS_STATUS_OK
            );
            assert!(link_matches(term).is_empty());
            assert!(link_uri(term, 0).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn viewport_links_validate_nulls_and_follow_scrolling() {
        let term = locus_term_new(30, 3, 1024 * 1024);
        let input = b"https://example.test\r\nline1\r\nline2\r\nline3\r\nline4";
        let mut bytes = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_viewport_links(ptr::null_mut(), &mut bytes),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_viewport_links(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_link_uri(term, 0, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert!(link_matches(term).is_empty());
            assert_eq!(locus_term_scroll(term, -3), LOCUS_STATUS_OK);
            let matches = link_matches(term);
            assert_eq!(matches.len(), 1);
            assert_eq!(matches[0].y, 0);
            assert_eq!(
                link_uri(term, u32::from(matches[0].link_id)),
                b"https://example.test"
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn search_start_and_status_round_trip() {
        let term = new_term();
        let input = b"Fizz\r\nBuzz\r\nFizz";
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                search_status(term),
                LocusTermSearchStatus {
                    active: true,
                    complete: true,
                    total: 2,
                    selected: LOCUS_TERM_SEARCH_NO_SELECTION,
                }
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn search_selection_cycles_and_reverses() {
        let term = new_term();
        let input = b"Fizz\r\nBuzz\r\nFizz";
        let mut status = LocusTermSearchStatus::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_NEXT, &mut status),
                LOCUS_STATUS_OK
            );
            assert_eq!(status.selected, 0);
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_NEXT, &mut status),
                LOCUS_STATUS_OK
            );
            assert_eq!(status.selected, 1);
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_NEXT, &mut status),
                LOCUS_STATUS_OK
            );
            assert_eq!(status.selected, 0);
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_PREV, &mut status),
                LOCUS_STATUS_OK
            );
            assert_eq!(status.selected, 1);
            locus_term_free(term);
        }
    }

    #[test]
    fn search_viewport_matches_include_selected_flag() {
        let term = new_term();
        let input = b"Fizz\r\nBuzz\r\nFizz";
        let mut status = LocusTermSearchStatus::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_NEXT, &mut status),
                LOCUS_STATUS_OK
            );
            let expected = vec![
                LocusTermSearchMatch {
                    y: 0,
                    x_start: 0,
                    x_end: 3,
                    flags: 0,
                },
                LocusTermSearchMatch {
                    y: 2,
                    x_start: 0,
                    x_end: 3,
                    flags: LOCUS_TERM_SEARCH_MATCH_SELECTED,
                },
            ];
            assert_eq!(search_matches(term), expected);
            assert_eq!(search_matches(term), expected);
            locus_term_free(term);
        }
    }

    #[test]
    fn search_multiline_match_emits_one_record_per_row() {
        let term = locus_term_new(5, 3, 1024);
        assert!(!term.is_null());
        let input = b"abcdeFG";
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"deFG".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                search_matches(term),
                vec![
                    LocusTermSearchMatch {
                        y: 0,
                        x_start: 3,
                        x_end: 4,
                        flags: 0,
                    },
                    LocusTermSearchMatch {
                        y: 1,
                        x_start: 0,
                        x_end: 1,
                        flags: 0,
                    },
                ]
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn search_selection_scrolls_to_scrollback_match() {
        let term = locus_term_new(12, 2, 1024 * 1024);
        let frame = locus_term_frame_new();
        assert!(!term.is_null());
        assert!(!frame.is_null());
        let input = b"Fizz0\r\nplain1\r\nplain2\r\nFizz3\r\nplain4\r\nplain5";
        let mut status = LocusTermSearchStatus::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term).total, 2);
            assert_eq!(
                locus_term_search_select(term, LOCUS_TERM_SEARCH_SELECT_NEXT, &mut status),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert!(!(*frame).at_bottom);
            assert!((*frame).viewport_offset_rows > 0);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn search_status_refreshes_after_new_output() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_feed(term, b"Fizz".as_ptr(), 4), LOCUS_STATUS_OK);
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term).total, 1);
            let input = b"\r\nFizz";
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term).total, 2);
            locus_term_free(term);
        }
    }

    #[test]
    fn search_survives_alternate_screen_round_trip() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_feed(term, b"Fizz".as_ptr(), 4), LOCUS_STATUS_OK);
            assert_eq!(
                locus_term_search_start(term, b"Fizz".as_ptr(), 4),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term).total, 1);

            let alternate = b"\x1b[?1049h";
            assert_eq!(
                locus_term_feed(term, alternate.as_ptr(), alternate.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term), LocusTermSearchStatus::default());

            let primary = b"\x1b[?1049l";
            assert_eq!(
                locus_term_feed(term, primary.as_ptr(), primary.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(search_status(term).total, 1);
            assert!(search_status(term).active);
            locus_term_free(term);
        }
    }

    #[test]
    fn search_guards_and_replacement_are_safe() {
        let term = new_term();
        let oversized = vec![b'x'; LOCUS_TERM_SEARCH_MAX_NEEDLE_BYTES + 1];
        let mut status = LocusTermSearchStatus::default();
        let mut bytes = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_search_start(term, ptr::null(), 0),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_search_start(term, oversized.as_ptr(), oversized.len()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_search_status(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_search_select(term, 99, &mut status),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_search_viewport_matches(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(locus_term_search_end(term), LOCUS_STATUS_OK);
            assert_eq!(locus_term_search_end(term), LOCUS_STATUS_OK);

            assert_eq!(
                locus_term_search_start(term, b"one".as_ptr(), 3),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_search_start(term, b"two".as_ptr(), 3),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_search_end(term), LOCUS_STATUS_OK);
            assert_eq!(
                locus_term_search_viewport_matches(term, &mut bytes),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut bytes).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn search_start_large_scrollback_reports_timing() {
        let term = locus_term_new(80, 24, 16 * 1024 * 1024);
        assert!(!term.is_null());
        let mut input = Vec::with_capacity(2 * 1024 * 1024);
        while input.len() < 2 * 1024 * 1024 {
            input.extend_from_slice(b"000001 sequence search needle payload\r\n");
        }
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            let started = Instant::now();
            assert_eq!(
                locus_term_search_start(term, b"needle".as_ptr(), 6),
                LOCUS_STATUS_OK
            );
            eprintln!(
                "search_start_2mb_ms={:.3}",
                started.elapsed().as_secs_f64() * 1_000.0
            );
            assert!(search_status(term).total > 0);
            locus_term_free(term);
        }
    }

    #[test]
    fn key_protocol_query_reports_xterm_and_kitty_modes() {
        let term = new_term();
        unsafe {
            assert_eq!(locus_term_key_protocol_active(term), 0);

            let xterm = b"\x1B[>4;2m";
            assert_eq!(
                locus_term_feed(term, xterm.as_ptr(), xterm.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_key_protocol_active(term), 1);

            let kitty = b"\x1B[=1;1u";
            assert_eq!(
                locus_term_feed(term, kitty.as_ptr(), kitty.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_key_protocol_active(term), 3);

            let reset = b"\x1Bc";
            assert_eq!(
                locus_term_feed(term, reset.as_ptr(), reset.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_key_protocol_active(term), 0);
            locus_term_free(term);
        }
    }

    #[test]
    fn key_protocol_query_accepts_null() {
        assert_eq!(unsafe { locus_term_key_protocol_active(ptr::null()) }, 0);
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
        assert!(offset_of!(LocusTermRow, sel_start) > offset_of!(LocusTermRow, wrapped));
        assert_eq!(
            offset_of!(LocusTermRow, sel_end),
            offset_of!(LocusTermRow, sel_start) + size_of::<u16>()
        );
        assert!(size_of::<LocusTermRow>() >= 32);
    }

    #[test]
    fn key_event_layout_starts_with_action_and_key() {
        assert_eq!(offset_of!(LocusTermKeyEvent, action), 0);
        assert_eq!(offset_of!(LocusTermKeyEvent, key), 4);
    }

    #[test]
    fn mods_bit_layout_is_pinned_for_ffi() {
        let flag_cases = [
            (
                LOCUS_TERM_MOD_SHIFT,
                Mods {
                    shift: true,
                    ..Mods::none()
                },
            ),
            (
                LOCUS_TERM_MOD_CTRL,
                Mods {
                    ctrl: true,
                    ..Mods::none()
                },
            ),
            (
                LOCUS_TERM_MOD_ALT,
                Mods {
                    alt: true,
                    ..Mods::none()
                },
            ),
            (
                LOCUS_TERM_MOD_SUPER,
                Mods {
                    super_key: true,
                    ..Mods::none()
                },
            ),
            (
                LOCUS_TERM_MOD_CAPS_LOCK,
                Mods {
                    caps_lock: true,
                    ..Mods::none()
                },
            ),
            (
                LOCUS_TERM_MOD_NUM_LOCK,
                Mods {
                    num_lock: true,
                    ..Mods::none()
                },
            ),
        ];

        for (bit, mods) in flag_cases {
            assert_eq!(mods.int(), bit);
            assert_eq!(mods_from_bits(bit).int(), bit);
        }

        for (index, bit) in [(0, 1 << 6), (1, 1 << 7), (2, 1 << 8), (3, 1 << 9)] {
            let mods = mods_from_bits(bit);
            assert_eq!(mods.int(), bit);
            let side = match index {
                0 => mods.sides.shift,
                1 => mods.sides.ctrl,
                2 => mods.sides.alt,
                _ => mods.sides.super_key,
            };
            assert_eq!(side, Side::Right);
        }

        let all_bits = (1 << 10) - 1;
        assert_eq!(mods_from_bits(all_bits).int(), all_bits);
    }

    #[test]
    fn frame_prefix_layout_exposes_version_first() {
        assert_eq!(offset_of!(LocusTermFrame, abi_version), 0);
        assert_eq!(offset_of!(LocusTermFrame, scroll_delta), 12);
        assert_eq!(offset_of!(LocusTermFrame, viewport_offset_rows), 16);
        assert_eq!(offset_of!(LocusTermFrame, total_rows), 20);
        assert_eq!(offset_of!(LocusTermFrame, at_bottom), 24);
        assert!(offset_of!(LocusTermFrame, rows_ptr) > offset_of!(LocusTermFrame, row_count));
    }

    #[test]
    fn new_rejects_zero_dimensions() {
        assert!(locus_term_new(0, 24, 0).is_null());
        assert!(locus_term_new(80, 0, 0).is_null());
    }

    #[test]
    fn term_new_rejects_oversized_dimensions() {
        // hardening: hostile dimensions must fail before allocating a frame.
        assert!(locus_term_new(u16::MAX, u16::MAX, 0).is_null());
        assert!(last_error_text().contains("at most 4096 cols by 4096 rows"));

        let term = locus_term_new(LOCUS_TERM_MAX_COLS, LOCUS_TERM_MAX_ROWS, 0);
        assert!(!term.is_null());
        unsafe {
            locus_term_free(term);
        }
    }

    #[test]
    fn term_new_rejects_oversized_scrollback() {
        // hardening: hostile scrollback budgets must fail before allocation.
        assert!(locus_term_new(80, 24, LOCUS_TERM_MAX_SCROLLBACK + 1).is_null());
        assert!(last_error_text().contains("scrollback budget"));
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
    fn frame_reports_scroll_delta() {
        let term = locus_term_new(8, 3, 1024 * 1024);
        let frame = locus_term_frame_new();
        assert!(!term.is_null());
        assert!(!frame.is_null());
        unsafe {
            let initial = b"one\r\ntwo\r\nthree";
            assert_eq!(
                locus_term_feed(term, initial.as_ptr(), initial.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let next = b"\r\nfour";
            assert_eq!(
                locus_term_feed(term, next.as_ptr(), next.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_eq!((*frame).scroll_delta, 1);
            assert_eq!((*frame).dirty_state, LOCUS_TERM_DIRTY_PARTIAL);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn cursor_is_hidden_while_scrolled_back() {
        let term = locus_term_new(8, 3, 1024 * 1024);
        let frame = locus_term_frame_new();
        let input = (0..10)
            .map(|line| format!("{line}\r\n"))
            .collect::<String>();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert!((*frame).cursor.visible);
            assert_eq!(locus_term_scroll(term, -2), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert!(!(*frame).cursor.visible);
            assert_eq!(locus_term_scroll(term, 100), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert!((*frame).cursor.visible);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn frame_reports_viewport_position() {
        let term = locus_term_new(12, 10, 1024 * 1024);
        let frame = locus_term_frame_new();
        let input = (0..100)
            .map(|line| format!("line-{line}\r\n"))
            .collect::<String>();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert!((*frame).total_rows >= 100);
            assert_eq!((*frame).viewport_offset_rows, 0);
            assert!((*frame).at_bottom);

            assert_eq!(locus_term_scroll(term, -20), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert_eq!((*frame).viewport_offset_rows, 20);
            assert!(!(*frame).at_bottom);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn synchronized_output_withholds_until_disabled() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let input = b"\x1b[?2026hwithheld";
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_eq!((*frame).dirty_state, LOCUS_TERM_DIRTY_NONE);
            assert!(!dump_frame(&*term, frame, TermReplayDump::Plain).contains("withheld"));

            let disable = b"\x1b[?2026l";
            assert_eq!(
                locus_term_feed(term, disable.as_ptr(), disable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_ne!((*frame).dirty_state, LOCUS_TERM_DIRTY_NONE);
            assert!(dump_frame(&*term, frame, TermReplayDump::Plain).contains("withheld"));
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn synchronized_output_timeout_forces_delivery() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            let input = b"\x1b[?2026htimeout";
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            (*term).expire_synchronized_output_for_test();
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_ne!((*frame).dirty_state, LOCUS_TERM_DIRTY_NONE);
            assert!(dump_frame(&*term, frame, TermReplayDump::Plain).contains("timeout"));
            assert!(!(*term)
                .stream
                .handler
                .terminal
                .modes
                .get(Mode::SynchronizedOutput));
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn synchronized_output_reopen_in_one_chunk_gets_fresh_budget() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            let first = b"\x1b[?2026hfirst";
            assert_eq!(
                locus_term_feed(term, first.as_ptr(), first.len()),
                LOCUS_STATUS_OK
            );
            (*term).age_synchronized_output_for_test(Duration::from_millis(100));
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_eq!((*frame).dirty_state, LOCUS_TERM_DIRTY_NONE);

            let reopen = b"\x1b[?2026l\x1b[?2026hsecond";
            assert_eq!(
                locus_term_feed(term, reopen.as_ptr(), reopen.len()),
                LOCUS_STATUS_OK
            );
            (*term).age_synchronized_output_for_test(Duration::from_millis(60));
            assert_eq!(locus_term_render(term, frame, false), LOCUS_STATUS_OK);
            assert_eq!((*frame).dirty_state, LOCUS_TERM_DIRTY_NONE);

            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn resize_releases_synchronized_output() {
        let term = new_term();
        unsafe {
            let enable = b"\x1b[?2026h";
            assert_eq!(
                locus_term_feed(term, enable.as_ptr(), enable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_resize(term, 20, 6), LOCUS_STATUS_OK);
            assert!(!(*term)
                .stream
                .handler
                .terminal
                .modes
                .get(Mode::SynchronizedOutput));
            locus_term_free(term);
        }
    }

    #[test]
    fn replay_plain_preserves_wide_graphemes_without_spacer_text() {
        let text = "日本語 👨‍👩‍👧";
        let output = replay_bytes(text.as_bytes(), 40, 4, TermReplayDump::Plain).unwrap();
        assert!(output.text.contains(text), "dump was: {:?}", output.text);
    }

    #[test]
    fn replay_vt_uses_terminal_formatter() {
        let output = replay_bytes(b"\x1b[31mred", 20, 4, TermReplayDump::Vt).unwrap();
        assert!(output.text.contains("\x1b["), "dump was: {:?}", output.text);
        assert!(output.text.contains("red"), "dump was: {:?}", output.text);
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
    fn term_resize_rejects_oversized_dimensions() {
        // hardening: rejected resize must leave the existing handle usable.
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_resize(term, 5000, 24),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_feed(term, b"ok".as_ptr(), b"ok".len()),
                LOCUS_STATUS_OK
            );
            assert!(render_plain(term).contains("ok"));
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
    fn osc_52_clipboard_write_decodes_and_drains() {
        let term = new_term();
        let input = b"\x1b]52;c;aGVsbG8=\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(take_clipboard_write(term), b"hello");
            assert!(take_clipboard_write(term).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_empty_selection_defaults_to_system_clipboard() {
        let term = new_term();
        let input = b"\x1b]52;;aGVsbG8=\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(take_clipboard_write(term), b"hello");
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_non_system_selection_is_ignored() {
        let term = new_term();
        let input = b"\x1b]52;p;aGVsbG8=\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert!(take_clipboard_write(term).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_clipboard_read_is_ignored_without_response() {
        let term = new_term();
        let input = b"\x1b]52;c;?\x07";
        let mut responses = LocusTermBytes::default();
        // SAFETY: term is live; input and output storage remain valid for each call.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert!(take_clipboard_write(term).is_empty());
            assert_eq!(
                locus_term_take_responses(term, &mut responses),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut responses).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_invalid_base64_is_ignored() {
        let term = new_term();
        let invalid_character = b"\x1b]52;c;aGVs!G8=\x07";
        let invalid_length = b"\x1b]52;c;abc\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, invalid_character.as_ptr(), invalid_character.len()),
                LOCUS_STATUS_OK
            );
            assert!(take_clipboard_write(term).is_empty());
            assert_eq!(
                locus_term_feed(term, invalid_length.as_ptr(), invalid_length.len()),
                LOCUS_STATUS_OK
            );
            assert!(take_clipboard_write(term).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_oversized_encoded_payload_is_dropped_before_decode() {
        let term = new_term();
        let mut input = b"\x1b]52;c;".to_vec();
        input.resize(input.len() + OSC52_MAX_ENCODED_BYTES + 1, b'A');
        input.push(0x07);
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert!(take_clipboard_write(term).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_last_honored_writer_wins() {
        let term = new_term();
        let input = b"\x1b]52;c;Zmlyc3Q=\x07\x1b]52;c;c2Vjb25k\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(take_clipboard_write(term), b"second");
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_take_clears_pending_write() {
        let term = new_term();
        let input = b"\x1b]52;c;eA==\x07";
        // SAFETY: term is live and input remains readable during the feed.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(take_clipboard_write(term), b"x");
            assert!(take_clipboard_write(term).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn osc_52_take_rejects_null_arguments() {
        let term = new_term();
        let mut bytes = LocusTermBytes::default();
        // SAFETY: these deliberately adversarial calls verify null checks.
        unsafe {
            assert_eq!(
                locus_term_take_clipboard_write(ptr::null_mut(), &mut bytes),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_take_clipboard_write(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
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
        // SAFETY: term is live, the byte slice is readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_paste(term, b"a\nb".as_ptr(), 3, false, &mut out),
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
        // SAFETY: term is live, the byte slice is readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_paste(term, b"paste".as_ptr(), 5, false, &mut out),
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
        // SAFETY: term is live, both byte slices are readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"\x1b[?2004h".as_ptr(), 8),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_paste(term, b"paste".as_ptr(), 5, false, &mut out),
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
    fn paste_allows_newline_when_confirmed() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        // SAFETY: term is live, the byte slice is readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_paste(term, b"a\nb".as_ptr(), 3, true, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(std::slice::from_raw_parts(out.ptr, out.len), b"a\rb");
            locus_term_bytes_free(&mut out);
            locus_term_free(term);
        }
    }

    #[test]
    fn paste_bracketed_multiline_skips_confirmation() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        // SAFETY: term is live, both byte slices are readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"\x1b[?2004h".as_ptr(), 8),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_paste(term, b"a\nb".as_ptr(), 3, false, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                std::slice::from_raw_parts(out.ptr, out.len),
                b"\x1b[200~a\nb\x1b[201~"
            );
            locus_term_bytes_free(&mut out);
            locus_term_free(term);
        }
    }

    #[test]
    fn paste_bracketed_neutralizes_end_sentinel() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        // SAFETY: term is live, both byte slices are readable, and out is writable.
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"\x1b[?2004h".as_ptr(), 8),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_paste(term, b"x\x1b[201~y".as_ptr(), 8, false, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                std::slice::from_raw_parts(out.ptr, out.len),
                b"\x1b[200~x [201~y\x1b[201~"
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
    fn ffi_effects_keep_latest_only() {
        let term = new_term();
        let mut input = Vec::new();
        for index in 0..1_000 {
            input.extend_from_slice(format!("\x1b]0;title-{index}\x07").as_bytes());
        }

        // SAFETY: `term` is live for this block, `input` remains readable for
        // the feed call, and the handle is freed exactly once after inspection.
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            let term_ref = &*term;
            assert_eq!(
                term_ref.stream.handler.effects.latest_title.as_deref(),
                Some("title-999")
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

    #[test]
    fn selection_gesture_populates_frame_and_release_keeps_selection() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"abcdef".as_ptr(), 6),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 1, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 2, 4, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (1, 3));
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_clear_removes_frame_range() {
        let term = new_term();
        let frame = locus_term_frame_new();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"abcdef".as_ptr(), 6),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 1, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_selection_clear(term), LOCUS_STATUS_OK);
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (u16::MAX, u16::MAX));
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_string_round_trips_visible_text() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"abcdef".as_ptr(), 6),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 1, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"bcd");
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_keeps_tail_started_wide_selection_copy_consistent() {
        // P12 probe A: press-tail(5,f0.9) -> drag(7).
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 5, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 7, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (6, 7));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_extends_wide_head_end_to_match_copy() {
        // P12 probe B: press(0) -> drag-head(4,f0.9).
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (0, 5));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), text.as_bytes());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_extends_wide_head_end_for_reverse_fraction() {
        // P12 probe C: press(0) -> drag-tail(5,f0.4).
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 5, 0, 0.4, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (0, 5));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), text.as_bytes());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_leaves_existing_spacer_tail_end_unchanged() {
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 5, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (0, 5));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), text.as_bytes());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_drops_spacer_tail_start_to_match_empty_copy() {
        // P12 probe D: press-tail(5,f0.4) -> drag(7).
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 5, 0, 0.4, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 7, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (6, 7));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_frame_includes_mixed_row_wide_character_tail() {
        let term = new_term();
        let frame = locus_term_frame_new();
        let mut out = LocusTermBytes::default();
        let text = "a漢b";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 1, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (0, 2));
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), "a漢".as_bytes());
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn rectangular_selection_snaps_each_wide_row_independently() {
        let term = new_term();
        let frame = locus_term_frame_new();
        let text = "日本語\r\n日本語";
        unsafe {
            assert_eq!(
                locus_term_feed(term, text.as_ptr(), text.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 1, 0.9, true),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let rows = std::slice::from_raw_parts((*frame).rows_ptr, (*frame).row_count);
            assert_eq!((rows[0].sel_start, rows[0].sel_end), (0, 5));
            assert_eq!((rows[1].sel_start, rows[1].sel_end), (0, 5));
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_snap_clears_tail_only_range() {
        let cells = [LocusTermCell {
            wide: 3,
            ..LocusTermCell::default()
        }];

        assert_eq!(snap_selection_to_wide_boundaries(0, 0, &cells), None);
    }

    #[test]
    fn selection_snap_does_not_extend_malformed_row_end() {
        let cells = [LocusTermCell {
            wide: 1,
            ..LocusTermCell::default()
        }];

        assert_eq!(
            snap_selection_to_wide_boundaries(0, 0, &cells),
            Some((0, 0))
        );
    }

    #[test]
    fn latest_title_and_pwd_round_trip_through_feed() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            let title = b"\x1b]2;hello-title\x07";
            assert_eq!(
                locus_term_feed(term, title.as_ptr(), title.len()),
                LOCUS_STATUS_OK
            );
            let pwd = b"\x1b]7;file:///tmp/locus%20p3\x07";
            assert_eq!(
                locus_term_feed(term, pwd.as_ptr(), pwd.len()),
                LOCUS_STATUS_OK
            );

            assert_eq!(locus_term_latest_title(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"hello-title");
            assert_eq!(locus_term_latest_pwd(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"file:///tmp/locus%20p3");

            let clear_title = b"\x1b]2;\x07";
            assert_eq!(
                locus_term_feed(term, clear_title.as_ptr(), clear_title.len()),
                LOCUS_STATUS_OK
            );
            let clear_pwd = b"\x1b]7;\x07";
            assert_eq!(
                locus_term_feed(term, clear_pwd.as_ptr(), clear_pwd.len()),
                LOCUS_STATUS_OK
            );

            assert_eq!(locus_term_latest_title(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            assert_eq!(locus_term_latest_pwd(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn latest_title_rejects_null_out() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_latest_title(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_term_latest_pwd(term, ptr::null_mut()),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(locus_term_latest_title(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            assert_eq!(locus_term_latest_pwd(term, &mut out), LOCUS_STATUS_OK);
            assert!(owned_bytes(&mut out).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_fraction_includes_pointer_cell() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"hello world".as_ptr(), 11),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.1, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.9, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"hello");

            assert_eq!(locus_term_selection_clear(term), LOCUS_STATUS_OK);
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, 0.05, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 0, 0, 0.95, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"h");
            locus_term_free(term);
        }
    }

    #[test]
    fn autoscroll_without_active_gesture_is_a_no_op() {
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_autoscroll_tick(term, 1, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn selection_rejects_nonfinite_fraction() {
        let term = new_term();
        unsafe {
            assert_eq!(
                locus_term_selection_gesture(term, 0, 0, 0, f32::NAN, false),
                LOCUS_TERM_STATUS_INVALID_ARGUMENT
            );
            locus_term_free(term);
        }
    }

    #[test]
    fn mouse_without_reporting_mode_returns_empty() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_mouse(term, 0, 0, 1, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut out).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn sgr_mouse_press_encodes_one_based_coordinates() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            let enable = b"\x1b[?1000h\x1b[?1006h";
            assert_eq!(
                locus_term_feed(term, enable.as_ptr(), enable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_mouse(term, 0, 0, 2, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(owned_bytes(&mut out), b"\x1b[<0;3;2M");
            locus_term_free(term);
        }
    }

    #[test]
    fn shifted_mouse_bypasses_reporting_and_preserves_selection() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, b"abcdef".as_ptr(), 6),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 0, 1, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_selection_gesture(term, 1, 4, 0, 0.5, false),
                LOCUS_STATUS_OK
            );
            let enable = b"\x1b[?1000h\x1b[?1006h";
            assert_eq!(
                locus_term_feed(term, enable.as_ptr(), enable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_mouse(term, 0, 0, 2, 0, LOCUS_TERM_MOD_SHIFT, &mut out),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut out).is_empty());
            assert_eq!(locus_term_selection_string(term, &mut out), LOCUS_STATUS_OK);
            assert_eq!(owned_bytes(&mut out), b"bcd");
            locus_term_free(term);
        }
    }

    #[test]
    fn shifted_mouse_reports_when_application_captures_shift() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            let enable = b"\x1b[?1000h\x1b[?1006h\x1b[>1s";
            assert_eq!(
                locus_term_feed(term, enable.as_ptr(), enable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_mouse(term, 0, 0, 2, 1, LOCUS_TERM_MOD_SHIFT, &mut out),
                LOCUS_STATUS_OK
            );
            assert!(!owned_bytes(&mut out).is_empty());
            locus_term_free(term);
        }
    }

    #[test]
    fn alternate_scroll_mode_emits_cursor_keys() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            let enable = b"\x1b[?1049h\x1b[?1007h";
            assert_eq!(
                locus_term_feed(term, enable.as_ptr(), enable.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_scroll_wheel(term, -2, 1, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(owned_bytes(&mut out), b"\x1b[A\x1b[A");
            locus_term_free(term);
        }
    }

    #[test]
    fn primary_wheel_without_mouse_mode_scrolls_viewport() {
        let term = locus_term_new(12, 4, 1024 * 1024);
        let frame = locus_term_frame_new();
        let input = (0..20)
            .map(|line| format!("{line}\r\n"))
            .collect::<String>();
        let mut out = LocusTermBytes::default();
        unsafe {
            assert_eq!(
                locus_term_feed(term, input.as_ptr(), input.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_scroll_wheel(term, -2, 1, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut out).is_empty());
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            assert_eq!((*frame).viewport_offset_rows, 2);
            locus_term_frame_free(frame);
            locus_term_free(term);
        }
    }

    #[test]
    fn button_motion_filters_hover_but_any_motion_reports_it() {
        let term = new_term();
        let mut out = LocusTermBytes::default();
        unsafe {
            let button_mode = b"\x1b[?1002h\x1b[?1006h";
            assert_eq!(
                locus_term_feed(term, button_mode.as_ptr(), button_mode.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_mouse(term, 2, u32::MAX, 1, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert!(owned_bytes(&mut out).is_empty());

            let any_mode = b"\x1b[?1003h";
            assert_eq!(
                locus_term_feed(term, any_mode.as_ptr(), any_mode.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(
                locus_term_mouse(term, 2, u32::MAX, 2, 1, 0, &mut out),
                LOCUS_STATUS_OK
            );
            assert_eq!(owned_bytes(&mut out), b"\x1b[<35;3;2M");
            locus_term_free(term);
        }
    }
}
