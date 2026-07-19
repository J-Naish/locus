use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, Instant};

use app_core::text_buffer::TextBuffer;
use app_core::workspace::list_directory;
use app_ffi::terminal::{replay_bytes, TermReplayDump};
use pty::{Pty, PtyError, PtyOptions};

const DEFAULT_ITERATIONS: usize = 5;
const MAX_ITERATIONS: usize = u32::MAX as usize;

const DEFAULT_BUFFER_SIZE_BYTES: usize = 1_000_000;
const DEFAULT_BUFFER_SCROLL_READS: usize = 100;
const BUFFER_VIEWPORT_LINES: usize = 80;
// Each edit is O(log n) in the piece count (the treap caches subtree
// aggregates), so this modest default just keeps a single benchmark run quick
// while still exercising the edit path repeatedly.
const DEFAULT_BUFFER_EDITS: usize = 50;

fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        None | Some("version") => print_version(),
        Some("perf-list-directory") => {
            if let Err(error) = run_perf_list_directory(args) {
                eprintln!("error: {error}");
                process::exit(error.exit_code());
            }
        }
        Some("perf-buffer") => {
            if let Err(error) = run_perf_buffer(args) {
                eprintln!("error: {error}");
                process::exit(error.exit_code());
            }
        }
        Some("term-replay") => {
            if let Err(error) = run_term_replay(args) {
                eprintln!("error: {error}");
                process::exit(error.exit_code());
            }
        }
        Some("term-run") => {
            if let Err(error) = run_term_run(args) {
                eprintln!("error: {error}");
                process::exit(error.exit_code());
            }
        }
        Some("help") | Some("--help") | Some("-h") => print_help(),
        Some(command) => {
            eprintln!("error: unknown command: {command}");
            print_help();
            process::exit(2);
        }
    }
}

fn print_version() {
    println!("{} core {}", app_core::APP_NAME, app_core::core_version());
}

fn print_help() {
    println!(
        "\
{} core {}

Usage:
  locus-core version
  locus-core perf-list-directory <path> [--iterations N] [--budget-ms N] [--max-budget-ms N]
  locus-core perf-buffer [--size-bytes N] [--iterations N] [--open-budget-ms N] [--scroll-budget-ms N] [--edit-budget-ms N]
  locus-core term-replay <file> --cols N --rows N [--dump plain|vt] [--bench]
  locus-core term-run --cols N --rows N [--timeout-ms N] -- <cmd> [args...]

Commands:
  version                 Print the Rust core version.
  perf-list-directory     Measure non-recursive workspace listing latency.
  perf-buffer             Measure text-buffer open, viewport read, and edit latency.
  term-replay             Replay a byte log through the terminal FFI surface.
  term-run                Run a command through a PTY and render the final screen.
",
        app_core::APP_NAME,
        app_core::core_version()
    );
}

fn run_term_replay(args: impl Iterator<Item = String>) -> Result<(), CliError> {
    let options = TermReplayOptions::parse(args)?;
    let bytes = fs::read(&options.path).map_err(|source| {
        CliError::Runtime(format!(
            "failed to read replay fixture {}: {source}",
            options.path.display()
        ))
    })?;

    let report =
        replay_bytes(&bytes, options.cols, options.rows, options.dump).map_err(|status| {
            CliError::Runtime(format!("terminal replay failed with status {status}"))
        })?;
    println!("{}", report.text);

    if options.bench {
        let bytes_per_second = if report.feed.is_zero() {
            0.0
        } else {
            report.bytes as f64 / report.feed.as_secs_f64()
        };
        println!("bytes: {}", report.bytes);
        println!("feed_ms: {:.3}", report.feed.as_secs_f64() * 1000.0);
        println!("bytes_per_second: {:.0}", bytes_per_second);
        println!("render_ms: {:.3}", report.render.as_secs_f64() * 1000.0);
    }
    Ok(())
}

fn run_term_run(args: impl Iterator<Item = String>) -> Result<(), CliError> {
    let options = TermRunOptions::parse(args)?;
    let text = term_run_plain_dump(&options)?;
    println!("{text}");
    Ok(())
}

fn term_run_plain_dump(options: &TermRunOptions) -> Result<String, CliError> {
    let mut pty = Pty::spawn(PtyOptions {
        cols: options.cols,
        rows: options.rows,
        command: Some(options.command.clone()),
        args: options.args.clone(),
        cwd: None,
        env: Vec::new(),
    })
    .map_err(|source| CliError::Runtime(format!("failed to spawn PTY command: {source}")))?;

    let deadline = Instant::now() + options.timeout;
    let mut output = Vec::new();
    let mut buf = [0_u8; 4096];
    loop {
        match pty.read(&mut buf) {
            Ok(0) => break,
            Ok(count) => output.extend_from_slice(&buf[..count]),
            Err(PtyError::WouldBlock) => {
                if matches!(pty.try_wait(), Ok(Some(_))) {
                    match pty.read(&mut buf) {
                        Ok(0) | Err(PtyError::WouldBlock) => break,
                        Ok(count) => output.extend_from_slice(&buf[..count]),
                        Err(source) => {
                            return Err(CliError::Runtime(format!(
                                "failed to drain PTY output: {source}"
                            )))
                        }
                    }
                }
                if Instant::now() >= deadline {
                    kill_timed_out_process_group(&pty);
                    let _ = pty.shutdown();
                    return Err(CliError::Runtime(format!(
                        "term-run timed out after {}ms",
                        options.timeout.as_millis()
                    )));
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(source) => {
                return Err(CliError::Runtime(format!(
                    "failed to read PTY output: {source}"
                )))
            }
        }
    }

    let report = replay_bytes(&output, options.cols, options.rows, TermReplayDump::Plain).map_err(
        |status| CliError::Runtime(format!("terminal replay failed with status {status}")),
    )?;
    Ok(report.text)
}

fn kill_timed_out_process_group(pty: &Pty) {
    // The PTY child is a session leader; this killpg-backed operation kills the
    // whole group so shell-spawned grandchildren do not survive `term-run`.
    pty.kill_process_group_for_timeout();
}

#[derive(Debug)]
struct TermRunOptions {
    cols: u16,
    rows: u16,
    timeout: Duration,
    command: PathBuf,
    args: Vec<OsString>,
}

impl TermRunOptions {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, CliError> {
        let mut cols = None;
        let mut rows = None;
        let mut timeout = Duration::from_millis(2_000);
        let mut command = None;
        let mut command_args = Vec::new();
        let mut after_separator = false;
        let mut args = args.peekable();

        while let Some(arg) = args.next() {
            if after_separator {
                if command.is_none() {
                    command = Some(PathBuf::from(arg));
                } else {
                    command_args.push(OsString::from(arg));
                }
                continue;
            }

            match arg.as_str() {
                "--cols" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--cols requires a value".to_string()))?;
                    cols = Some(parse_nonzero_u16("--cols", &value)?);
                }
                "--rows" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--rows requires a value".to_string()))?;
                    rows = Some(parse_nonzero_u16("--rows", &value)?);
                }
                "--timeout-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--timeout-ms requires a value".to_string())
                    })?;
                    timeout = Duration::from_millis(parse_nonzero_u64("--timeout-ms", &value)?);
                }
                "--" => after_separator = true,
                value if value.starts_with('-') => {
                    return Err(CliError::Usage(format!("unknown option: {value}")));
                }
                _ => {
                    return Err(CliError::Usage(
                        "term-run command must follow --".to_string(),
                    ));
                }
            }
        }

        Ok(Self {
            cols: cols.ok_or_else(|| CliError::Usage("term-run requires --cols".to_string()))?,
            rows: rows.ok_or_else(|| CliError::Usage("term-run requires --rows".to_string()))?,
            timeout,
            command: command.ok_or_else(|| {
                CliError::Usage("term-run requires a command after --".to_string())
            })?,
            args: command_args,
        })
    }
}

#[derive(Debug)]
struct TermReplayOptions {
    path: PathBuf,
    cols: u16,
    rows: u16,
    dump: TermReplayDump,
    bench: bool,
}

impl TermReplayOptions {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, CliError> {
        let mut path = None;
        let mut cols = None;
        let mut rows = None;
        let mut dump = TermReplayDump::Plain;
        let mut bench = false;
        let mut args = args.peekable();

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--cols" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--cols requires a value".to_string()))?;
                    cols = Some(parse_nonzero_u16("--cols", &value)?);
                }
                "--rows" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--rows requires a value".to_string()))?;
                    rows = Some(parse_nonzero_u16("--rows", &value)?);
                }
                "--dump" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--dump requires a value".to_string()))?;
                    dump = match value.as_str() {
                        "plain" => TermReplayDump::Plain,
                        "vt" => TermReplayDump::Vt,
                        _ => return Err(CliError::Usage("--dump must be plain or vt".to_string())),
                    };
                }
                "--bench" => bench = true,
                value if value.starts_with('-') => {
                    return Err(CliError::Usage(format!("unknown option: {value}")));
                }
                value => {
                    if path.replace(PathBuf::from(value)).is_some() {
                        return Err(CliError::Usage(
                            "term-replay accepts exactly one file".to_string(),
                        ));
                    }
                }
            }
        }

        Ok(Self {
            path: path.ok_or_else(|| CliError::Usage("term-replay requires a file".to_string()))?,
            cols: cols.ok_or_else(|| CliError::Usage("term-replay requires --cols".to_string()))?,
            rows: rows.ok_or_else(|| CliError::Usage("term-replay requires --rows".to_string()))?,
            dump,
            bench,
        })
    }
}

fn parse_nonzero_u16(name: &str, value: &str) -> Result<u16, CliError> {
    let parsed = value
        .parse::<u16>()
        .map_err(|source| CliError::Usage(format!("invalid {name} value {value:?}: {source}")))?;
    if parsed == 0 {
        return Err(CliError::Usage(format!("{name} must be greater than zero")));
    }
    Ok(parsed)
}

fn run_perf_list_directory(args: impl Iterator<Item = String>) -> Result<(), CliError> {
    let options = PerfListDirectoryOptions::parse(args)?;
    let report = measure_list_directory(&options.path, options.iterations)?;

    println!("workspace: {}", options.path.display());
    println!("entries: {}", report.entries);
    println!("partial_errors: {}", report.partial_errors);
    println!("iterations: {}", report.iterations);
    println!("avg_ms: {:.3}", report.average.as_secs_f64() * 1000.0);
    println!("max_ms: {:.3}", report.max.as_secs_f64() * 1000.0);

    if let Some(budget) = options.budget {
        println!("avg_budget_ms: {:.3}", budget.as_secs_f64() * 1000.0);
        if report.average > budget {
            return Err(CliError::Budget(format!(
                "average folder listing time {:.3}ms exceeded budget {:.3}ms",
                report.average.as_secs_f64() * 1000.0,
                budget.as_secs_f64() * 1000.0
            )));
        }
    }

    if let Some(max_budget) = options.max_budget {
        println!("max_budget_ms: {:.3}", max_budget.as_secs_f64() * 1000.0);
        if report.max > max_budget {
            return Err(CliError::Budget(format!(
                "max folder listing time {:.3}ms exceeded budget {:.3}ms",
                report.max.as_secs_f64() * 1000.0,
                max_budget.as_secs_f64() * 1000.0
            )));
        }
    }

    Ok(())
}

#[derive(Debug)]
enum CliError {
    Usage(String),
    Runtime(String),
    Budget(String),
}

impl CliError {
    fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => 2,
            Self::Runtime(_) | Self::Budget(_) => 1,
        }
    }
}

impl std::fmt::Display for CliError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Usage(message) | Self::Runtime(message) | Self::Budget(message) => {
                formatter.write_str(message)
            }
        }
    }
}

impl std::error::Error for CliError {}

#[derive(Debug)]
struct PerfListDirectoryOptions {
    path: PathBuf,
    iterations: usize,
    budget: Option<Duration>,
    max_budget: Option<Duration>,
}

impl PerfListDirectoryOptions {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, CliError> {
        let mut path = None;
        let mut iterations = DEFAULT_ITERATIONS;
        let mut budget = None;
        let mut max_budget = None;
        let mut args = args.peekable();

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--iterations" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--iterations requires a value".to_string())
                    })?;
                    iterations = parse_iteration_count("--iterations", &value)?;
                }
                "--budget-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--budget-ms requires a value".to_string())
                    })?;
                    budget = Some(Duration::from_millis(parse_nonzero_u64(
                        "--budget-ms",
                        &value,
                    )?));
                }
                "--max-budget-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--max-budget-ms requires a value".to_string())
                    })?;
                    max_budget = Some(Duration::from_millis(parse_nonzero_u64(
                        "--max-budget-ms",
                        &value,
                    )?));
                }
                value if value.starts_with('-') => {
                    return Err(CliError::Usage(format!("unknown option: {value}")));
                }
                value => {
                    if path.replace(PathBuf::from(value)).is_some() {
                        return Err(CliError::Usage(
                            "perf-list-directory accepts exactly one path".to_string(),
                        ));
                    }
                }
            }
        }

        let path =
            path.ok_or_else(|| CliError::Usage("perf-list-directory requires a path".to_string()))?;

        Ok(Self {
            path,
            iterations,
            budget,
            max_budget,
        })
    }
}

/// Parses a positive count used as a `u32` divisor for averaging (iterations,
/// scroll reads, edits), capped so the average never overflows the cast.
fn parse_iteration_count(name: &str, value: &str) -> Result<usize, CliError> {
    let parsed = parse_nonzero_size_bytes(name, value)?;
    if parsed > MAX_ITERATIONS {
        return Err(CliError::Usage(format!(
            "{name} must be less than or equal to {MAX_ITERATIONS}"
        )));
    }
    Ok(parsed)
}

/// Parses a positive byte size. Unlike [`parse_iteration_count`], it is not
/// capped to `u32`, so multi-gigabyte sizes can be measured.
fn parse_nonzero_size_bytes(name: &str, value: &str) -> Result<usize, CliError> {
    let parsed = value
        .parse::<usize>()
        .map_err(|source| CliError::Usage(format!("invalid {name} value {value:?}: {source}")))?;
    if parsed == 0 {
        return Err(CliError::Usage(format!("{name} must be greater than zero")));
    }
    Ok(parsed)
}

fn parse_nonzero_u64(name: &str, value: &str) -> Result<u64, CliError> {
    let parsed = value
        .parse::<u64>()
        .map_err(|source| CliError::Usage(format!("invalid {name} value {value:?}: {source}")))?;
    if parsed == 0 {
        return Err(CliError::Usage(format!("{name} must be greater than zero")));
    }
    Ok(parsed)
}

#[derive(Debug)]
struct PerfListDirectoryReport {
    entries: usize,
    partial_errors: usize,
    iterations: usize,
    average: Duration,
    max: Duration,
}

fn measure_list_directory(
    path: &Path,
    iterations: usize,
) -> Result<PerfListDirectoryReport, CliError> {
    let warmup = list_directory(path).map_err(|source| CliError::Runtime(source.to_string()))?;
    let entries = warmup.entries.len();
    let partial_errors = warmup.partial_errors.len();

    let mut total = Duration::ZERO;
    let mut max = Duration::ZERO;

    for _ in 0..iterations {
        let started = Instant::now();
        let snapshot =
            list_directory(path).map_err(|source| CliError::Runtime(source.to_string()))?;
        let elapsed = started.elapsed();

        if snapshot.entries.len() != entries {
            return Err(CliError::Runtime(format!(
                "entry count changed during measurement: expected {entries}, got {}",
                snapshot.entries.len()
            )));
        }

        total += elapsed;
        max = max.max(elapsed);
    }

    Ok(PerfListDirectoryReport {
        entries,
        partial_errors,
        iterations,
        average: total / iterations as u32,
        max,
    })
}

fn run_perf_buffer(args: impl Iterator<Item = String>) -> Result<(), CliError> {
    let options = PerfBufferOptions::parse(args)?;
    let report = measure_buffer(
        options.size_bytes,
        options.iterations,
        options.scroll_reads,
        options.edits,
    )?;

    println!("requested_size_bytes: {}", report.requested_size_bytes);
    println!("actual_size_bytes: {}", report.actual_size_bytes);
    println!("line_count: {}", report.line_count);
    println!("open_ms: {:.3}", report.open.as_secs_f64() * 1000.0);
    println!("scroll_ms: {:.3}", report.scroll.as_secs_f64() * 1000.0);
    println!("edit_ms: {:.3}", report.edit.as_secs_f64() * 1000.0);

    check_budget("open", report.open, options.open_budget_ms)?;
    check_budget("scroll", report.scroll, options.scroll_budget_ms)?;
    check_budget("edit", report.edit, options.edit_budget_ms)?;
    Ok(())
}

fn check_budget(name: &str, measured: Duration, budget_ms: Option<u64>) -> Result<(), CliError> {
    let Some(ms) = budget_ms else {
        return Ok(());
    };
    println!("{name}_budget_ms: {ms}");
    if measured > Duration::from_millis(ms) {
        return Err(CliError::Budget(format!(
            "{name} time {:.3}ms exceeded budget {ms}ms",
            measured.as_secs_f64() * 1000.0
        )));
    }
    Ok(())
}

#[derive(Debug)]
struct PerfBufferOptions {
    size_bytes: usize,
    iterations: usize,
    scroll_reads: usize,
    edits: usize,
    open_budget_ms: Option<u64>,
    scroll_budget_ms: Option<u64>,
    edit_budget_ms: Option<u64>,
}

impl PerfBufferOptions {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, CliError> {
        let mut size_bytes = DEFAULT_BUFFER_SIZE_BYTES;
        let mut iterations = DEFAULT_ITERATIONS;
        let mut scroll_reads = DEFAULT_BUFFER_SCROLL_READS;
        let mut edits = DEFAULT_BUFFER_EDITS;
        let mut open_budget_ms = None;
        let mut scroll_budget_ms = None;
        let mut edit_budget_ms = None;
        let mut args = args;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--size-bytes" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--size-bytes requires a value".to_string())
                    })?;
                    size_bytes = parse_nonzero_size_bytes("--size-bytes", &value)?;
                }
                "--iterations" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--iterations requires a value".to_string())
                    })?;
                    iterations = parse_iteration_count("--iterations", &value)?;
                }
                "--scroll-reads" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--scroll-reads requires a value".to_string())
                    })?;
                    scroll_reads = parse_iteration_count("--scroll-reads", &value)?;
                }
                "--edits" => {
                    let value = args
                        .next()
                        .ok_or_else(|| CliError::Usage("--edits requires a value".to_string()))?;
                    edits = parse_iteration_count("--edits", &value)?;
                }
                "--open-budget-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--open-budget-ms requires a value".to_string())
                    })?;
                    open_budget_ms = Some(parse_nonzero_u64("--open-budget-ms", &value)?);
                }
                "--scroll-budget-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--scroll-budget-ms requires a value".to_string())
                    })?;
                    scroll_budget_ms = Some(parse_nonzero_u64("--scroll-budget-ms", &value)?);
                }
                "--edit-budget-ms" => {
                    let value = args.next().ok_or_else(|| {
                        CliError::Usage("--edit-budget-ms requires a value".to_string())
                    })?;
                    edit_budget_ms = Some(parse_nonzero_u64("--edit-budget-ms", &value)?);
                }
                value => {
                    return Err(CliError::Usage(format!("unknown option: {value}")));
                }
            }
        }

        Ok(Self {
            size_bytes,
            iterations,
            scroll_reads,
            edits,
            open_budget_ms,
            scroll_budget_ms,
            edit_budget_ms,
        })
    }
}

#[derive(Debug)]
struct PerfBufferReport {
    requested_size_bytes: usize,
    actual_size_bytes: usize,
    line_count: usize,
    open: Duration,
    scroll: Duration,
    edit: Duration,
}

fn measure_buffer(
    size_bytes: usize,
    iterations: usize,
    scroll_reads: usize,
    edits: usize,
) -> Result<PerfBufferReport, CliError> {
    let bytes = generate_buffer_text(size_bytes);
    let actual_size_bytes = bytes.len();

    // Open: build the buffer (UTF-8 validation + line index). The input copy is
    // made outside the timer so only the build is measured.
    let mut open_total = Duration::ZERO;
    let mut line_count = 0;
    for _ in 0..iterations {
        let owned = bytes.clone();
        let started = Instant::now();
        let buffer = TextBuffer::from_utf8_bytes(owned)
            .map_err(|source| CliError::Runtime(source.to_string()))?;
        open_total += started.elapsed();
        line_count = buffer.line_count();
    }
    let open = open_total / iterations as u32;

    // Scroll: viewport reads spread across the document.
    let buffer = TextBuffer::from_utf8_bytes(bytes.clone())
        .map_err(|source| CliError::Runtime(source.to_string()))?;
    let mut scroll_total = Duration::ZERO;
    for index in 0..scroll_reads {
        let start_line = line_count.saturating_sub(1) * index / scroll_reads;
        let started = Instant::now();
        let text = buffer.text_for_line_range(start_line, BUFFER_VIEWPORT_LINES);
        scroll_total += started.elapsed();
        std::hint::black_box(text);
    }
    let scroll = scroll_total / scroll_reads as u32;

    // Edit: insert then delete one character at spread offsets, so the content
    // stays stable and each edit is comparable.
    let mut buffer = TextBuffer::from_utf8_bytes(bytes)
        .map_err(|source| CliError::Runtime(source.to_string()))?;
    let mut edit_total = Duration::ZERO;
    for index in 0..edits {
        let offset = buffer.utf16_len() * index / edits;
        let started = Instant::now();
        buffer
            .insert(offset, "X")
            .map_err(|source| CliError::Runtime(source.to_string()))?;
        buffer
            .delete(offset, offset + 1)
            .map_err(|source| CliError::Runtime(source.to_string()))?;
        edit_total += started.elapsed();
    }
    let edit = edit_total / edits as u32;

    Ok(PerfBufferReport {
        requested_size_bytes: size_bytes,
        actual_size_bytes,
        line_count,
        open,
        scroll,
        edit,
    })
}

/// Generates deterministic multi-line ASCII text of at least `size_bytes`.
fn generate_buffer_text(size_bytes: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(size_bytes + 64);
    let mut line: u64 = 0;
    while out.len() < size_bytes {
        line += 1;
        out.extend_from_slice(
            format!("{line:08} the quick brown fox jumps over the lazy dog\n").as_bytes(),
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::path::Path;
    use std::process::Command;
    use std::time::{Duration, Instant};

    use app_ffi::terminal::{replay_bytes, TermReplayDump};

    use super::{
        measure_buffer, term_run_plain_dump, PerfBufferOptions, PerfListDirectoryOptions,
        TermReplayOptions, TermRunOptions, DEFAULT_BUFFER_EDITS, DEFAULT_BUFFER_SCROLL_READS,
        DEFAULT_BUFFER_SIZE_BYTES, DEFAULT_ITERATIONS,
    };

    #[test]
    fn parse_perf_list_directory_options_uses_defaults() {
        let options =
            PerfListDirectoryOptions::parse(["/tmp/workspace".to_string()].into_iter()).unwrap();

        assert_eq!(options.path.to_string_lossy(), "/tmp/workspace");
        assert_eq!(options.iterations, DEFAULT_ITERATIONS);
        assert_eq!(options.budget, None);
    }

    #[test]
    fn parse_perf_list_directory_options_accepts_budget_and_iterations() {
        let options = PerfListDirectoryOptions::parse(
            [
                "/tmp/workspace".to_string(),
                "--iterations".to_string(),
                "7".to_string(),
                "--budget-ms".to_string(),
                "150".to_string(),
                "--max-budget-ms".to_string(),
                "300".to_string(),
            ]
            .into_iter(),
        )
        .unwrap();

        assert_eq!(options.iterations, 7);
        assert_eq!(options.budget.unwrap().as_millis(), 150);
        assert_eq!(options.max_budget.unwrap().as_millis(), 300);
    }

    #[test]
    fn parse_perf_list_directory_options_rejects_zero_iterations() {
        let error = PerfListDirectoryOptions::parse(
            [
                "/tmp/workspace".to_string(),
                "--iterations".to_string(),
                "0".to_string(),
            ]
            .into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "--iterations must be greater than zero");
    }

    #[test]
    fn parse_perf_list_directory_options_rejects_iterations_that_cannot_be_averaged() {
        let too_many_iterations = (super::MAX_ITERATIONS + 1).to_string();

        let error = PerfListDirectoryOptions::parse(
            [
                "/tmp/workspace".to_string(),
                "--iterations".to_string(),
                too_many_iterations,
            ]
            .into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(
            error.to_string(),
            format!(
                "--iterations must be less than or equal to {}",
                super::MAX_ITERATIONS
            )
        );
    }

    #[test]
    fn parse_perf_list_directory_options_rejects_unknown_option() {
        let error = PerfListDirectoryOptions::parse(
            ["/tmp/workspace".to_string(), "--unknown".to_string()].into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "unknown option: --unknown");
    }

    #[test]
    fn parse_term_replay_options_accepts_required_flags() {
        let options = TermReplayOptions::parse(
            [
                "fixtures/terminal/replay-basic.vt".to_string(),
                "--cols".to_string(),
                "80".to_string(),
                "--rows".to_string(),
                "24".to_string(),
                "--dump".to_string(),
                "vt".to_string(),
                "--bench".to_string(),
            ]
            .into_iter(),
        )
        .unwrap();

        assert_eq!(
            options.path.to_string_lossy(),
            "fixtures/terminal/replay-basic.vt"
        );
        assert_eq!(options.cols, 80);
        assert_eq!(options.rows, 24);
        assert_eq!(options.dump, TermReplayDump::Vt);
        assert!(options.bench);
    }

    #[test]
    fn parse_term_replay_options_rejects_missing_dimensions() {
        let error = TermReplayOptions::parse(["replay.vt".to_string()].into_iter()).unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "term-replay requires --cols");
    }

    #[test]
    fn parse_term_replay_options_rejects_unknown_dump_mode() {
        let error = TermReplayOptions::parse(
            [
                "replay.vt".to_string(),
                "--cols".to_string(),
                "80".to_string(),
                "--rows".to_string(),
                "24".to_string(),
                "--dump".to_string(),
                "ansi".to_string(),
            ]
            .into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "--dump must be plain or vt");
    }

    #[test]
    fn parse_term_run_options_accepts_command_after_separator() {
        let options = TermRunOptions::parse(
            [
                "--cols".to_string(),
                "40".to_string(),
                "--rows".to_string(),
                "12".to_string(),
                "--timeout-ms".to_string(),
                "1000".to_string(),
                "--".to_string(),
                "/bin/echo".to_string(),
                "hello".to_string(),
            ]
            .into_iter(),
        )
        .unwrap();

        assert_eq!(options.cols, 40);
        assert_eq!(options.rows, 12);
        assert_eq!(options.timeout.as_millis(), 1000);
        assert_eq!(options.command.to_string_lossy(), "/bin/echo");
        assert_eq!(options.args, vec![OsString::from("hello")]);
    }

    #[test]
    fn parse_term_run_options_requires_separator() {
        let error = TermRunOptions::parse(
            [
                "--cols".to_string(),
                "40".to_string(),
                "--rows".to_string(),
                "12".to_string(),
                "/bin/echo".to_string(),
            ]
            .into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.to_string(), "term-run command must follow --");
    }

    #[test]
    fn term_run_echo_round_trips_through_pty_and_terminal_ffi() {
        let options = TermRunOptions::parse(
            [
                "--cols".to_string(),
                "40".to_string(),
                "--rows".to_string(),
                "8".to_string(),
                "--".to_string(),
                "/bin/echo".to_string(),
                "hello".to_string(),
            ]
            .into_iter(),
        )
        .unwrap();

        assert!(term_run_plain_dump(&options).unwrap().contains("hello"));
    }

    #[test]
    fn term_run_timeout_kills_process_group() {
        let pid_file = std::env::temp_dir().join(format!(
            "locus-term-run-grandchild-{}.pid",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&pid_file);
        let script = format!(
            "sleep 30 & echo $! > {}; sleep 30",
            pid_file.to_string_lossy()
        );
        let options = TermRunOptions::parse(
            [
                "--cols".to_string(),
                "40".to_string(),
                "--rows".to_string(),
                "8".to_string(),
                "--timeout-ms".to_string(),
                "100".to_string(),
                "--".to_string(),
                "/bin/sh".to_string(),
                "-c".to_string(),
                script,
            ]
            .into_iter(),
        )
        .unwrap();

        let error = term_run_plain_dump(&options).unwrap_err();
        assert!(error.to_string().contains("timed out"));
        let grandchild_pid = std::fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .to_string();

        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if !process_exists(&grandchild_pid) {
                let _ = std::fs::remove_file(&pid_file);
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = std::fs::remove_file(&pid_file);
        panic!("grandchild sleep process {grandchild_pid} survived term-run timeout");
    }

    fn process_exists(pid: &str) -> bool {
        Command::new("/bin/kill")
            .arg("-0")
            .arg(pid)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    #[test]
    fn term_replay_fixture_round_trips_through_terminal_ffi() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../fixtures/terminal/replay-basic.vt");
        let bytes = std::fs::read(fixture).unwrap();
        let report = replay_bytes(&bytes, 40, 16, TermReplayDump::Plain).unwrap();

        assert_eq!(report.bytes, bytes.len());
        assert!(report.text.contains("Locus terminal replay"));
        assert!(report.text.contains("ready"));
    }

    #[test]
    fn parse_perf_buffer_options_uses_defaults() {
        let options = PerfBufferOptions::parse(std::iter::empty()).unwrap();

        assert_eq!(options.size_bytes, DEFAULT_BUFFER_SIZE_BYTES);
        assert_eq!(options.iterations, DEFAULT_ITERATIONS);
        assert_eq!(options.scroll_reads, DEFAULT_BUFFER_SCROLL_READS);
        assert_eq!(options.edits, DEFAULT_BUFFER_EDITS);
        assert_eq!(options.open_budget_ms, None);
        assert_eq!(options.scroll_budget_ms, None);
        assert_eq!(options.edit_budget_ms, None);
    }

    #[test]
    fn parse_perf_buffer_options_accepts_flags() {
        let options = PerfBufferOptions::parse(
            [
                "--size-bytes".to_string(),
                "2048".to_string(),
                "--iterations".to_string(),
                "3".to_string(),
                "--scroll-reads".to_string(),
                "10".to_string(),
                "--edits".to_string(),
                "7".to_string(),
                "--open-budget-ms".to_string(),
                "500".to_string(),
                "--scroll-budget-ms".to_string(),
                "50".to_string(),
                "--edit-budget-ms".to_string(),
                "500".to_string(),
            ]
            .into_iter(),
        )
        .unwrap();

        assert_eq!(options.size_bytes, 2048);
        assert_eq!(options.iterations, 3);
        assert_eq!(options.scroll_reads, 10);
        assert_eq!(options.edits, 7);
        assert_eq!(options.open_budget_ms, Some(500));
        assert_eq!(options.scroll_budget_ms, Some(50));
        assert_eq!(options.edit_budget_ms, Some(500));
    }

    #[test]
    fn parse_perf_buffer_options_rejects_unknown_option() {
        let error = PerfBufferOptions::parse(["--nope".to_string()].into_iter()).unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "unknown option: --nope");
    }

    #[test]
    fn measure_buffer_reports_metrics_for_small_input() {
        let report = measure_buffer(2000, 2, 5, 5).unwrap();

        assert_eq!(report.requested_size_bytes, 2000);
        assert!(report.actual_size_bytes >= 2000);
        assert!(report.line_count > 0);
    }
}
