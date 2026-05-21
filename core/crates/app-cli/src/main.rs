use std::env;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, Instant};

use app_core::workspace::list_directory;

const DEFAULT_ITERATIONS: usize = 5;

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

Commands:
  version                 Print the Rust core version.
  perf-list-directory     Measure non-recursive workspace listing latency.
",
        app_core::APP_NAME,
        app_core::core_version()
    );
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
                    iterations = parse_nonzero_usize("--iterations", &value)?;
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

fn parse_nonzero_usize(name: &str, value: &str) -> Result<usize, CliError> {
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

#[cfg(test)]
mod tests {
    use super::{PerfListDirectoryOptions, DEFAULT_ITERATIONS};

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
    fn parse_perf_list_directory_options_rejects_unknown_option() {
        let error = PerfListDirectoryOptions::parse(
            ["/tmp/workspace".to_string(), "--unknown".to_string()].into_iter(),
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "unknown option: --unknown");
    }
}
