use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::file_type::{classify_path, FileType};

#[non_exhaustive]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkspaceListOptions {
    pub include_ignored: bool,
    pub include_extended_metadata: bool,
}

impl WorkspaceListOptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn include_ignored(mut self, value: bool) -> Self {
        self.include_ignored = value;
        self
    }

    pub fn include_extended_metadata(mut self, value: bool) -> Self {
        self.include_extended_metadata = value;
        self
    }
}

#[derive(Debug)]
pub struct WorkspaceSnapshot {
    pub entries: Vec<WorkspaceEntry>,
    pub partial_errors: Vec<WorkspaceError>,
}

impl WorkspaceSnapshot {
    pub fn has_partial_errors(&self) -> bool {
        !self.partial_errors.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceEntry {
    pub path: PathBuf,
    /// Display-oriented file name. `path` remains the source of truth.
    pub name: String,
    pub kind: WorkspaceEntryKind,
    pub size_bytes: Option<u64>,
    pub modified: Option<SystemTime>,
    pub readonly: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceEntryKind {
    Directory,
    File(FileType),
    Symlink,
    Other,
}

impl WorkspaceEntryKind {
    pub fn is_directory(self) -> bool {
        matches!(self, Self::Directory)
    }
}

#[derive(Debug)]
pub enum WorkspaceError {
    NotFound(PathBuf),
    NotDirectory(PathBuf),
    ReadDirectory { path: PathBuf, source: io::Error },
    ReadEntry { source: io::Error },
    ReadMetadata { path: PathBuf, source: io::Error },
}

impl fmt::Display for WorkspaceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(path) => {
                write!(
                    formatter,
                    "workspace path does not exist: {}",
                    path.display()
                )
            }
            Self::NotDirectory(path) => {
                write!(
                    formatter,
                    "workspace path is not a folder: {}",
                    path.display()
                )
            }
            Self::ReadDirectory { path, source } => {
                write!(
                    formatter,
                    "failed to read folder {}: {source}",
                    path.display()
                )
            }
            Self::ReadEntry { source } => {
                write!(formatter, "failed to read folder entry: {source}")
            }
            Self::ReadMetadata { path, source } => {
                write!(
                    formatter,
                    "failed to read metadata for {}: {source}",
                    path.display()
                )
            }
        }
    }
}

impl std::error::Error for WorkspaceError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::NotFound(_) | Self::NotDirectory(_) => None,
            Self::ReadDirectory { source, .. }
            | Self::ReadEntry { source }
            | Self::ReadMetadata { source, .. } => Some(source),
        }
    }
}

pub fn list_directory(path: impl AsRef<Path>) -> Result<WorkspaceSnapshot, WorkspaceError> {
    list_directory_with_options(path, WorkspaceListOptions::default())
}

pub fn list_directory_with_options(
    path: impl AsRef<Path>,
    options: WorkspaceListOptions,
) -> Result<WorkspaceSnapshot, WorkspaceError> {
    let path = path.as_ref();
    list_directory_inner(path, options, |entry_path| fs::symlink_metadata(entry_path))
}

fn list_directory_inner(
    path: &Path,
    options: WorkspaceListOptions,
    metadata_for: impl Fn(&Path) -> io::Result<fs::Metadata>,
) -> Result<WorkspaceSnapshot, WorkspaceError> {
    let entries = fs::read_dir(path).map_err(|source| read_directory_error(path, source))?;

    let mut snapshot = Vec::new();
    let mut partial_errors = Vec::new();

    for entry in entries {
        // Keep listing useful even when one child cannot be read; the UI can
        // show readable entries plus a partial warning instead of failing empty.
        let entry = match entry {
            Ok(entry) => entry,
            Err(source) => {
                partial_errors.push(WorkspaceError::ReadEntry { source });
                continue;
            }
        };
        let name = entry.file_name().to_string_lossy().into_owned();

        if !options.include_ignored && is_ignored_name(&name) {
            continue;
        }

        let path = entry.path();
        // Do not follow symlinks during listing. The browser should show links
        // as links and avoid surprising traversal or permission side effects.
        let metadata = match metadata_for(&path) {
            Ok(metadata) => metadata,
            Err(source) => {
                partial_errors.push(WorkspaceError::ReadMetadata {
                    path: path.clone(),
                    source,
                });
                continue;
            }
        };

        snapshot.push(entry_from_metadata(
            path,
            name,
            metadata,
            options.include_extended_metadata,
        ));
    }

    snapshot.sort_by(compare_entries);
    Ok(WorkspaceSnapshot {
        entries: snapshot,
        partial_errors,
    })
}

fn read_directory_error(path: &Path, source: io::Error) -> WorkspaceError {
    match source.kind() {
        io::ErrorKind::NotFound => WorkspaceError::NotFound(path.to_path_buf()),
        io::ErrorKind::NotADirectory => WorkspaceError::NotDirectory(path.to_path_buf()),
        _ => WorkspaceError::ReadDirectory {
            path: path.to_path_buf(),
            source,
        },
    }
}

fn entry_from_metadata(
    path: PathBuf,
    name: String,
    metadata: fs::Metadata,
    include_extended_metadata: bool,
) -> WorkspaceEntry {
    let file_type = metadata.file_type();
    let kind = if file_type.is_dir() {
        WorkspaceEntryKind::Directory
    } else if file_type.is_file() {
        WorkspaceEntryKind::File(classify_path(&path))
    } else if file_type.is_symlink() {
        WorkspaceEntryKind::Symlink
    } else {
        WorkspaceEntryKind::Other
    };

    let size_bytes = (include_extended_metadata && matches!(kind, WorkspaceEntryKind::File(_)))
        .then_some(metadata.len());
    let modified = include_extended_metadata
        .then(|| metadata.modified().ok())
        .flatten();
    let readonly = metadata.permissions().readonly();

    WorkspaceEntry {
        path,
        name,
        kind,
        size_bytes,
        modified,
        readonly,
    }
}

fn compare_entries(left: &WorkspaceEntry, right: &WorkspaceEntry) -> std::cmp::Ordering {
    entry_sort_group(left)
        .cmp(&entry_sort_group(right))
        .then_with(|| compare_names_naturally(&left.name, &right.name))
}

fn entry_sort_group(entry: &WorkspaceEntry) -> u8 {
    if entry.kind.is_directory() {
        0
    } else {
        1
    }
}

fn compare_names_naturally(left: &str, right: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;

    let mut left_chars = left.char_indices().peekable();
    let mut right_chars = right.char_indices().peekable();

    loop {
        match (left_chars.peek().copied(), right_chars.peek().copied()) {
            (None, None) => return left.cmp(right),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some((_, left_char)), Some((_, right_char)))
                if left_char.is_ascii_digit() && right_char.is_ascii_digit() =>
            {
                let left_number = take_ascii_digit_run(left, &mut left_chars);
                let right_number = take_ascii_digit_run(right, &mut right_chars);
                let ordering = compare_ascii_numbers(left_number, right_number);
                if ordering != Ordering::Equal {
                    return ordering;
                }
            }
            (Some((_, left_char)), Some((_, right_char))) => {
                left_chars.next();
                right_chars.next();
                let ordering = left_char
                    .to_lowercase()
                    .cmp(right_char.to_lowercase())
                    .then_with(|| left_char.cmp(&right_char));
                if ordering != Ordering::Equal {
                    return ordering;
                }
            }
        }
    }
}

fn take_ascii_digit_run<'a>(
    value: &'a str,
    chars: &mut std::iter::Peekable<std::str::CharIndices<'a>>,
) -> &'a str {
    let start = chars.peek().map(|(index, _)| *index).unwrap_or(value.len());
    let mut end = start;
    while let Some((index, character)) = chars.peek().copied() {
        if !character.is_ascii_digit() {
            break;
        }
        chars.next();
        end = index + character.len_utf8();
    }
    &value[start..end]
}

fn compare_ascii_numbers(left: &str, right: &str) -> std::cmp::Ordering {
    let left_trimmed = left.trim_start_matches('0');
    let right_trimmed = right.trim_start_matches('0');
    let left_digits = if left_trimmed.is_empty() {
        "0"
    } else {
        left_trimmed
    };
    let right_digits = if right_trimmed.is_empty() {
        "0"
    } else {
        right_trimmed
    };

    left_digits
        .len()
        .cmp(&right_digits.len())
        .then_with(|| left_digits.cmp(right_digits))
        .then_with(|| left.len().cmp(&right.len()))
}

const IGNORED_NAMES: &[&str] = &[
    ".git",
    ".DS_Store",
    ".DocumentRevisions-V100",
    ".Spotlight-V100",
    ".TemporaryItems",
    ".Trashes",
    ".fseventsd",
    ".VolumeIcon.icns",
    "$RECYCLE.BIN",
    "System Volume Information",
    "Thumbs.db",
    "desktop.ini",
];

fn is_ignored_name(name: &str) -> bool {
    // Hidden project files such as .env and .agents are intentionally not ignored.
    name.starts_with("._") || name.starts_with("~$") || IGNORED_NAMES.contains(&name)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{
        list_directory, list_directory_with_options, WorkspaceEntryKind, WorkspaceError,
        WorkspaceListOptions,
    };
    use crate::file_type::FileType;

    #[test]
    fn list_directory_sorts_folders_before_files_then_by_name() {
        let workspace = TestWorkspace::new();
        workspace.create_dir("zeta");
        workspace.create_dir("Alpha");
        workspace.create_file("beta.md");
        workspace.create_file("gamma.txt");

        let names = entry_names(list_directory(workspace.path()).unwrap());

        assert_eq!(names, ["Alpha", "zeta", "beta.md", "gamma.txt"]);
    }

    #[test]
    fn list_directory_sorts_names_numerically() {
        let workspace = TestWorkspace::new();
        workspace.create_file("file10.md");
        workspace.create_file("file2.md");
        workspace.create_file("file1.md");

        let names = entry_names(list_directory(workspace.path()).unwrap());

        assert_eq!(names, ["file1.md", "file2.md", "file10.md"]);
    }

    #[test]
    fn list_directory_keeps_agent_and_environment_dotfiles_by_default() {
        let workspace = TestWorkspace::new();
        workspace.create_dir(".agents");
        workspace.create_dir(".claude");
        workspace.create_file(".env");
        workspace.create_file(".gitignore");
        workspace.create_file("project-brief.md");

        let names = entry_names(list_directory(workspace.path()).unwrap());

        assert_eq!(
            names,
            [
                ".agents",
                ".claude",
                ".env",
                ".gitignore",
                "project-brief.md"
            ]
        );
    }

    #[test]
    fn list_directory_ignores_source_control_and_os_noise_by_default() {
        let workspace = TestWorkspace::new();
        workspace.create_dir(".git");
        workspace.create_dir(".Spotlight-V100");
        workspace.create_dir("$RECYCLE.BIN");
        workspace.create_dir("System Volume Information");
        workspace.create_file(".DS_Store");
        workspace.create_file("._project-brief.md");
        workspace.create_file("Thumbs.db");
        workspace.create_file("desktop.ini");
        workspace.create_file("~$budget.xlsx");
        workspace.create_file("project-brief.md");

        let names = entry_names(list_directory(workspace.path()).unwrap());

        assert_eq!(names, ["project-brief.md"]);
    }

    #[test]
    fn list_directory_can_include_ignored_entries() {
        let workspace = TestWorkspace::new();
        workspace.create_dir(".git");
        workspace.create_file(".DS_Store");
        workspace.create_file("project-brief.md");

        let names = entry_names(
            list_directory_with_options(
                workspace.path(),
                WorkspaceListOptions::new().include_ignored(true),
            )
            .unwrap(),
        );

        assert_eq!(names, [".git", ".DS_Store", "project-brief.md"]);
    }

    #[test]
    fn list_directory_classifies_file_types() {
        let workspace = TestWorkspace::new();
        workspace.create_file("notes.md");

        let entries = list_directory(workspace.path()).unwrap().entries;

        assert_eq!(
            entries[0].kind,
            WorkspaceEntryKind::File(FileType::Markdown)
        );
    }

    #[test]
    fn list_directory_omits_extended_file_metadata_by_default() {
        let workspace = TestWorkspace::new();
        workspace.create_file_with_contents("notes.md", "hello");

        let entries = list_directory(workspace.path()).unwrap().entries;

        assert_eq!(entries[0].size_bytes, None);
        assert_eq!(entries[0].modified, None);
    }

    #[test]
    fn list_directory_can_include_extended_file_metadata_without_loading_contents() {
        let workspace = TestWorkspace::new();
        workspace.create_dir("Drafts");
        workspace.create_file_with_contents("notes.md", "hello");

        let entries = list_directory_with_options(
            workspace.path(),
            WorkspaceListOptions::new().include_extended_metadata(true),
        )
        .unwrap()
        .entries;

        assert_eq!(entries[0].name, "Drafts");
        assert_eq!(entries[0].size_bytes, None);
        assert_eq!(entries[1].name, "notes.md");
        assert_eq!(entries[1].size_bytes, Some(5));
        assert!(entries[1].modified.is_some());
    }

    #[test]
    fn list_directory_sort_order_does_not_depend_on_extended_metadata() {
        let workspace = TestWorkspace::new();
        workspace.create_dir("zeta");
        workspace.create_dir("Alpha");
        workspace.create_file("file10.md");
        workspace.create_file("file2.md");
        workspace.create_file("file1.md");

        let default_names = entry_names(list_directory(workspace.path()).unwrap());
        let extended_names = entry_names(
            list_directory_with_options(
                workspace.path(),
                WorkspaceListOptions::new().include_extended_metadata(true),
            )
            .unwrap(),
        );

        assert_eq!(default_names, extended_names);
    }

    #[test]
    fn list_directory_keeps_readable_entries_when_child_metadata_fails() {
        let workspace = TestWorkspace::new();
        workspace.create_file("readable.md");
        workspace.create_file("unreadable.md");

        let snapshot =
            super::list_directory_inner(workspace.path(), WorkspaceListOptions::new(), |path| {
                if path
                    .file_name()
                    .is_some_and(|name| name == std::ffi::OsStr::new("unreadable.md"))
                {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "metadata blocked for test",
                    ))
                } else {
                    fs::symlink_metadata(path)
                }
            })
            .unwrap();

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].name, "readable.md");
        assert_eq!(snapshot.partial_errors.len(), 1);
        assert!(matches!(
            snapshot.partial_errors[0],
            WorkspaceError::ReadMetadata { .. }
        ));
    }

    #[test]
    fn list_directory_preserves_non_ascii_file_names() {
        let workspace = TestWorkspace::new();
        workspace.create_file("alpha.md");
        workspace.create_file("資料.md");

        let names = entry_names(list_directory(workspace.path()).unwrap());

        assert_eq!(names, ["alpha.md", "資料.md"]);
    }

    #[test]
    fn list_directory_returns_error_for_file_path() {
        let workspace = TestWorkspace::new();
        let file_path = workspace.create_file("notes.md");

        let error = list_directory(file_path).unwrap_err();

        assert!(matches!(error, WorkspaceError::NotDirectory(_)));
    }

    #[test]
    fn list_directory_returns_error_for_missing_path() {
        let workspace = TestWorkspace::new();
        let missing_path = workspace.path().join("missing");

        let error = list_directory(missing_path).unwrap_err();

        assert!(matches!(error, WorkspaceError::NotFound(_)));
    }

    #[cfg(unix)]
    #[test]
    fn list_directory_reports_symlink_without_following_it() {
        use std::os::unix::fs::symlink;

        let workspace = TestWorkspace::new();
        let target = workspace.create_dir("target");
        symlink(target, workspace.path().join("linked-target")).unwrap();

        let entries = list_directory(workspace.path()).unwrap().entries;
        let link_entry = entries
            .iter()
            .find(|entry| entry.name == "linked-target")
            .unwrap();

        assert_eq!(link_entry.kind, WorkspaceEntryKind::Symlink);
    }

    fn entry_names(snapshot: super::WorkspaceSnapshot) -> Vec<String> {
        assert!(!snapshot.has_partial_errors());
        snapshot
            .entries
            .into_iter()
            .map(|entry| entry.name)
            .collect()
    }

    struct TestWorkspace {
        path: PathBuf,
    }

    static NEXT_TEST_WORKSPACE_ID: AtomicU64 = AtomicU64::new(0);

    impl TestWorkspace {
        fn new() -> Self {
            let mut path = std::env::temp_dir();
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let id = NEXT_TEST_WORKSPACE_ID.fetch_add(1, Ordering::Relaxed);
            path.push(format!(
                "locus-workspace-test-{}-{nanos}-{id}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();

            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }

        fn create_dir(&self, name: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::create_dir(&path).unwrap();
            path
        }

        fn create_file(&self, name: &str) -> PathBuf {
            self.create_file_with_contents(name, "")
        }

        fn create_file_with_contents(&self, name: &str, contents: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::write(&path, contents).unwrap();
            path
        }
    }

    impl Drop for TestWorkspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
