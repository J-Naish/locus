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
    let Some(extension) = path.as_ref().extension().and_then(|value| value.to_str()) else {
        return FileType::Unknown;
    };

    classify_extension(extension)
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
    fn classify_path_returns_unknown_when_extension_is_missing() {
        assert_eq!(classify_path("README"), FileType::Unknown);
    }

    #[test]
    fn label_returns_user_facing_type_name() {
        assert_eq!(FileType::Office.label(), "Office");
    }
}
