pub(crate) fn text_range(
    _text: &str,
    anchor: Option<usize>,
    cursor: usize,
) -> Option<(usize, usize)> {
    let anchor = anchor?;
    Some((anchor.min(cursor), anchor.max(cursor)))
}

pub(crate) fn byte_index(text: &str, character: usize) -> usize {
    text.char_indices()
        .nth(character)
        .map(|(index, _)| index)
        .unwrap_or(text.len())
}

pub(crate) fn replace_selection(
    text: &mut String,
    cursor: &mut usize,
    anchor: &mut Option<usize>,
) -> bool {
    let Some((start, end)) = text_range(text, *anchor, *cursor) else {
        return false;
    };
    text.replace_range(byte_index(text, start)..byte_index(text, end), "");
    *cursor = start;
    *anchor = None;
    true
}

pub(crate) fn insert_text(
    text: &mut String,
    cursor: &mut usize,
    anchor: &mut Option<usize>,
    character: char,
) {
    replace_selection(text, cursor, anchor);
    let index = byte_index(text, *cursor);
    text.insert(index, character);
    *cursor += 1;
}

pub(crate) fn backspace_text(text: &mut String, cursor: &mut usize, anchor: &mut Option<usize>) {
    if replace_selection(text, cursor, anchor) || *cursor == 0 {
        return;
    }
    let start = byte_index(text, *cursor - 1);
    let end = byte_index(text, *cursor);
    text.replace_range(start..end, "");
    *cursor -= 1;
}

pub(crate) fn delete_text(text: &mut String, cursor: &mut usize, anchor: &mut Option<usize>) {
    if replace_selection(text, cursor, anchor) {
        return;
    }
    let end = byte_index(text, *cursor + 1);
    if end > byte_index(text, *cursor) {
        text.replace_range(byte_index(text, *cursor)..end, "");
    }
}

pub(crate) fn move_cursor(
    cursor: &mut usize,
    anchor: &mut Option<usize>,
    length: usize,
    offset: isize,
    selecting: bool,
) {
    if selecting {
        anchor.get_or_insert(*cursor);
    } else {
        *anchor = None;
    }
    *cursor = cursor.saturating_add_signed(offset).min(length);
}
pub(crate) fn cycle_option(value: &mut String, options: &[&str], offset: isize) {
    let current = options
        .iter()
        .position(|option| *option == value.as_str())
        .unwrap_or_default();
    let next = (current as isize + offset).rem_euclid(options.len() as isize) as usize;
    *value = options[next].into();
}
