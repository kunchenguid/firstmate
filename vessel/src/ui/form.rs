use super::*;

pub(super) fn heading(title: impl Into<String>) -> Line<'static> {
    Line::styled(format!("● {}", title.into()), Style::default().fg(TEAL))
}

pub(super) fn push_stacked_field(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    focused: bool,
    editing: bool,
    label: &str,
    value: &str,
    cursor: usize,
    selection_anchor: Option<usize>,
) {
    let value_lines = if focused && editing {
        editable_lines(value, cursor, selection_anchor)
    } else if value.is_empty() {
        vec![Line::styled("Not set", Style::default().fg(MUTED_TEXT))]
    } else {
        value
            .lines()
            .map(|line| Line::styled(line.to_owned(), Style::default().fg(TEXT)))
            .collect()
    };
    push_stacked_lines(
        lines,
        focused_row,
        width,
        focused,
        editing,
        label,
        value_lines,
        0,
    );
}

pub(super) fn push_stacked_lines(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    focused: bool,
    editing: bool,
    label: &str,
    value_lines: Vec<Line<'static>>,
    extra_focus_rows: usize,
) {
    if focused {
        *focused_row = Paragraph::new(lines.clone())
            .wrap(Wrap { trim: false })
            .line_count(width);
        *focused_row += extra_focus_rows;
    }
    lines.push(Line::from(vec![
        Span::styled(
            format!("{} {label}", if focused { "›" } else { "·" }),
            if focused {
                selection_style(true)
            } else {
                Style::default().fg(MUTED_TEXT)
            },
        ),
        Span::styled(
            if focused && editing { "  editing" } else { "" },
            Style::default().fg(MUTED_TEXT),
        ),
    ]));
    let value_lines = if value_lines.is_empty() {
        vec![Line::styled("Not set", Style::default().fg(MUTED_TEXT))]
    } else {
        value_lines
    };
    if focused && editing {
        let cursor_line = value_lines
            .iter()
            .position(|line| {
                line.spans
                    .iter()
                    .any(|span| span.style.add_modifier.contains(Modifier::UNDERLINED))
            })
            .unwrap_or(0);
        let mut cursor_lines = value_lines[..=cursor_line].to_vec();
        if let Some(cursor_span) = cursor_lines[cursor_line]
            .spans
            .iter()
            .position(|span| span.style.add_modifier.contains(Modifier::UNDERLINED))
        {
            cursor_lines[cursor_line].spans.truncate(cursor_span + 1);
        }
        *focused_row += Paragraph::new(cursor_lines)
            .wrap(Wrap { trim: false })
            .line_count(width);
    }
    lines.extend(value_lines);
    lines.push(Line::raw(""));
}

fn editable_lines(value: &str, cursor: usize, anchor: Option<usize>) -> Vec<Line<'static>> {
    let mut lines = vec![Line::default()];
    for (index, character) in value.chars().chain(std::iter::once(' ')).enumerate() {
        let mut style = Style::default().fg(TEXT);
        if anchor.is_some_and(|anchor| (anchor.min(cursor)..anchor.max(cursor)).contains(&index)) {
            style = style.add_modifier(Modifier::REVERSED);
        }
        if index == cursor {
            style = style.add_modifier(Modifier::UNDERLINED | Modifier::BOLD);
        }
        if character == '\n' {
            if index == cursor {
                lines
                    .last_mut()
                    .unwrap()
                    .spans
                    .push(Span::styled(" ", style));
            }
            lines.push(Line::default());
        } else {
            lines
                .last_mut()
                .unwrap()
                .spans
                .push(Span::styled(character.to_string(), style));
        }
    }
    lines
}
