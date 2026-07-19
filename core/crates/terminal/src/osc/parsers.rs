pub(crate) mod change_window_icon;
pub(crate) mod change_window_title;
pub(crate) mod clipboard_operation;
pub(crate) mod color_operation;
pub(crate) mod context_signal;
pub(crate) mod hyperlink;
pub(crate) mod iterm2;
pub(crate) mod kitty_clipboard_protocol;
pub(crate) mod kitty_color;
pub(crate) mod kitty_dnd_protocol;
pub(crate) mod kitty_options;
pub(crate) mod kitty_text_sizing;
pub(crate) mod mouse_shape;
pub(crate) mod osc9;
pub(crate) mod report_pwd;
pub(crate) mod rxvt_extension;
pub(crate) mod semantic_prompt;
pub(crate) mod string_encoding;

#[cfg(test)]
fn parse_body(body: &[u8], terminator: Option<u8>) -> crate::osc::Parser {
    let mut parser = crate::osc::Parser::default();
    for byte in body {
        parser.next(*byte);
    }
    parser.end(terminator);
    parser
}
