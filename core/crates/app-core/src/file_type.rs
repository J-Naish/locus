use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileType {
    Markdown,
    StructuredText,
    Pdf,
    Office,
    Image,
    Audio,
    Video,
    PlainText,
    Code,
    Unknown,
}

impl FileType {
    /// Returns a stable English label for diagnostics and CLI output.
    ///
    /// Native app UI should localize file type names in the platform layer.
    pub fn label(self) -> &'static str {
        match self {
            Self::Markdown => "Markdown",
            Self::StructuredText => "Structured Text",
            Self::Pdf => "PDF",
            Self::Office => "Office",
            Self::Image => "Image",
            Self::Audio => "Audio",
            Self::Video => "Video",
            Self::PlainText => "Text",
            Self::Code => "Code",
            Self::Unknown => "Unknown",
        }
    }
}

pub fn classify_path(path: impl AsRef<Path>) -> FileType {
    if let Some(file_type) = path
        .as_ref()
        .file_name()
        .and_then(|value| value.to_str())
        .and_then(classify_extensionless_name)
    {
        return file_type;
    }

    path.as_ref()
        .extension()
        .and_then(|value| value.to_str())
        .map(classify_extension)
        .unwrap_or(FileType::Unknown)
}

pub fn classify_extension(extension: &str) -> FileType {
    match extension.to_ascii_lowercase().as_str() {
        "md" | "markdown" | "mdown" | "mkd" => FileType::Markdown,
        "yaml" | "yml" | "json" | "toml" => FileType::StructuredText,
        "pdf" => FileType::Pdf,
        "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" => FileType::Office,
        "png" | "jpg" | "jpeg" | "gif" | "heic" | "webp" | "tif" | "tiff" | "bmp" | "svg" => {
            FileType::Image
        }
        "mp3" | "m4a" | "aac" | "wav" | "aiff" | "flac" | "ogg" => FileType::Audio,
        "mov" | "mp4" | "m4v" | "avi" | "mkv" | "webm" => FileType::Video,
        "txt" | "text" | "csv" | "tsv" | "log" => FileType::PlainText,
        "rs" | "swift" | "cs" | "js" | "ts" | "tsx" | "jsx" | "py" | "rb" | "go" | "java"
        | "kt" | "kts" | "c" | "h" | "cpp" | "hpp" | "sh" | "zsh" | "fish" | "ps1" | "html"
        | "css" | "scss" | "xml" => FileType::Code,
        _ => FileType::Unknown,
    }
}

fn classify_extensionless_name(name: &str) -> Option<FileType> {
    if name.eq_ignore_ascii_case(".env")
        || name.eq_ignore_ascii_case(".envrc")
        || name
            .get(..5)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(".env."))
    {
        return Some(FileType::PlainText);
    }

    if KNOWN_PLAIN_TEXT_NAMES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
    {
        return Some(FileType::PlainText);
    }

    if KNOWN_STRUCTURED_TEXT_NAMES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
    {
        return Some(FileType::StructuredText);
    }

    if KNOWN_CODE_NAMES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
    {
        return Some(FileType::Code);
    }

    None
}

const KNOWN_PLAIN_TEXT_NAMES: &[&str] = &[
    ".gitignore",
    ".cursorignore",
    ".dockerignore",
    ".eslintignore",
    ".prettierignore",
    ".npmignore",
    "readme",
    "license",
    "notice",
    "changelog",
    "contributing",
    "authors",
];

const KNOWN_STRUCTURED_TEXT_NAMES: &[&str] =
    &[".editorconfig", ".eslintrc", ".prettierrc", ".babelrc"];

const KNOWN_CODE_NAMES: &[&str] = &[
    "dockerfile",
    "containerfile",
    "makefile",
    "rakefile",
    "gemfile",
    "brewfile",
    "justfile",
    "procfile",
];

#[cfg(test)]
mod tests {
    use super::{classify_extension, classify_path, FileType};

    #[test]
    fn classify_extension_returns_markdown_for_md() {
        assert_eq!(classify_extension("md"), FileType::Markdown);
    }

    #[test]
    fn classify_extension_is_case_insensitive() {
        assert_eq!(classify_extension("PDF"), FileType::Pdf);
    }

    #[test]
    fn classify_extension_returns_structured_text_for_yaml_json_and_toml() {
        let actual = ["yaml", "json", "toml"].map(classify_extension);

        assert_eq!(
            actual,
            [
                FileType::StructuredText,
                FileType::StructuredText,
                FileType::StructuredText,
            ]
        );
    }

    #[test]
    fn classify_path_recognizes_common_extensionless_text_files() {
        assert_eq!(classify_path(".gitignore"), FileType::PlainText);
        assert_eq!(classify_path(".cursorignore"), FileType::PlainText);
        assert_eq!(classify_path("README"), FileType::PlainText);
        assert_eq!(classify_path(".env.local"), FileType::PlainText);
        assert_eq!(classify_path(".envrc"), FileType::PlainText);
    }

    #[test]
    fn classify_path_does_not_apply_env_rule_to_other_prefixed_files() {
        assert_eq!(classify_path(".envoyproxy.yaml"), FileType::StructuredText);
        assert_eq!(
            classify_path(".environment-config.json"),
            FileType::StructuredText
        );
    }

    #[test]
    fn classify_path_recognizes_common_extensionless_code_files() {
        assert_eq!(classify_path("Dockerfile"), FileType::Code);
        assert_eq!(classify_path("Makefile"), FileType::Code);
    }

    #[test]
    fn classify_path_keeps_unknown_extensionless_files_unknown() {
        assert_eq!(classify_path("opaque-file"), FileType::Unknown);
    }

    #[test]
    fn label_returns_user_facing_type_name() {
        assert_eq!(FileType::Office.label(), "Office");
    }
}
